vim9script

# The Rust runtime's JSON bridge and the self-installing agent, driven through
# the stub ssh under tests/fixtures.  Everything here also runs against the
# legacy transport at the end, so both protocols keep the same contract.

set nocompatible
set nomore

const REPO = $SIMPLEREMOTE_TEST_ROOT
const TARGET = $SIMPLEREMOTE_TEST_TARGET
const BASE = tempname()
const AGENT_DIR = BASE .. '-agents'
mkdir(BASE .. '/dir/inner', 'p')
mkdir(BASE .. '/local', 'p')
writefile(['plain', 'text ✓'], BASE .. '/utf8.txt')
writefile(0zC3A9FFFE0A, BASE .. '/latin.bin')
writefile(['inner'], BASE .. '/dir/inner/deep.txt')
writefile(['top'], BASE .. '/dir/top.txt')
writefile(['local file'], BASE .. '/local/up.txt')
writefile([repeat('L', 500)], BASE .. '/large.txt')
mkdir(BASE .. '/local/tree/sub', 'p')
writefile(['one'], BASE .. '/local/tree/one.txt')
writefile(['two'], BASE .. '/local/tree/sub/two.txt')

g:simpleremote_use_daemon = 1
g:simpleremote_daemon_path = REPO .. '/target/debug/simpleremote-daemon'
g:simpleremote_use_sshfs = 'never'
g:simpleremote_workspace_mode = 'virtual'
g:simpleremote_open_tree_on_connect = 0
g:simpleremote_change_directory = 'none'
# Not installed yet: the first connection must bootstrap it.
g:simpleremote_agent = AGENT_DIR .. '/json/simpleremote-agent.sh'
execute 'set runtimepath^=' .. fnameescape(REPO)
runtime plugin/simpleremote.vim

def WaitFor(Condition: func(): bool, timeout: float = 6.0): bool
  var started = reltime()
  while reltimefloat(reltime(started)) < timeout
    if Condition()
      return true
    endif
    sleep 10m
  endwhile
  return Condition()
enddef

def Ready(): bool
  return get(get(g:, 'simpleremote_workspace', {}), 'root', '') ==# BASE
    && get(g:, 'simpleremote_status', '') ==# 'ssh:' .. TARGET
enddef

var events: list<string> = []
augroup TransportBridgeTest
  autocmd!
  autocmd User SimpleRemoteFileCopied add(events, 'copied:' .. g:simpleremote_event.local)
  autocmd User SimpleRemoteFileUploaded add(events, 'uploaded:' .. g:simpleremote_event.remote)
augroup END

def Exercise(protocol: string, agent: string)
  execute 'SimpleRemoteConnect ssh ' .. TARGET .. ' ' .. fnameescape(BASE)
  assert_true(WaitFor(Ready), protocol .. ': workspace did not become ready')
  assert_equal(protocol, get(g:simpleremote_workspace, 'protocol', ''),
    'workspace does not report the transport protocol')
  assert_true(filereadable(agent), protocol .. ': agent was not bootstrapped')
  assert_equal(readfile(REPO .. '/bin/simpleremote-agent.sh'), readfile(agent),
    protocol .. ': bootstrapped agent differs from the bundled one')
  assert_equal('rwx------', getfperm(agent))

  # Byte-exact reads: UTF-8 travels as JSON text, anything else as base64.
  var done = false
  var body = ''
  g:SimpleRemoteReadFile('utf8.txt', (ok, content) => {
    body = ok ? content : 'ERR ' .. content
    done = true
  })
  assert_true(WaitFor(() => done), protocol .. ': utf8 read did not finish')
  assert_equal("plain\ntext ✓\n", body)
  done = false
  g:SimpleRemoteReadFile('latin.bin', (ok, content) => {
    body = ok ? content : 'ERR ' .. content
    done = true
  })
  assert_true(WaitFor(() => done), protocol .. ': binary read did not finish')
  assert_equal(readfile(BASE .. '/latin.bin', 'b')[0] .. "\n", body)

  # Buffer round trip through :w, including a final newline and non-ASCII.
  g:VimrcRemoteOpen(BASE .. '/utf8.txt')
  assert_true(WaitFor(() => get(get(b:, 'vimrc_remote', {}), 'path', '')
    ==# BASE .. '/utf8.txt' && getline(1) ==# 'plain'),
    protocol .. ': remote buffer did not load')
  setline(2, 'edited ✓ é')
  write
  assert_true(WaitFor(() => readfile(BASE .. '/utf8.txt') ==# ['plain', 'edited ✓ é']),
    protocol .. ': remote write did not land')
  assert_true(WaitFor(() => !&modified), protocol .. ': buffer stayed modified')

  # Public helpers over the persistent agent connection.
  done = false
  var output = ''
  g:SimpleRemoteExecute('printf "%s" "$PWD"', (ok, text) => {
    output = ok ? text : 'ERR ' .. text
    done = true
  })
  assert_true(WaitFor(() => done), protocol .. ': execute did not finish')
  assert_equal(BASE, output)

  done = false
  g:SimpleRemoteWriteFile('written.txt', "from api\n", (ok, text) => {
    output = ok ? text : 'ERR ' .. text
    done = true
  })
  assert_true(WaitFor(() => done), protocol .. ': write did not finish')
  assert_equal(BASE .. '/written.txt', output)
  assert_equal(['from api'], readfile(BASE .. '/written.txt'))

  done = false
  var listing: any = []
  g:SimpleRemoteListDirectory('dir', (ok, entries) => {
    listing = ok ? entries : 'ERR ' .. string(entries)
    done = true
  })
  assert_true(WaitFor(() => done), protocol .. ': list did not finish')
  assert_equal(v:t_list, type(listing))
  var names = mapnew(listing, (_, entry) => entry.name .. ':' .. entry.type)
  sort(names)
  assert_equal(['inner:d', 'top.txt:f'], names)
  assert_true(listing[0].size >= 0 && listing[0].mtime > 0,
    protocol .. ': list-meta fields are missing')

  # Transfers: file and directory in both directions, force semantics.
  var result: dict<any> = {}
  done = false
  assert_true(g:SimpleRemoteDownload('dir/top.txt', BASE .. '/local/top.txt', {},
    (ok, info) => {
      result = extend({ok: ok}, info)
      done = true
    }))
  assert_true(WaitFor(() => done), protocol .. ': download did not finish')
  assert_true(result.ok, protocol .. ': download failed: ' .. string(result))
  assert_equal(['top'], readfile(BASE .. '/local/top.txt'))
  assert_true(WaitFor(() => index(events, 'copied:' .. BASE .. '/local/top.txt') >= 0),
    protocol .. ': SimpleRemoteFileCopied did not fire')

  done = false
  assert_true(g:SimpleRemoteDownload('dir', BASE .. '/local/dircopy',
    {recursive: true}, (ok, info) => {
      result = extend({ok: ok}, info)
      done = true
    }))
  assert_true(WaitFor(() => done), protocol .. ': recursive download did not finish')
  assert_true(result.ok, protocol .. ': recursive download failed: ' .. string(result))
  assert_equal(['inner'], readfile(BASE .. '/local/dircopy/inner/deep.txt'))

  done = false
  assert_true(g:SimpleRemoteUpload(BASE .. '/local/up.txt', 'dir/up.txt', {},
    (ok, info) => {
      result = extend({ok: ok}, info)
      done = true
    }))
  assert_true(WaitFor(() => done), protocol .. ': upload did not finish')
  assert_true(result.ok, protocol .. ': upload failed: ' .. string(result))
  assert_equal(['local file'], readfile(BASE .. '/dir/up.txt'))
  assert_true(WaitFor(() => index(events, 'uploaded:' .. BASE .. '/dir/up.txt') >= 0),
    protocol .. ': SimpleRemoteFileUploaded did not fire')

  done = false
  assert_true(g:SimpleRemoteUpload(BASE .. '/local/tree', 'dir/tree', {},
    (ok, info) => {
      result = extend({ok: ok}, info)
      done = true
    }))
  assert_true(WaitFor(() => done), protocol .. ': directory upload did not finish')
  assert_true(result.ok, protocol .. ': directory upload failed: ' .. string(result))
  assert_equal(['two'], readfile(BASE .. '/dir/tree/sub/two.txt'))

  # A second upload onto an existing destination is refused without force.
  done = false
  assert_true(g:SimpleRemoteUpload(BASE .. '/local/up.txt', 'dir/up.txt', {},
    (ok, info) => {
      result = extend({ok: ok}, info)
      done = true
    }))
  assert_true(WaitFor(() => done), protocol .. ': refused upload did not finish')
  assert_false(result.ok, protocol .. ': upload replaced an existing file silently')

  # Clean up for the next protocol run.
  silent! bwipeout!
  delete(BASE .. '/local/top.txt')
  delete(BASE .. '/local/dircopy', 'rf')
  delete(BASE .. '/dir/up.txt')
  delete(BASE .. '/dir/tree', 'rf')
  delete(BASE .. '/written.txt')
  writefile(['plain', 'text ✓'], BASE .. '/utf8.txt')
  events = []
  SimpleRemoteDisconnect
  assert_true(WaitFor(() => get(g:, 'simpleremote_status', '') ==# 'disconnected'))
enddef

def MessagesMatch(pattern: string): bool
  return execute('messages') =~# pattern
enddef

# A request that fails has to reach its callback in the shape that callback
# was declared for.  The buffer read types its payload list<string>, so a bare
# message aborted the timeout timer with E1013 and hid the timeout itself.
# Nothing here is protocol specific, so one transport proves it.
def ReadTimeoutIsReported()
  execute 'SimpleRemoteConnect ssh ' .. TARGET .. ' ' .. fnameescape(BASE)
  assert_true(WaitFor(Ready), 'timeout: workspace did not become ready')

  # The agent answers one request per line, in order, so this sleep keeps the
  # read behind it queued well past the timeout below.
  var slept = false
  g:SimpleRemoteExecute('sleep 2', (ok, text) => {
    slept = true
  })
  g:simpleremote_request_timeout = 200
  messages clear
  g:VimrcRemoteOpen(BASE .. '/utf8.txt')
  assert_true(WaitFor(() => MessagesMatch('request timed out: read'), 3.0),
    'timed-out read did not report the timeout: ' .. execute('messages'))
  assert_false(MessagesMatch('E1013'),
    'timed-out read aborted with a type error: ' .. execute('messages'))

  unlet g:simpleremote_request_timeout
  assert_true(WaitFor(() => slept), 'the blocking command never finished')
  silent! bwipeout!
  SimpleRemoteDisconnect
  assert_true(WaitFor(() => get(g:, 'simpleremote_status', '') ==# 'disconnected'))
enddef

# A file past g:simpleremote_large_file_bytes is not read on sight: the buffer
# holds a hint, nothing has crossed the transport, and the read happens only
# once the user confirms it.
def LargeFileWaitsForConfirmation()
  execute 'SimpleRemoteConnect ssh ' .. TARGET .. ' ' .. fnameescape(BASE)
  assert_true(WaitFor(Ready), 'deferred: workspace did not become ready')

  g:simpleremote_large_file_bytes = 64
  g:VimrcRemoteOpen(BASE .. '/large.txt')
  assert_true(WaitFor(() => getline(1) =~# 'has not been read'),
    'the oversized file was not deferred')
  assert_match('501 B, over the 64 B', join(getline(1, '$'), "\n"),
    'the hint does not say what it measured')
  assert_true(empty(get(b:, 'vimrc_remote', {})),
    'a deferred buffer must not claim to be backed by the file')
  assert_false(&modifiable, 'a deferred buffer is not editable')
  assert_equal('', &filetype, 'a deferred buffer must not detect a filetype')
  assert_match('SimpleRemoteLoad', maparg('<CR>', 'n'),
    'the hint does not offer its confirmation')

  # Saving the hint over the file it stands for is the one mistake that would
  # cost data, so the write is refused instead.
  silent! write
  assert_equal([repeat('L', 500)], readfile(BASE .. '/large.txt'),
    'writing a deferred buffer replaced the remote file')

  SimpleRemoteLoad
  assert_true(WaitFor(() => getline(1) ==# repeat('L', 500)),
    'the confirmed read did not land')
  assert_equal(BASE .. '/large.txt', get(get(b:, 'vimrc_remote', {}), 'path', ''))
  assert_true(&modifiable, 'the loaded buffer stayed read-only')
  assert_equal('', maparg('<CR>', 'n'), 'the confirmation mapping outlived it')
  assert_true(empty(get(b:, 'vimrc_remote_deferred', {})))

  # Under the limit nothing changes: the file is simply there.
  g:simpleremote_large_file_bytes = 1048576
  g:VimrcRemoteOpen(BASE .. '/utf8.txt')
  assert_true(WaitFor(() => getline(1) ==# 'plain'),
    'a small file did not open directly')
  assert_true(empty(get(b:, 'vimrc_remote_deferred', {})))

  unlet g:simpleremote_large_file_bytes
  silent! bwipeout!
  silent! bwipeout!
  SimpleRemoteDisconnect
  assert_true(WaitFor(() => get(g:, 'simpleremote_status', '') ==# 'disconnected'))
enddef

def Run()
  var capabilities = g:SimpleRemoteRuntimeCapabilities()
  assert_equal(1, get(capabilities, 'bridge_protocol', 0),
    'runtime does not advertise the bridge protocol')
  assert_true(index(get(capabilities, 'actions', []), 'upload') >= 0)

  Exercise('json', AGENT_DIR .. '/json/simpleremote-agent.sh')
  ReadTimeoutIsReported()
  LargeFileWaitsForConfirmation()

  # The same contract without any runtime: Vim drives ssh and base64 itself,
  # and bootstraps the agent through the same heredoc launcher.
  g:simpleremote_use_daemon = 0
  g:simpleremote_agent = AGENT_DIR .. '/legacy/simpleremote-agent.sh'
  Exercise('legacy', AGENT_DIR .. '/legacy/simpleremote-agent.sh')

  # An installed agent that drifted is replaced on the next connection.
  writefile(['#!/bin/sh', 'exit 9'], AGENT_DIR .. '/legacy/simpleremote-agent.sh')
  execute 'SimpleRemoteConnect ssh ' .. TARGET .. ' ' .. fnameescape(BASE)
  assert_true(WaitFor(Ready), 'reconnect over a drifted agent failed')
  assert_equal(readfile(REPO .. '/bin/simpleremote-agent.sh'),
    readfile(AGENT_DIR .. '/legacy/simpleremote-agent.sh'),
    'drifted agent was not replaced')
enddef

var failure = ''
try
  Run()
catch
  failure = v:exception .. ' @ ' .. v:throwpoint
finally
  silent! SimpleRemoteDisconnect
  delete(BASE, 'rf')
  delete(AGENT_DIR, 'rf')
endtry
if !empty(failure)
  add(v:errors, failure)
endif
if !empty(v:errors)
  writefile(v:errors, '/dev/stderr')
  cquit
endif
qall!
