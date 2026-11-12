#!/usr/bin/env python3
"""Exercise only the activation menu; never replace the real user's dotfiles."""
import fcntl
import os
from pathlib import Path
import pty
import select
import subprocess
import sys
import tempfile
import termios
import time

library = str(Path(sys.argv[1]).resolve())
shell = os.environ.get("BASH", "/bin/bash")
program = r'''
set -euo pipefail
source "$ACTIVATION_TEST_LIB"
MC_TARGET="$ACTIVATION_TEST_TARGET"
MC_STATE="$ACTIVATION_TEST_STATE"
MC_CONFLICTS=2
MC_REPLACE="$ACTIVATION_TEST_REPLACE"
MC_TARGET_EXPLICIT="$ACTIVATION_TEST_EXPLICIT"
mc_show_prepared_configs() { printf '  prepared fixture files\n'; }
mc_activate_prepared_configs() {
  printf 'activated\n' > "$ACTIVATION_TEST_RESULT"
  MC_CONFLICTS=0
}
mc_offer_activation
printf '\nACTIVATION_TEST_RESULT=%s\n' "$MC_CONFLICTS"
'''


def attach_terminal():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


with tempfile.TemporaryDirectory(prefix="my-configs-activation-", dir=os.getenv("TMPDIR", "/tmp")) as directory:
    root = Path(directory)

    def run(name, reply, expected, *, tty=True, explicit=False, replace=False, own_home=True):
        marker = root / name
        env = os.environ.copy()
        env.update(
            ACTIVATION_TEST_LIB=library,
            ACTIVATION_TEST_TARGET=os.environ["HOME"] if own_home else str(root),
            ACTIVATION_TEST_STATE=str(root / "state"),
            ACTIVATION_TEST_RESULT=str(marker),
            ACTIVATION_TEST_EXPLICIT="1" if explicit else "0",
            ACTIVATION_TEST_REPLACE="1" if replace else "0",
        )
        expect_prompt = tty and not explicit and not replace and own_home
        if not tty:
            result = subprocess.run([shell, "-c", program], env=env, input=reply,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
            code, output = result.returncode, result.stdout
        else:
            master, slave = pty.openpty()
            process = subprocess.Popen([shell, "-c", program], env=env, stdin=slave,
                                       stdout=slave, stderr=slave, preexec_fn=attach_terminal,
                                       close_fds=True)
            os.close(slave)
            output = bytearray()
            sent = False
            deadline = time.monotonic() + 10
            try:
                while time.monotonic() < deadline:
                    ready, _, _ = select.select([master], [], [], 0.05)
                    if ready:
                        try:
                            chunk = os.read(master, 65536)
                        except OSError:
                            break
                        if not chunk:
                            break
                        output.extend(chunk)
                    if expect_prompt and not sent and "Выбор [2]:".encode() in output:
                        os.write(master, reply)
                        sent = True
                    if process.poll() is not None and not ready:
                        break
                if process.poll() is None:
                    process.kill()
                code = process.wait()
            finally:
                os.close(master)
        text = bytes(output).decode(errors="replace")
        assert code == 0, (name, code, text)
        assert ("Выбор [2]:" in text) == expect_prompt, (name, text)
        assert marker.exists() == expected, (name, text)
        assert f"ACTIVATION_TEST_RESULT={0 if expected else 2}" in text, (name, text)

    run("yes", b"1\n", True)
    run("default-no", b"\n", False)
    run("explicit-no", b"2\n", False)
    run("invalid-then-yes", b"invalid\n1\n", True)
    run("eof", b"\x04", False)
    run("noninteractive", b"1\n", False, tty=False)
    run("explicit-target", b"1\n", False, explicit=True)
    run("replace-flag", b"1\n", False, replace=True)
    run("another-target", b"1\n", False, own_home=False)

print("Activation menu: explicit approval, decline, EOF and automation guards OK")
