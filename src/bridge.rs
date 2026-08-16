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
    let mut agent = BufWriter::new(child_stdin);
    let stdin = io::stdin();
    let mut line = String::new();
    loop {
        line.clear();
        match stdin.lock().read_line(&mut line) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        let trimmed = line.trim_end_matches(['\n', '\r']);
        if trimmed.is_empty() {
            continue;
        }
        let request: Request = match serde_json::from_str(trimmed) {
            Ok(request) => request,
            Err(error) => {
                // A malformed line has no usable id; report it where Vim's
                // err_cb collects transport noise instead of hanging a request.
                eprintln!("simpleremote-daemon: invalid request line: {error}");
                continue;
            }
        };
        let payload = match encode_payload(&request) {
            Ok(payload) => payload,
            Err(message) => {
                emit(&Reply::error(request.id, &message));
                continue;
            }
        };
        if let Ok(mut table) = ops.lock() {
            table.insert(request.id, request.op.clone());
        }
        let wire = format!("{}\t{}\t{}\n", request.id, request.op, payload);
        if agent.write_all(wire.as_bytes()).is_err() || agent.flush().is_err() {
            break;
        }
    }
    // Dropping the writer closes the agent's stdin: its read loop ends and the
    // transport exits, which is what unblocks the reply side.
}

/// The base64 payload for one request, mirroring what Vim's historical
/// `Send()` produced.
fn encode_payload(request: &Request) -> Result<String, String> {
    let raw: Vec<u8> = match request.op.as_str() {
        "ping" => Vec::new(),
        "read" | "read-config" | "list" | "list-meta" => request.path.as_bytes().to_vec(),
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
    let mut line = Vec::new();
    loop {
        line.clear();
        match reader.read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        while line
            .last()
            .is_some_and(|byte| *byte == b'\n' || *byte == b'\r')
        {
            line.pop();
        }
        if line.is_empty() {
            continue;
        }
        let Some(reply) = parse_reply(ops, &line) else {
            continue;
        };
        emit(&reply);
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
