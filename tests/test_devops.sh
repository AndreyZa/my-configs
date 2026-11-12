#!/usr/bin/env bash
# Behavioural regression tests; native mise integration runs separately in CI.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BASH_BIN=$BASH
PYTHON_BIN=$(command -v python3)
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/my-configs-devops-test.XXXXXX")
trap 'rm -rf "$FIXTURE"' EXIT
BIN="$FIXTURE/bin"
TARGET="$FIXTURE/target"
LOG="$FIXTURE/calls"
mkdir -p "$BIN"
: > "$LOG"
cat > "$FIXTURE/mise-model.py" <<'PY'
import json, os, re, stat, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['FAKE_LOG'], 'a') as stream:
    stream.write(' '.join(args) + '\n')
profile = Path(os.environ['MISE_GLOBAL_CONFIG_FILE'])
data = Path(os.environ['MISE_DATA_DIR'])
shims = Path(os.environ['MISE_SHIMS_DIR'])
# Installing or resolving against the live config is itself a regression.
assert profile != Path(os.environ['FAKE_LIVE_PROFILE'])
assert Path(os.environ['MISE_CONFIG_DIR']) != Path(os.environ['FAKE_LIVE_PROFILE']).parent.parent

def read_tools():
    tools = {}
    for line in profile.read_text().splitlines():
        match = re.match(r'^("[^"]+"|[\w:-]+)\s*=\s*(.*)$', line)
        if not match:
            continue
        name = match[1].strip('"')
        value = match[2]
        if value.startswith('{'):
            tools[name] = dict(re.findall(r'(\w+)\s*=\s*"([^"]*)"', value))
        else:
            tools[name] = json.loads(value)
    return tools

def parse_key(key):
    # mise 2026.8.x interprets embedded CLI quotes as part of the tool name.
    # Reject that spelling instead of silently normalizing it in this model.
    assert '"' not in key, 'Quoted CLI key breaks older mise: ' + key
    match = re.fullmatch(r'tools\.([\w:-]+)(?:\.(\w+))?', key)
    assert match, key
    return match[1], match[2]

def names(tool):
    if tool == 'pipx:ansible-core':
        return ['ansible', 'ansible-playbook', 'ansible-galaxy', 'ansible-vault']
    if tool == 'uv':
        return ['uv', 'uvx']
    return [tool]

def location(name):
    tool = 'pipx:ansible-core' if name.startswith('ansible') else ('uv' if name == 'uvx' else name)
    value = read_tools()[tool]
    version = value['version'] if isinstance(value, dict) else value
    return data / 'installs' / tool.replace(':', '-') / version / 'bin' / name

def create_shim(name):
    shims.mkdir(parents=True, exist_ok=True)
    destination = shims / name
    if destination.exists() or destination.is_symlink():
        destination.unlink()
    destination.symlink_to(os.environ['FAKE_MISE_REAL'])

if args[0] == 'latest':
    print(os.environ.get('FAKE_LATEST_VERSION', '1.0.0'))
elif args[:2] == ['config', 'get']:
    name, field = parse_key(args[-1])
    value = read_tools().get(name)
    if field:
        value = value.get(field) if isinstance(value, dict) else None
    if value is None:
        sys.exit(1)
    print(value)
elif args[:2] == ['config', 'set']:
    name, field = parse_key(args[-2]); value = args[-1]
    tools = read_tools()
    if field:
        entry = tools.get(name, {})
        if isinstance(entry, str):
            entry = {'version': entry}
        entry[field] = value
        value = entry
    rendered = ('{ ' + ', '.join(k + ' = ' + json.dumps(v) for k, v in value.items()) + ' }') if isinstance(value, dict) else json.dumps(value)
    replacement = json.dumps(name) + ' = ' + rendered
    lines = profile.read_text().splitlines()
    for number, line in enumerate(lines):
        if re.match(r'^("' + re.escape(name) + r'"|' + re.escape(name) + r')\s*=', line):
            lines[number] = replacement
            break
    else:
        lines.append(replacement)
    profile.write_text('\n'.join(lines) + '\n')
elif args[0] == 'install':
    force = '--force' in args
    for tool in [arg for arg in args[1:] if not arg.startswith('-')]:
        for name in names(tool):
            executable = location(name)
            if force or not executable.exists():
                executable.parent.mkdir(parents=True, exist_ok=True)
                executable.write_text('#!/bin/sh\nprintf "' + name + '\\n"\n')
                executable.chmod(0o755)
            create_shim(name)
        if os.environ.get('FAKE_INSTALL_FAIL') == '1':
            sys.exit(7)
elif args[0] == 'reshim':
    for tool in read_tools():
        for name in names(tool):
            if location(name).exists():
                create_shim(name)
elif args[0] == 'which':
    print(location(args[1]))
else:
    raise RuntimeError('Unexpected mise invocation: ' + repr(args))
PY
cat > "$BIN/mise" <<'EOF'
#!/usr/bin/env bash
exec "$FAKE_PYTHON" "$FAKE_MISE_MODEL" "$@"
EOF
chmod +x "$BIN/mise"
run_profile() {
  env PATH="$BIN:/usr/bin:/bin" FAKE_LOG="$LOG" FAKE_INSTALL_FAIL="${FAKE_INSTALL_FAIL:-0}" \
    FAKE_LATEST_VERSION="${FAKE_LATEST_VERSION:-1.0.0}" FAKE_PYTHON="$PYTHON_BIN" \
    FAKE_MISE_MODEL="$FIXTURE/mise-model.py" FAKE_MISE_REAL="$BIN/mise" \
    FAKE_LIVE_PROFILE="$TARGET/.config/mise/conf.d/my-configs-devops.toml" \
    "$BASH_BIN" "$ROOT/scripts/devops.sh" --target-dir "$TARGET" --skip-packages "$@"
}
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
snapshot() {
  "$PYTHON_BIN" - "$TARGET" <<'PY'
import hashlib, json, os, stat, sys
from pathlib import Path
root=Path(sys.argv[1]); result={}
for p in [root, *sorted(root.rglob('*'))]:
    s=p.lstat(); row={'mode':stat.S_IMODE(s.st_mode),'mtime_ns':s.st_mtime_ns,'size':s.st_size}
    if p.is_symlink(): row['target']=os.readlink(p)
    elif p.is_file(): row['sha256']=hashlib.sha256(p.read_bytes()).hexdigest()
    result[str(p.relative_to(root))]=row
print(json.dumps(result,sort_keys=True))
PY
}

if run_profile --check > "$FIXTURE/output" 2>&1; then fail 'missing profile check succeeded'; fi
[ ! -e "$TARGET" ] || fail '--check created target'
[ ! -s "$LOG" ] || fail '--check executed mise'

# A partial first install must not expose shims or replace existing commands.
for failed_case in fresh existing; do
  TARGET="$FIXTURE/failed-$failed_case"
  if [ "$failed_case" = existing ]; then
    mkdir -p "$TARGET/.local/share/mise/shims"
    printf '#!/bin/sh\nexit 42\n' > "$TARGET/.local/share/mise/shims/kubectl"
    chmod +x "$TARGET/.local/share/mise/shims/kubectl"
    cp "$TARGET/.local/share/mise/shims/kubectl" "$FIXTURE/original-shim"
  fi
  if FAKE_INSTALL_FAIL=1 run_profile > "$FIXTURE/output" 2>&1; then fail 'failed first install succeeded'; fi
  [ ! -e "$TARGET/.config/mise/conf.d/my-configs-devops.toml" ] || fail 'failed install exposed profile'
  [ ! -e "$TARGET/.local/share/mise/shims/helm" ] || fail 'failed install exposed shim'
  if [ "$failed_case" = existing ]; then
    cmp -s "$TARGET/.local/share/mise/shims/kubectl" "$FIXTURE/original-shim" || fail 'existing shim changed'
  else
    [ ! -e "$TARGET/.local/share/mise/shims" ] || fail 'failed install created live shims'
  fi
done
TARGET="$FIXTURE/target"
: > "$LOG"
mkdir -p "$TARGET/.config/mise/conf.d"
printf '[tools]\nnode = "24"\n' > "$TARGET/.config/mise/config.toml"
printf '[tools]\nrust = "stable"\n' > "$TARGET/.config/mise/conf.d/user.toml"
cp "$TARGET/.config/mise/config.toml" "$FIXTURE/user-config"
cp "$TARGET/.config/mise/conf.d/user.toml" "$FIXTURE/user-fragment"
run_profile > "$FIXTURE/output"
grep -q 'tools.pipx:ansible-core.uvx_args' "$LOG" || fail 'backend option path was not exercised'
if grep -q 'tools\."' "$LOG"; then fail 'quoted CLI tool key was used'; fi
PROFILE="$TARGET/.config/mise/conf.d/my-configs-devops.toml"
MANIFEST="$TARGET/.local/state/my-configs/devops-executables.tsv"
[ -f "$PROFILE" ] || fail 'profile missing'
# Upgrade legacy path-only metadata without reinstalling healthy tools.
awk -F '\t' 'BEGIN {OFS="\t"} $1 == "profile_sha256" {print $1,$2} /^exe:/ && $1 != "exe:uv" && $1 != "exe:ansible-playbook" {sub(/^exe:/,"",$1); print $1,$2}' "$MANIFEST" > "$FIXTURE/v1-manifest"
cp "$FIXTURE/v1-manifest" "$MANIFEST"
: > "$LOG"
run_profile > "$FIXTURE/output"
if grep -q '^install ' "$LOG"; then fail 'metadata migration reinstalled healthy tools'; fi
grep -q '^schema' "$MANIFEST" || fail 'legacy manifest was not upgraded'
snapshot > "$FIXTURE/before.json"
cp "$LOG" "$FIXTURE/previous-log"
run_profile > "$FIXTURE/output"
snapshot > "$FIXTURE/after.json"
cmp -s "$FIXTURE/before.json" "$FIXTURE/after.json" || fail 'default repeat wrote managed tree'
cmp -s "$LOG" "$FIXTURE/previous-log" || fail 'default repeat called mise'
run_profile --check > "$FIXTURE/output"
cmp -s "$LOG" "$FIXTURE/previous-log" || fail '--check called mise'

# Resolving identical releases must preserve modes, contents and nanosecond mtimes.
: > "$LOG"
run_profile --update > "$FIXTURE/output"
snapshot > "$FIXTURE/after.json"
cmp -s "$FIXTURE/before.json" "$FIXTURE/after.json" || fail 'same-version update wrote managed tree'
if grep -Eq '^(install|reshim|config set) ' "$LOG"; then fail 'same-version update installed or rewrote config'; fi
[ -z "$(find "$TARGET/.local/state/my-configs" -name 'devops-backup-*' -print)" ] || fail 'same-version backup'

# Missing/corrupted binaries must be repaired, not mistaken for a no-op.
executable=$(awk -F '\t' '$1 == "exe:kubectl" {print $2}' "$MANIFEST")
rm "$executable"
if run_profile --check > "$FIXTURE/output" 2>&1; then fail 'missing binary check succeeded'; fi
: > "$LOG"
run_profile > "$FIXTURE/output"
grep -q '^install --force kubectl$' "$LOG" || fail 'missing binary was not repaired specifically'
run_profile --check > "$FIXTURE/output"
printf 'corrupt\n' >> "$executable"
: > "$LOG"
run_profile > "$FIXTURE/output"
grep -q '^install --force kubectl$' "$LOG" || fail 'corrupted binary was not repaired'
run_profile --check > "$FIXTURE/output"

# Broken shims require reshimming, without redownloading working tools.
rm "$TARGET/.local/share/mise/shims/ansible"
: > "$LOG"
run_profile > "$FIXTURE/output"
grep -q '^reshim$' "$LOG" || fail 'missing shim not repaired'
if grep -q '^install ' "$LOG"; then fail 'shim repair unnecessarily installed tools'; fi
rm "$TARGET/.local/share/mise/shims/helm"
ln -s /bin/true "$TARGET/.local/share/mise/shims/helm"
: > "$LOG"
run_profile > "$FIXTURE/output"
if grep -q '^install ' "$LOG"; then fail 'wrong shim target unnecessarily installed tools'; fi
[ "$(readlink "$TARGET/.local/share/mise/shims/helm")" = "$BIN/mise" ] || fail 'wrong shim target retained'

# A newer release creates exactly one backup, while a failed update stays private.
cp "$PROFILE" "$FIXTURE/old-profile"
FAKE_LATEST_VERSION=2.0.0 run_profile --update > "$FIXTURE/output"
[ "$(find "$TARGET/.local/state/my-configs" -name 'devops-backup-*' -print | wc -l | tr -d ' ')" -eq 1 ] || fail 'new release backup count'
backup=$(find "$TARGET/.local/state/my-configs" -path '*/devops-backup-*/my-configs-devops.toml' -print)
cmp -s "$backup" "$FIXTURE/old-profile" || fail 'backup content mismatch'
cp "$PROFILE" "$FIXTURE/good-profile"
cp "$MANIFEST" "$FIXTURE/good-manifest"
shim_before=$(readlink "$TARGET/.local/share/mise/shims/kubectl")
if FAKE_LATEST_VERSION=3.0.0 FAKE_INSTALL_FAIL=1 run_profile --update > "$FIXTURE/output" 2>&1; then fail 'failed update succeeded'; fi
cmp -s "$PROFILE" "$FIXTURE/good-profile" || fail 'failed update exposed profile'
cmp -s "$MANIFEST" "$FIXTURE/good-manifest" || fail 'failed update changed manifest'
[ "$(readlink "$TARGET/.local/share/mise/shims/kubectl")" = "$shim_before" ] || fail 'failed update changed shim'
[ "$(find "$TARGET/.local/state/my-configs" -name 'devops-backup-*' -print | wc -l | tr -d ' ')" -eq 1 ] || fail 'failed update made backup'

printf '\n# User edit\n' >> "$PROFILE"
cp "$PROFILE" "$FIXTURE/edited-profile"
cp "$LOG" "$FIXTURE/previous-log"
if run_profile > "$FIXTURE/output" 2>&1; then fail 'local edits accepted without update'; fi
cmp -s "$PROFILE" "$FIXTURE/edited-profile" || fail 'local edits lost'
cmp -s "$LOG" "$FIXTURE/previous-log" || fail 'conflict invoked mise'
printf 'foreign lock\n' > "$TARGET/.config/mise/mise.lock"
if run_profile --update > "$FIXTURE/output" 2>&1; then fail 'foreign global lock accepted'; fi
cmp -s "$TARGET/.config/mise/config.toml" "$FIXTURE/user-config" || fail 'foreign global config changed'
cmp -s "$TARGET/.config/mise/conf.d/user.toml" "$FIXTURE/user-fragment" || fail 'foreign fragment changed'

# APT/Homebrew dispatch remains covered without invoking real package managers.
if [ ! -x /opt/homebrew/bin/mise ] && [ ! -x /usr/local/bin/mise ] && [ ! -x /usr/bin/mise ]; then
  cp "$BIN/mise" "$FIXTURE/mise-template"
  cat > "$BIN/uname" <<'EOF'
#!/bin/sh
printf '%s\n' "$FAKE_PLATFORM"
EOF
  cat > "$BIN/id" <<'EOF'
#!/bin/sh
printf '0\n'
EOF
  cat > "$BIN/apt-get" <<'EOF'
#!/bin/sh
printf 'apt-get %s\n' "$*" >> "$FAKE_LOG"
case "$*" in 'install -y mise') cp "$FAKE_TEMPLATE" "$FAKE_BIN/mise"; chmod +x "$FAKE_BIN/mise" ;; esac
EOF
  cat > "$BIN/extrepo" <<'EOF'
#!/bin/sh
printf 'extrepo %s\n' "$*" >> "$FAKE_LOG"
EOF
  cat > "$BIN/brew" <<'EOF'
#!/bin/sh
printf 'brew %s\n' "$*" >> "$FAKE_LOG"
case "$*" in 'install mise') cp "$FAKE_TEMPLATE" "$FAKE_BIN/mise"; chmod +x "$FAKE_BIN/mise" ;; esac
EOF
  chmod +x "$BIN/uname" "$BIN/id" "$BIN/apt-get" "$BIN/extrepo" "$BIN/brew"
  for platform in Linux Darwin; do
    TARGET="$FIXTURE/dispatch-$platform"
    rm -f "$BIN/mise"
    : > "$LOG"
    env PATH="$BIN:/usr/bin:/bin" FAKE_LOG="$LOG" FAKE_PLATFORM="$platform" \
      FAKE_TEMPLATE="$FIXTURE/mise-template" FAKE_BIN="$BIN" FAKE_PYTHON="$PYTHON_BIN" \
      FAKE_MISE_MODEL="$FIXTURE/mise-model.py" FAKE_MISE_REAL="$BIN/mise" \
      FAKE_LIVE_PROFILE="$TARGET/.config/mise/conf.d/my-configs-devops.toml" \
      "$BASH_BIN" "$ROOT/scripts/devops.sh" --target-dir "$TARGET" > "$FIXTURE/output"
    if [ "$platform" = Linux ]; then
      grep -q '^extrepo enable mise$' "$LOG" || fail 'APT repository skipped'
      grep -q '^apt-get install -y mise$' "$LOG" || fail 'APT mise skipped'
    else
      grep -q '^brew install mise$' "$LOG" || fail 'Homebrew mise skipped'
      if grep -q '^apt-get ' "$LOG"; then fail 'macOS called APT'; fi
    fi
  done
fi
printf 'DevOps no-op, update, repair and ownership tests passed.\n'
