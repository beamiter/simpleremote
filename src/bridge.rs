//! The JSON bridge between Vim and the remote shell agent.
//!
//! Vim writes one JSON object per line on our stdin and reads one JSON object
//! per line from our stdout.  The remote agent keeps speaking its deliberately
//! boring `id<TAB>op<TAB>base64(payload)` protocol; every base64 round trip
//! that Vim used to perform by spawning `base64` twice per request now happens
//! here, in-process, in microseconds.
//!
//! Request lines (from Vim):
//!
//! ```json
//! {"id":1,"op":"ping"}
//! {"id":2,"op":"read","path":"/srv/app/main.py"}
//! {"id":3,"op":"write","path":"/srv/app/main.py","content_b64":"..."}
//! {"id":4,"op":"list-meta","path":"/srv/app"}
//! {"id":5,"op":"exec","command":"git status --porcelain"}
//! ```
//!
//! Response lines (to Vim):
//!
//! ```json
//! {"id":1,"ok":true,"data":"simpleremote/2"}
//! {"id":2,"ok":true,"data":"print('hi')\n"}
//! {"id":6,"ok":false,"data":"not a file: /srv/app/missing"}
//! {"id":7,"ok":true,"data_b64":"/9j/4AAQ..."}
//! ```
//!
//! `data` is the fully decoded payload — for `read` and `read-config` the file
//! content itself, not the agent's inner base64 layer.  When a payload is not
//! valid UTF-8 (a latin-1 file, a binary blob) it is delivered as `data_b64`
//! instead, so no byte is ever replaced on the way to a buffer.  Writes carry
//! `content_b64` for the same reason in the other direction; `content` is
//! accepted for callers that know their text is UTF-8.
//!
//! Every request line produces exactly one reply line, including the lines
//! this bridge cannot understand: a line that fails to parse still carries its
//! `id` in the common case, and answering it is the difference between an
//! error the user sees and a request that never comes back.
//!
//! Both directions are read with a bounded reader.  Vim's stdin is a channel
//! that can die mid-write, and the reply side carries bytes from another
//! machine over ssh or docker; neither may grow this process until the
//! allocator fails, so an oversized record is discarded through its newline
//! and the next well-formed record is still served.
//!
//! Lifetime: one bridge per connection.  When Vim closes our stdin, the
//! agent's stdin is closed too, its `read` loop ends and the transport exits;
//! we exit with the transport's status.  When the transport dies first, our
//! stdout reader sees EOF and we exit with its status while any request still
//! in flight is answered by Vim's own exit handling.

use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, BufWriter, Write};
use std::process::{self, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde::Deserialize;

use crate::{RuntimeArgs, transport_command};

#[derive(Deserialize)]
struct Request {
    id: u64,
    op: String,
    #[serde(default)]
    path: String,
    #[serde(default)]
    command: String,
    #[serde(default)]
    content: Option<String>,
    #[serde(default)]
    content_b64: Option<String>,
}

type Ops = Arc<Mutex<HashMap<u64, String>>>;

/// The largest request or agent reply this bridge will assemble.  A buffer
/// travels base64 encoded in both directions, and the agent adds a second
/// layer around file bodies, so the ceiling has to sit well above
/// `g:simpleremote_large_file_bytes` (10 MiB by default) — but it has to
/// exist: `read_line` and `read_until` grow one allocation until the next
/// newline arrives or the machine runs out of memory, and the producer on
/// either side is untrusted.
const MAX_RECORD_BYTES: usize = 64 * 1024 * 1024;

/// How many replies may be awaiting correlation before new ones are refused.
/// An entry is removed when the agent answers; an agent that accepts requests
/// and never answers must not be able to grow this table without bound.
const MAX_TRACKED_REQUESTS: usize = 4096;

pub fn run(args: &RuntimeArgs) -> Result<u8, String> {
    let mut command = transport_command(args, "agent")?;
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|error| format!("cannot start {} transport: {error}", args.kind))?;
    let child_stdin = child.stdin.take().ok_or("agent transport has no stdin")?;
    let child_stdout = child.stdout.take().ok_or("agent transport has no stdout")?;
    let ops: Ops = Arc::new(Mutex::new(HashMap::new()));

    let writer_ops = Arc::clone(&ops);
    let writer = thread::spawn(move || forward_requests(writer_ops, child_stdin));

    forward_replies(&ops, child_stdout);
    let status = child
        .wait()
        .map_err(|error| format!("cannot wait for agent transport: {error}"))?;
    // The request thread may be blocked in a read of Vim's stdin that will
    // only end when Vim closes the channel; do not wait for it.
    drop(writer);
    let code = status.code().unwrap_or(1).clamp(0, 255) as u8;
    process::exit(i32::from(code));
}

/// Vim → agent.  Runs until Vim closes the channel or the agent's stdin dies.
fn forward_requests(ops: Ops, child_stdin: process::ChildStdin) {
    let stdin = io::stdin();
    let mut input = stdin.lock();
    let mut agent = BufWriter::new(child_stdin);
    pump_requests(&ops, &mut input, &mut agent, MAX_RECORD_BYTES, &mut emit);
    // Dropping the writer closes the agent's stdin: its read loop ends and the
    // transport exits, which is what unblocks the reply side.
}

/// What one request line asks of us.
enum Forwarded {
    /// The agent's `id<TAB>op<TAB>base64(payload)` record.
    Wire(String),
    /// An answer Vim gets without the agent seeing anything.
    Reply(Reply),
    /// A blank line: not a request, and nothing owes it a reply.
    Nothing,
}

/// The request half of the bridge, over any reader and writer so the contract
/// — every line is answered or forwarded, and no line may be unbounded — is
/// testable without a live transport.
fn pump_requests<R: BufRead, W: Write>(
    ops: &Ops,
    input: &mut R,
    agent: &mut W,
    limit: usize,
    reply: &mut dyn FnMut(&Reply),
) {
    while let Some(record) = read_record(input, "request", limit) {
        let line = match record {
            Ok(line) => line,
            Err(message) => {
                eprintln!("simpleremote-daemon: {message}");
                // The record was discarded through its newline, so no id
                // survived it.  Vim's ids start at 1 and it drops a reply that
                // matches nothing, so id 0 reports the failure through err_cb
                // without resolving somebody else's request.
                reply(&Reply::error(0, &message));
                continue;
            }
        };
        match prepare_request(ops, &line) {
            Forwarded::Nothing => {}
            Forwarded::Reply(answer) => reply(&answer),
            Forwarded::Wire(wire) => {
                if agent.write_all(wire.as_bytes()).is_err() || agent.flush().is_err() {
                    break;
                }
            }
        }
    }
}

/// Turn one request line into the agent record it becomes, or into the reply
/// Vim gets instead.  Every path out of here that is not `Nothing` answers the
/// caller: silence is what a hung request is made of.
fn prepare_request(ops: &Ops, line: &[u8]) -> Forwarded {
    let Ok(text) = std::str::from_utf8(line) else {
        // Vim writes json_encode() output, which is always UTF-8; a line that
        // is not carries no id we could trust either.
        eprintln!("simpleremote-daemon: request line is not valid UTF-8");
        return Forwarded::Reply(Reply::error(0, "request line is not valid UTF-8"));
    };
    if text.trim().is_empty() {
        return Forwarded::Nothing;
    }
    let request: Request = match serde_json::from_str(text) {
        Ok(request) => request,
        Err(error) => {
            eprintln!("simpleremote-daemon: invalid request line: {error}");
            // A line that fails because one field has the wrong type still
            // carries a readable id.  Answering it turns a request that never
            // came back into an error the caller's callback receives.
            return Forwarded::Reply(Reply::error(
                best_effort_request_id(text),
                &format!("invalid request: {error}"),
            ));
        }
    };
    let payload = match encode_payload(&request) {
        Ok(payload) => payload,
        Err(message) => return Forwarded::Reply(Reply::error(request.id, &message)),
    };
    if needs_correlation(&request.op) {
        if let Ok(mut table) = ops.lock() {
            if table.len() >= MAX_TRACKED_REQUESTS && !table.contains_key(&request.id) {
                return Forwarded::Reply(Reply::error(
                    request.id,
                    &format!(
                        "the agent has left {MAX_TRACKED_REQUESTS} reads unanswered; \
                         refusing to track another"
                    ),
                ));
            }
            table.insert(request.id, request.op.clone());
        }
    }
    Forwarded::Wire(format!("{}\t{}\t{}\n", request.id, request.op, payload))
}

/// Only `read` and `read-config` replies need their op to decide whether to
/// peel the agent's inner base64 layer, so recording any other op would grow
/// the correlation table for nothing.
fn needs_correlation(op: &str) -> bool {
    matches!(op, "read" | "read-config")
}

/// The `id` of a line that is not a `Request`.  0 is the sentinel for a line
/// with no usable id; Vim's own ids start at 1, so it never resolves a real
/// request.
fn best_effort_request_id(line: &str) -> u64 {
    serde_json::from_str::<serde_json::Value>(line)
        .ok()
        .and_then(|value| value.get("id").and_then(serde_json::Value::as_u64))
        .unwrap_or(0)
}

/// Read one bounded record and discard the remainder of an oversized record
/// through its newline, so the next well-formed record is still served.
/// `BufRead::read_line` and `read_until` can provide neither guarantee: they
/// grow one allocation until a newline arrives.
fn read_record<R: BufRead>(
    reader: &mut R,
    what: &str,
    limit: usize,
) -> Option<Result<Vec<u8>, String>> {
    let mut bytes = Vec::new();
    let mut too_long = false;

    loop {
        let available = match reader.fill_buf() {
            Ok(available) => available,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            // A read error on either pipe ends the stream, which is how this
            // bridge has always treated it.
            Err(_) => break,
        };
        if available.is_empty() {
            break;
        }

        let newline = available.iter().position(|byte| *byte == b'\n');
        let content_len = newline.unwrap_or(available.len());
        let consumed = newline.map_or(available.len(), |position| position + 1);
        if !too_long {
            // The CR of a CRLF is framing, so retain one extra byte until the
            // record is finished and strip it before enforcing the limit.
            if bytes.len().saturating_add(content_len) > limit.saturating_add(1) {
                bytes.clear();
                too_long = true;
            } else {
                bytes.extend_from_slice(&available[..content_len]);
            }
        }
        reader.consume(consumed);

        if newline.is_some() {
            return Some(finish_record(bytes, too_long, what, limit));
        }
    }

    if bytes.is_empty() && !too_long {
        return None;
    }
    Some(finish_record(bytes, too_long, what, limit))
}

fn finish_record(
    mut bytes: Vec<u8>,
    too_long: bool,
    what: &str,
    limit: usize,
) -> Result<Vec<u8>, String> {
    if bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    if too_long || bytes.len() > limit {
        return Err(format!("{what} line exceeds {limit} bytes"));
    }
    Ok(bytes)
}

/// The base64 payload for one request, mirroring what Vim's historical
/// `Send()` produced.
fn encode_payload(request: &Request) -> Result<String, String> {
    let raw: Vec<u8> = match request.op.as_str() {
        "ping" => Vec::new(),
        "read" | "read-config" | "list" | "list-meta" | "list-encoded" | "list-meta-encoded" => {
            request.path.as_bytes().to_vec()
        }
        "exec" | "grep" => request.command.as_bytes().to_vec(),
        "write" => {
            if request.path.is_empty() {
                return Err("write requires a path".to_string());
            }
            let inner = match (&request.content_b64, &request.content) {
                (Some(encoded), _) => {
                    // Validate now so a corrupt payload fails here, with a
                    // message, rather than as an agent-side decode error.
                    BASE64
                        .decode(encoded.as_bytes())
                        .map_err(|error| format!("invalid content_b64: {error}"))?;
                    encoded.clone()
                }
                (None, Some(content)) => BASE64.encode(content.as_bytes()),
                (None, None) => return Err("write requires content or content_b64".to_string()),
            };
            let mut raw = request.path.as_bytes().to_vec();
            raw.push(b'\t');
            raw.extend_from_slice(inner.as_bytes());
            raw
        }
        _ => {
            // Unknown operations still travel to the agent, which answers
            // `unknown operation: …` — the same message the legacy path saw.
            request.path.as_bytes().to_vec()
        }
    };
    Ok(BASE64.encode(raw))
}

/// Agent → Vim.  Returns when the transport closes its stdout.
fn forward_replies(ops: &Ops, child_stdout: process::ChildStdout) {
    let mut reader = BufReader::new(child_stdout);
    pump_replies(ops, &mut reader, MAX_RECORD_BYTES, &mut emit);
}

/// The reply half of the bridge, over any reader for the same reason
/// `pump_requests` is generic.  These bytes arrive from another machine, so
/// the bound here is the one that matters most.
fn pump_replies<R: BufRead>(ops: &Ops, agent: &mut R, limit: usize, reply: &mut dyn FnMut(&Reply)) {
    while let Some(record) = read_record(agent, "agent reply", limit) {
        let line = match record {
            Ok(line) => line,
            Err(message) => {
                // The id led the discarded record, so nothing here can resolve
                // the request it belonged to; Vim's request timeout does that.
                // Reporting it is what tells the user why.
                eprintln!("simpleremote-daemon: {message}");
                continue;
            }
        };
        if line.is_empty() {
            continue;
        }
        let Some(answer) = parse_reply(ops, &line) else {
            continue;
        };
        reply(&answer);
    }
}

fn parse_reply(ops: &Ops, line: &[u8]) -> Option<Reply> {
    let mut fields = line.splitn(3, |byte| *byte == b'\t');
    let id = std::str::from_utf8(fields.next()?)
        .ok()?
        .parse::<u64>()
        .ok()?;
    let status = fields.next()?;
    let encoded = fields.next().unwrap_or(&[]);
    let op = ops
        .lock()
        .ok()
        .and_then(|mut table| table.remove(&id))
        .unwrap_or_default();
    let ok = status == b"ok";
    let mut payload = match BASE64.decode(encoded) {
        Ok(payload) => payload,
        Err(error) => {
            return Some(Reply::error(
                id,
                &format!("invalid agent reply encoding: {error}"),
            ));
        }
    };
    if ok && (op == "read" || op == "read-config") {
        // The agent base64-encodes file bodies before the protocol layer
        // encodes the whole payload; peel the inner layer here so Vim never
        // has to.
        payload = match BASE64.decode(&payload) {
            Ok(content) => content,
            Err(error) => {
                return Some(Reply::error(
                    id,
                    &format!("invalid file encoding from agent: {error}"),
                ));
            }
        };
    }
    Some(Reply::from_bytes(id, ok, payload))
}

enum Data {
    Text(String),
    Base64(String),
}

struct Reply {
    id: u64,
    ok: bool,
    data: Data,
}

impl Reply {
    fn error(id: u64, message: &str) -> Self {
        Reply {
            id,
            ok: false,
            data: Data::Text(message.to_string()),
        }
    }

    fn from_bytes(id: u64, ok: bool, bytes: Vec<u8>) -> Self {
        // Vim's json_decode() drops U+0000, so a NUL-bearing payload is the
        // one byte class valid UTF-8 would still lose: send it encoded.
        if bytes.contains(&0) {
            return Reply {
                id,
                ok,
                data: Data::Base64(BASE64.encode(bytes)),
            };
        }
        let data = match String::from_utf8(bytes) {
            Ok(text) => Data::Text(text),
            Err(error) => Data::Base64(BASE64.encode(error.into_bytes())),
        };
        Reply { id, ok, data }
    }

    fn to_json(&self) -> String {
        match &self.data {
            Data::Text(text) => {
                serde_json::json!({"id": self.id, "ok": self.ok, "data": text}).to_string()
            }
            Data::Base64(encoded) => {
                serde_json::json!({"id": self.id, "ok": self.ok, "data_b64": encoded}).to_string()
            }
        }
    }
}

/// One `write_all` under the stdout lock keeps lines whole even though two
/// threads emit them.
fn emit(reply: &Reply) {
    let mut line = reply.to_json();
    line.push('\n');
    let mut stdout = io::stdout().lock();
    let _ = stdout.write_all(line.as_bytes());
    let _ = stdout.flush();
}

/// Exercise the bridge in-process: one request through the encoder, one agent
/// reply back through the decoder, and the bound that keeps a runaway producer
/// from growing this process.  `--self-test` runs this before an installer is
/// allowed to replace a working daemon, because a version string only shows
/// that the file is not corrupt.
pub fn self_test() -> Result<(), String> {
    let request: Request =
        serde_json::from_str(r#"{"id":1,"op":"write","path":"/f","content":"hi\n"}"#)
            .map_err(|error| format!("the bridge cannot parse its own request shape: {error}"))?;
    let payload = encode_payload(&request)?;
    let decoded = BASE64
        .decode(payload.as_bytes())
        .map_err(|error| format!("the bridge produced a payload it cannot decode: {error}"))?;
    if decoded != format!("/f\t{}", BASE64.encode("hi\n")).into_bytes() {
        return Err("the bridge encoded a write the agent would not understand".to_string());
    }

    let ops: Ops = Arc::new(Mutex::new(HashMap::new()));
    let Forwarded::Wire(wire) = prepare_request(&ops, br#"{"id":7,"op":"read","path":"/f"}"#)
    else {
        return Err("the bridge refused a well-formed read request".to_string());
    };
    if wire != format!("7\tread\t{}\n", BASE64.encode("/f")) {
        return Err("the bridge assembled an agent record the agent would reject".to_string());
    }

    let inner = BASE64.encode("print('hi')\n");
    let line = format!("7\tok\t{}", BASE64.encode(&inner));
    let reply = parse_reply(&ops, line.as_bytes())
        .ok_or_else(|| "the bridge dropped a well-formed agent reply".to_string())?;
    if reply.to_json() != r#"{"data":"print('hi')\n","id":7,"ok":true}"# {
        return Err("the bridge did not peel the agent's inner encoding".to_string());
    }

    // A record with no newline in sight must be refused, not assembled.
    match read_record(&mut io::Cursor::new(b"0123456789\n".to_vec()), "request", 8) {
        Some(Err(_)) => {}
        _ => return Err("the bridge no longer bounds an oversized record".to_string()),
    }

    // A line serde cannot turn into a Request is answered with the id it
    // carries; checked here without going through prepare_request, which would
    // print to the stderr an installer shows the user.
    if best_effort_request_id(r#"{"id":9,"op":"read","path":[]}"#) != 9 {
        return Err("a malformed request line no longer yields its id".to_string());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(json: &str) -> Request {
        serde_json::from_str(json).unwrap()
    }

    fn decode(payload: &str) -> Vec<u8> {
        BASE64.decode(payload).unwrap()
    }

    #[test]
    fn payloads_mirror_the_legacy_vim_encoding() {
        assert_eq!(
            decode(&encode_payload(&request(r#"{"id":1,"op":"ping"}"#)).unwrap()),
            b""
        );
        assert_eq!(
            decode(&encode_payload(&request(r#"{"id":2,"op":"read","path":"/a b"}"#)).unwrap()),
            b"/a b"
        );
        assert_eq!(
            decode(
                &encode_payload(&request(
                    r#"{"id":6,"op":"list-meta-encoded","path":"/a b"}"#
                ))
                .unwrap()
            ),
            b"/a b"
        );
        assert_eq!(
            decode(
                &encode_payload(&request(r#"{"id":3,"op":"exec","command":"ls -la"}"#)).unwrap()
            ),
            b"ls -la"
        );
        let write = encode_payload(&request(
            r#"{"id":4,"op":"write","path":"/f","content":"hi\n"}"#,
        ))
        .unwrap();
        assert_eq!(
            decode(&write),
            format!("/f\t{}", BASE64.encode("hi\n")).as_bytes()
        );
        let write = encode_payload(&request(
            r#"{"id":5,"op":"write","path":"/f","content_b64":"aGkK"}"#,
        ))
        .unwrap();
        assert_eq!(decode(&write), b"/f\taGkK");
    }

    #[test]
    fn write_validates_its_arguments() {
        assert!(encode_payload(&request(r#"{"id":1,"op":"write","path":"/f"}"#)).is_err());
        assert!(encode_payload(&request(r#"{"id":1,"op":"write","content":"x"}"#)).is_err());
        assert!(
            encode_payload(&request(
                r#"{"id":1,"op":"write","path":"/f","content_b64":"%%%"}"#
            ))
            .is_err()
        );
    }

    fn table(entries: &[(u64, &str)]) -> Ops {
        Arc::new(Mutex::new(
            entries
                .iter()
                .map(|(id, op)| (*id, op.to_string()))
                .collect(),
        ))
    }

    #[test]
    fn replies_peel_the_inner_layer_only_for_reads() {
        let ops = table(&[(1, "read"), (2, "exec"), (3, "read")]);
        let inner = BASE64.encode("print('hi')\n");
        let line = format!("1\tok\t{}", BASE64.encode(&inner));
        let reply = parse_reply(&ops, line.as_bytes()).unwrap();
        assert_eq!(
            reply.to_json(),
            r#"{"data":"print('hi')\n","id":1,"ok":true}"#
        );

        let line = format!("2\tok\t{}", BASE64.encode("output"));
        let reply = parse_reply(&ops, line.as_bytes()).unwrap();
        assert_eq!(reply.to_json(), r#"{"data":"output","id":2,"ok":true}"#);

        // An error for a read op carries a plain message, not a file body.
        let line = format!("3\terror\t{}", BASE64.encode("not a file: /x"));
        let reply = parse_reply(&ops, line.as_bytes()).unwrap();
        assert_eq!(
            reply.to_json(),
            r#"{"data":"not a file: /x","id":3,"ok":false}"#
        );
        assert!(ops.lock().unwrap().is_empty());
    }

    #[test]
    fn nul_bearing_payloads_travel_as_base64() {
        // Valid UTF-8, but json_decode() would silently truncate it.
        let ops = table(&[(11, "exec")]);
        let bytes = b"a\0b";
        let line = format!("11\tok\t{}", BASE64.encode(bytes));
        let reply = parse_reply(&ops, line.as_bytes()).unwrap();
        assert_eq!(
            reply.to_json(),
            format!(
                r#"{{"data_b64":"{}","id":11,"ok":true}}"#,
                BASE64.encode(bytes)
            )
        );
    }

    #[test]
    fn non_utf8_payloads_travel_as_base64() {
        let ops = table(&[(9, "read")]);
        let bytes = [0xffu8, 0xfe, b'a'];
        let inner = BASE64.encode(bytes);
        let line = format!("9\tok\t{}", BASE64.encode(&inner));
        let reply = parse_reply(&ops, line.as_bytes()).unwrap();
        assert_eq!(
            reply.to_json(),
            format!(
                r#"{{"data_b64":"{}","id":9,"ok":true}}"#,
                BASE64.encode(bytes)
            )
        );
    }

    fn empty_ops() -> Ops {
        Arc::new(Mutex::new(HashMap::new()))
    }

    fn pump(input: &str, limit: usize) -> (Ops, String, Vec<String>) {
        let ops = empty_ops();
        let mut agent = Vec::new();
        let mut replies = Vec::new();
        pump_requests(
            &ops,
            &mut io::Cursor::new(input.as_bytes()),
            &mut agent,
            limit,
            &mut |reply| replies.push(reply.to_json()),
        );
        (ops, String::from_utf8(agent).unwrap(), replies)
    }

    /// The defect: an unparseable line was reported on stderr and nothing was
    /// written to stdout, so Vim's pending entry for that id was resolved only
    /// by its 15-second timeout — a write that neither succeeded nor failed.
    #[test]
    fn an_unparseable_request_is_answered_with_the_id_it_carries() {
        let ops = empty_ops();
        // `content` typed wrong: serde refuses the Request, the id is right
        // there in the line.
        let line = br#"{"id":17,"op":"write","path":"/srv/x","content":["a"]}"#;
        let Forwarded::Reply(reply) = prepare_request(&ops, line) else {
            panic!("a malformed request line was not answered at all");
        };
        assert_eq!(reply.id, 17);
        assert!(!reply.ok);
        assert!(
            reply.to_json().contains("invalid request"),
            "{}",
            reply.to_json()
        );
        assert!(
            ops.lock().unwrap().is_empty(),
            "a request that was never forwarded must not be tracked"
        );

        // Only a line with no id at all falls back to the sentinel.
        let Forwarded::Reply(reply) = prepare_request(&ops, b"not json at all") else {
            panic!("a line that is not JSON was not answered");
        };
        assert_eq!(reply.id, 0);
        assert_eq!(best_effort_request_id(r#"{"id":42,"op":[]}"#), 42);
        assert_eq!(best_effort_request_id("not json"), 0);
    }

    #[test]
    fn every_request_line_is_either_forwarded_or_answered() {
        let (_, agent, replies) = pump(
            concat!(
                "\n",
                r#"{"id":17,"op":"write","path":"/srv/x","content":["a"]}"#,
                "\n",
                r#"{"id":18,"op":"ping"}"#,
                "\n",
                r#"{"id":19,"op":"write","path":"/f"}"#,
                "\n",
            ),
            MAX_RECORD_BYTES,
        );
        assert_eq!(
            agent, "18\tping\t\n",
            "only the valid request reached the agent"
        );
        assert_eq!(replies.len(), 2);
        assert!(replies[0].contains(r#""id":17"#), "{}", replies[0]);
        assert!(replies[1].contains(r#""id":19"#), "{}", replies[1]);
    }

    /// The defect: `read_line` grew one String until the next newline arrived,
    /// so a producer that never sends one grew the daemon until the machine
    /// ran out of memory, and the record could not be skipped afterwards.
    #[test]
    fn the_bounded_reader_reports_an_oversized_record_and_resumes() {
        let input = b"0123456789\n{\"id\":3,\"op\":\"ping\"}\r\n";
        let mut reader = io::Cursor::new(&input[..]);
        assert_eq!(
            read_record(&mut reader, "request", 8).unwrap().unwrap_err(),
            "request line exceeds 8 bytes"
        );
        assert_eq!(
            read_record(&mut reader, "request", 64).unwrap().unwrap(),
            br#"{"id":3,"op":"ping"}"#
        );
        assert!(read_record(&mut reader, "request", 64).is_none());

        // A record of exactly the limit plus its CRLF framing is not oversized.
        let mut exact = io::Cursor::new(&b"12345678\r\n"[..]);
        assert_eq!(
            read_record(&mut exact, "request", 8).unwrap().unwrap(),
            b"12345678"
        );

        // An unterminated record still ends the stream rather than spinning.
        let mut truncated = io::Cursor::new(&b"partial"[..]);
        assert_eq!(
            read_record(&mut truncated, "request", 64).unwrap().unwrap(),
            b"partial"
        );
        assert!(read_record(&mut truncated, "request", 64).is_none());
    }

    /// A producer that never sends a newline: a Vim channel that died
    /// mid-write, or an ssh peer streaming from another machine.  One chunk is
    /// handed out `left` times, so the stream costs nothing to produce and the
    /// only thing that can grow is the reader's own buffer.
    struct Runaway {
        chunk: Vec<u8>,
        offset: usize,
        left: usize,
    }

    impl io::Read for Runaway {
        fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
            let taken = {
                let available = self.fill_buf()?;
                let taken = available.len().min(out.len());
                out[..taken].copy_from_slice(&available[..taken]);
                taken
            };
            self.consume(taken);
            Ok(taken)
        }
    }

    impl BufRead for Runaway {
        fn fill_buf(&mut self) -> io::Result<&[u8]> {
            if self.left == 0 {
                return Ok(&[]);
            }
            Ok(&self.chunk[self.offset..])
        }

        fn consume(&mut self, amount: usize) {
            self.offset += amount;
            if self.offset >= self.chunk.len() {
                self.offset = 0;
                self.left -= 1;
            }
        }
    }

    /// The defect this guards is a memory ceiling, and removing the ceiling
    /// changes nothing else the caller can see: the oversized record is still
    /// reported and the stream is still resynchronised.  So the assertion has
    /// to be about the heap, or it stays green on a daemon that grows until
    /// the machine runs out of memory.
    #[test]
    fn a_stream_that_never_sends_a_newline_is_discarded_not_assembled() {
        // 256 MiB, produced 64 KiB at a time, with no newline anywhere in it.
        let mut runaway = Runaway {
            chunk: vec![b'x'; 64 * 1024],
            offset: 0,
            left: 4096,
        };
        let baseline = crate::heap::watch();
        let outcome = read_record(&mut runaway, "request", 1024);
        let peak = crate::heap::peak_above(baseline);
        assert_eq!(
            outcome.unwrap().unwrap_err(),
            "request line exceeds 1024 bytes"
        );
        assert!(
            peak < 16 * 1024 * 1024,
            "the reader retained {peak} bytes of a 256 MiB stream it had to discard"
        );
    }

    #[test]
    fn an_oversized_request_is_reported_and_the_next_one_is_still_served() {
        let mut input = "x".repeat(200);
        input.push('\n');
        input.push_str(r#"{"id":18,"op":"ping"}"#);
        input.push('\n');
        let (_, agent, replies) = pump(&input, 32);
        assert_eq!(replies.len(), 1);
        assert!(
            replies[0].contains("request line exceeds 32 bytes")
                && replies[0].contains(r#""id":0"#),
            "{}",
            replies[0]
        );
        assert_eq!(
            agent, "18\tping\t\n",
            "the daemon stopped serving after an oversized record"
        );
    }

    #[test]
    fn an_oversized_agent_reply_is_skipped_and_the_next_one_is_delivered() {
        let ops = table(&[(5, "exec")]);
        let mut input = "y".repeat(200);
        input.push('\n');
        input.push_str(&format!("5\tok\t{}\n", BASE64.encode("out")));
        let mut replies = Vec::new();
        pump_replies(
            &ops,
            &mut io::Cursor::new(input.as_bytes()),
            32,
            &mut |reply| replies.push(reply.to_json()),
        );
        assert_eq!(
            replies,
            vec![r#"{"data":"out","id":5,"ok":true}"#.to_string()]
        );
    }

    /// The correlation table exists only to decide whether a reply needs the
    /// agent's inner layer peeled, and an agent that never answers must not be
    /// able to grow it without bound.
    #[test]
    fn the_correlation_table_tracks_only_reads_and_stays_bounded() {
        let (ops, agent, replies) = pump(
            concat!(
                r#"{"id":1,"op":"ping"}"#,
                "\n",
                r#"{"id":2,"op":"exec","command":"ls"}"#,
                "\n",
                r#"{"id":3,"op":"write","path":"/f","content":"x"}"#,
                "\n",
            ),
            MAX_RECORD_BYTES,
        );
        assert!(replies.is_empty());
        assert_eq!(agent.lines().count(), 3);
        assert!(
            ops.lock().unwrap().is_empty(),
            "an op whose reply needs no peeling must not be tracked"
        );

        let ops = empty_ops();
        for id in 1..=MAX_TRACKED_REQUESTS as u64 {
            let line = format!(r#"{{"id":{id},"op":"read","path":"/f"}}"#);
            assert!(matches!(
                prepare_request(&ops, line.as_bytes()),
                Forwarded::Wire(_)
            ));
        }
        assert_eq!(ops.lock().unwrap().len(), MAX_TRACKED_REQUESTS);
        let line = format!(r#"{{"id":{},"op":"read","path":"/f"}}"#, u64::MAX);
        let Forwarded::Reply(reply) = prepare_request(&ops, line.as_bytes()) else {
            panic!("the correlation table grew past its ceiling");
        };
        assert!(!reply.ok);
        assert_eq!(ops.lock().unwrap().len(), MAX_TRACKED_REQUESTS);
    }

    #[test]
    fn the_self_test_exercises_the_bridge() {
        self_test().unwrap();
    }

    #[test]
    fn malformed_reply_lines_are_dropped_or_reported() {
        let ops = table(&[(4, "exec")]);
        assert!(parse_reply(&ops, b"garbage").is_none());
        assert!(parse_reply(&ops, b"x\tok\tAA==").is_none());
        let reply = parse_reply(&ops, b"4\tok\t!!!").unwrap();
        assert!(!reply.ok);
        assert!(reply.to_json().contains("invalid agent reply encoding"));
    }
}
