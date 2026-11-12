#!/usr/bin/env python3
"""Load the installed shell in a real terminal without reading user history."""
import fcntl
import os
from pathlib import Path
import pty
import select
import subprocess
import sys
import termios
import time

target = Path(sys.argv[1]).resolve()
env = os.environ.copy()
env.update(
    ZDOTDIR=str(target),
    ZSH=str(target / ".oh-my-zsh"),
    ZSH_CUSTOM=str(target / ".oh-my-zsh/custom"),
    XDG_CACHE_HOME=str(target / ".cache"),
    HISTFILE="/dev/null",
    TERM="xterm-256color",
)
(target / ".cache").mkdir(exist_ok=True)
script = r"""
[[ $HISTFILE == /dev/null && $HISTSIZE == 50000 && $SAVEHIST == 50000 ]] \
  || { print -u2 -- "FAIL: history settings ($HISTFILE, $HISTSIZE, $SAVEHIST)"; exit 1; }
(( $+functions[_zsh_autosuggest_start] && $+functions[_zsh_highlight] )) \
  || { print -u2 'FAIL: suggestion/highlight functions'; exit 1; }
(( $+ZSH_AUTOSUGGEST_USE_ASYNC )) \
  || { print -u2 'FAIL: asynchronous suggestions'; exit 1; }
(( $+functions[fzf-file-widget] )) \
  || { print -u2 'FAIL: fzf file widget'; exit 1; }
[[ $(bindkey -M emacs '^[^F') == *fzf-file-widget* ]] \
  || { print -u2 'FAIL: emacs file-search binding'; exit 1; }
[[ $(bindkey -M viins '^[^F') == *fzf-file-widget* ]] \
  || { print -u2 'FAIL: viins file-search binding'; exit 1; }
unique_path=("${(@u)path}")
[[ ${#path} == ${#unique_path} ]] \
  || { print -u2 'FAIL: duplicate PATH entries'; exit 1; }
print -r -- MY_CONFIGS_PTY_OK
"""


def attach_terminal():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


master, slave = pty.openpty()
# Host-wide CI startup scripts can reset HISTFILE (macOS) or prompt in an
# independent compinit (Ubuntu). Load the installed user configuration only;
# its Oh My Zsh completion-security checks remain enabled.
proc = subprocess.Popen(
    ["zsh", "-d", "-i", "-c", script],
    stdin=slave, stdout=slave, stderr=slave, env=env,
    preexec_fn=attach_terminal, close_fds=True,
)
os.close(slave)
output = bytearray()
deadline = time.monotonic() + 30
try:
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.1)
        if ready:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            output.extend(chunk)
        if proc.poll() is not None and not ready:
            break
    if proc.poll() is None:
        proc.kill()
    code = proc.wait()
finally:
    os.close(master)
text = output.decode(errors="replace")
if code or "MY_CONFIGS_PTY_OK" not in text or "[ERROR]" in text or "failed to initialize" in text:
    print(text, file=sys.stderr)
    raise SystemExit(f"Installed zsh smoke failed (exit {code})")
print("Installed zsh: prompt, plugins, history and file-search bindings OK")
