#!/usr/bin/env python3
"""Exercise delete confirmation with real terminal input and Vim timers."""
import os
import pty
import select
import subprocess
import tempfile
import time
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='simpleremote-confirm-') as tmp:
    result = Path(tmp) / 'result'
    env = os.environ | {
        'PATH': str(repo / 'tests/fixtures') + os.pathsep + os.environ['PATH'],
        'SIMPLEREMOTE_TEST_ROOT': str(repo),
        'SIMPLEREMOTE_TEST_TARGET': 'fixture-target',
        'SIMPLEREMOTE_CONFIRM_RESULT': str(result),
        'TERM': 'xterm',
    }
    master, slave = pty.openpty()
    process = subprocess.Popen(
        ['vim', '-Nu', 'NONE', '-n', '-i', 'NONE', '-S', str(repo / 'tests/tree_confirm.vim')],
        stdin=slave, stdout=slave, stderr=slave, env=env,
    )
    os.close(slave)
    output = bytearray()
    answered = False
    deadline = time.monotonic() + 20
    try:
        while process.poll() is None and time.monotonic() < deadline:
            if not select.select([master], [], [], 0.1)[0]:
                continue
            try:
                output.extend(os.read(master, 65536))
            except OSError:
                break
            if not answered and b'[C]ancel:' in output:
                time.sleep(0.5)
                os.write(master, b'd')
                answered = True
        process.wait(timeout=2)
        assert answered, 'delete confirmation prompt was not shown'
        assert process.returncode == 0, f'Vim exited {process.returncode}'
        assert result.exists(), 'Vim did not finish the regression'
        assert not result.read_text(), result.read_text()
    except Exception:
        if result.exists(): print(result.read_text())
        print(output.decode(errors='replace'))
        raise
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
print('tree_confirm: ok')
