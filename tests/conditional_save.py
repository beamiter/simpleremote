#!/usr/bin/env python3
"""Real shell-agent byte snapshots and optimistic conflict checks (no SSH)."""
import base64
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile

agent = Path(__file__).resolve().parent.parent / 'bin/simpleremote-agent.sh'

def exchange(proc, ident, op, payload):
    proc.stdin.write(str(ident).encode() + b'\t' + op.encode() + b'\t' + base64.b64encode(payload) + b'\n')
    proc.stdin.flush()
    reply = proc.stdout.readline().rstrip(b'\n').split(b'\t', 2)
    assert reply[0] == str(ident).encode(), reply
    return reply[1], base64.b64decode(reply[2])

with tempfile.TemporaryDirectory(prefix='simpleremote-snapshot-') as tmp:
    path = Path(tmp) / 'data'
    proc = subprocess.Popen(['sh', str(agent)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        for i, content in enumerate([b'', b'abc', b'a\r\nb\r\n', b'\0\xff\n\x80', b'x\n\n']):
            path.write_bytes(content)
            path.chmod(0o700)
            status, data = exchange(proc, i * 10, 'read-snapshot', os.fsencode(path))
            assert status == b'ok', data
            token, encoded = data.split(b'\t', 1)
            assert token.decode() == hashlib.sha256(content).hexdigest()
            assert base64.b64decode(encoded) == content
            updated = content + b'\x00new'
            status, saved = exchange(proc, i * 10 + 1, 'write-checked', os.fsencode(path) + b'\t' + token + b'\t' + base64.b64encode(updated))
            assert status == b'ok', saved
            assert saved.decode() == hashlib.sha256(updated).hexdigest()
            assert path.read_bytes() == updated
            assert path.stat().st_mode & 0o777 == 0o700
            status, _ = exchange(proc, i * 10 + 2, 'write-checked', os.fsencode(path) + b'\t' + token + b'\t' + base64.b64encode(b'stale'))
            assert status == b'error'
            assert path.read_bytes() == updated
            path.unlink()
            status, _ = exchange(proc, i * 10 + 3, 'write-checked', os.fsencode(path) + b'\t' + saved + b'\t' + base64.b64encode(b'recreate'))
            assert status == b'error'
            assert not path.exists()
            assert not list(Path(tmp).glob('.simpleremote.*'))
        proc.stdin.close()
        assert proc.wait(timeout=3) == 0
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
print('conditional_save: ok')
