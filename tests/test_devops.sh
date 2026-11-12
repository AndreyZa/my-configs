#!/usr/bin/env bash
# Regression tests for ownership, repeatability, rollback and read-only checks.
# OS package managers/mise are mocked; this is not a macOS integration test.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BASH_BIN=$(command -v bash)
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/my-configs-devops-test.XXXXXX")
trap 'rm -rf "$FIXTURE"' EXIT
BIN="$FIXTURE/bin"
TARGET="$FIXTURE/target"
LOG="$FIXTURE/calls"
mkdir -p "$BIN"
: > "$LOG"
cat > "$BIN/mise" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$1" in
  use)
    printf '# mocked mise: exact resolved versions\n[tools]\nkubectl = "1.36.3"\n' > "$MISE_GLOBAL_CONFIG_FILE"
    ;;
  install|reshim) ;;
  which) printf '%s\n' "$MISE_DATA_DIR/installs/mock/bin/$2"; exit 0 ;;
  *) exit 8 ;;
esac
mkdir -p "$MISE_SHIMS_DIR" "$MISE_DATA_DIR/installs/mock/bin"
for name in kubectl helm kubecolor terraform terragrunt ansible; do
  printf '#!/bin/sh\nexit 0\n' > "$MISE_SHIMS_DIR/$name"
  chmod +x "$MISE_SHIMS_DIR/$name"
  cp "$MISE_SHIMS_DIR/$name" "$MISE_DATA_DIR/installs/mock/bin/$name"
done
# Simulate a late failure after mise has already published some temporary shims.
if [ "$1" = use ] && [ "${FAKE_USE_FAIL:-0}" -eq 1 ]; then exit 7; fi
EOF
chmod +x "$BIN/mise"
run_profile() {
  env PATH="$BIN:/usr/bin:/bin" FAKE_LOG="$LOG" FAKE_USE_FAIL="${FAKE_USE_FAIL:-0}" \
    "$BASH_BIN" "$ROOT/scripts/devops.sh" --target-dir "$TARGET" --skip-packages "$@"
}
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# A check on an unconfigured target must not create it or call mise.
if run_profile --check > "$FIXTURE/output" 2>&1; then fail 'missing profile check succeeded'; fi
[ ! -e "$TARGET" ] || fail '--check created the target'
[ ! -s "$LOG" ] || fail '--check executed mise'

# A failed first install must not expose new shims or replace existing ones.
for failed_case in fresh existing; do
  TARGET="$FIXTURE/failed-$failed_case"
  if [ "$failed_case" = existing ]; then
    mkdir -p "$TARGET/.local/share/mise/shims"
    printf '#!/bin/sh\nprintf "user command\\n"\n' > "$TARGET/.local/share/mise/shims/kubectl"
    chmod +x "$TARGET/.local/share/mise/shims/kubectl"
    cp "$TARGET/.local/share/mise/shims/kubectl" "$FIXTURE/original-shim"
  fi
  if FAKE_USE_FAIL=1 run_profile > "$FIXTURE/output" 2>&1; then fail 'failed first install succeeded'; fi
  [ ! -e "$TARGET/.config/mise/conf.d/my-configs-devops.toml" ] || fail 'failed first install retained profile'
  [ ! -e "$TARGET/.local/share/mise/shims/helm" ] || fail 'failed first install exposed a new shim'
  if [ "$failed_case" = existing ]; then
    cmp -s "$TARGET/.local/share/mise/shims/kubectl" "$FIXTURE/original-shim" || fail 'failed install changed existing shim'
  else
    [ ! -e "$TARGET/.local/share/mise/shims" ] || fail 'failed install created live shims directory'
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
PROFILE="$TARGET/.config/mise/conf.d/my-configs-devops.toml"
[ -f "$PROFILE" ] || fail 'profile not created'
cp "$PROFILE" "$FIXTURE/first-profile"
run_profile > "$FIXTURE/output"
cmp -s "$PROFILE" "$FIXTURE/first-profile" || fail 'repeat changed the profile'
[ "$(grep -c '^use ' "$LOG")" -eq 1 ] || fail 'repeat resolved new versions'
[ "$(grep -c '^install ' "$LOG")" -eq 1 ] || fail 'repeat did not install pinned versions'
[ -z "$(find "$TARGET/.local/state/my-configs" -name 'devops-backup-*' -print)" ] || fail 'repeat made a backup'

# Unrelated user configuration must survive first install and repeat.
cmp -s "$TARGET/.config/mise/config.toml" "$FIXTURE/user-config" || fail 'global config changed'
cmp -s "$TARGET/.config/mise/conf.d/user.toml" "$FIXTURE/user-fragment" || fail 'user fragment changed'

# Locally modified managed files require an explicit update and a backup.
printf '\n# User edit\n' >> "$PROFILE"
cp "$PROFILE" "$FIXTURE/edited-profile"
cp "$LOG" "$FIXTURE/previous-log"
if run_profile > "$FIXTURE/output" 2>&1; then fail 'local edits were silently overwritten'; fi
cmp -s "$PROFILE" "$FIXTURE/edited-profile" || fail 'local edits lost'
cmp -s "$LOG" "$FIXTURE/previous-log" || fail 'conflict still executed mise'
run_profile --update > "$FIXTURE/output"
backup=$(find "$TARGET/.local/state/my-configs" -name my-configs-devops.toml -print | head -n 1)
[ -n "$backup" ] || fail 'update made no backup'
cmp -s "$backup" "$FIXTURE/edited-profile" || fail 'backup lost original edits'

# A failed resolver must not leave a half-written profile.
cp "$PROFILE" "$FIXTURE/good-profile"
if FAKE_USE_FAIL=1 run_profile --update > "$FIXTURE/output" 2>&1; then fail 'failed mise update succeeded'; fi
cmp -s "$PROFILE" "$FIXTURE/good-profile" || fail 'failed update was not rolled back'

# Successful checks are also read-only and do not execute mise or the tools.
cp "$LOG" "$FIXTURE/previous-log"
run_profile --check > "$FIXTURE/output"
cmp -s "$LOG" "$FIXTURE/previous-log" || fail 'successful --check executed mise'
# A surviving mise shim cannot hide a removed tool installation.
rm "$TARGET/.local/share/mise/installs/mock/bin/kubectl"
[ -x "$TARGET/.local/share/mise/shims/kubectl" ] || fail 'test shim unexpectedly missing'
if run_profile --check > "$FIXTURE/output" 2>&1; then fail 'removed executable check succeeded'; fi
cp "$TARGET/.local/share/mise/shims/kubectl" "$TARGET/.local/share/mise/installs/mock/bin/kubectl"
rm "$TARGET/.local/share/mise/shims/ansible"
if run_profile --check > "$FIXTURE/output" 2>&1; then fail 'missing shim check succeeded'; fi

# Never alter a pre-existing global lockfile.
printf 'foreign lock\n' > "$TARGET/.config/mise/mise.lock"
cp "$TARGET/.config/mise/mise.lock" "$FIXTURE/lock"
if run_profile --update > "$FIXTURE/output" 2>&1; then fail 'foreign global lock accepted'; fi
cmp -s "$TARGET/.config/mise/mise.lock" "$FIXTURE/lock" || fail 'foreign lock changed'
cmp -s "$TARGET/.config/mise/config.toml" "$FIXTURE/user-config" || fail 'global config changed at end'
cmp -s "$TARGET/.config/mise/conf.d/user.toml" "$FIXTURE/user-fragment" || fail 'user fragment changed at end'

# Exercise native manager dispatch only when no absolute-path mise can escape mocks.
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
    rm -f "$BIN/mise"
    : > "$LOG"
    env PATH="$BIN:/usr/bin:/bin" FAKE_LOG="$LOG" FAKE_USE_FAIL=0 \
      FAKE_PLATFORM="$platform" FAKE_TEMPLATE="$FIXTURE/mise-template" FAKE_BIN="$BIN" \
      "$BASH_BIN" "$ROOT/scripts/devops.sh" --target-dir "$FIXTURE/dispatch-$platform" > "$FIXTURE/output"
    if [ "$platform" = Linux ]; then
      grep -q '^extrepo enable mise$' "$LOG" || fail 'Ubuntu skipped official repo setup'
      grep -q '^apt-get install -y mise$' "$LOG" || fail 'Ubuntu skipped mise package'
      ! grep -q '^brew ' "$LOG" || fail 'Ubuntu called Homebrew'
    else
      grep -q '^brew install mise$' "$LOG" || fail 'macOS skipped Homebrew mise'
      ! grep -q '^apt-get ' "$LOG" || fail 'macOS called APT'
    fi
  done
fi

printf 'DevOps profile tests passed (mocked mise/package managers; user configuration preserved).\n'
