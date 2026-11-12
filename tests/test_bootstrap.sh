#!/usr/bin/env bash
# Isolated regression checks. No HOME reassignment, sudo, packages or network.
# Test doubles are invoked indirectly by the sourced bootstrap functions.
# shellcheck disable=SC2329
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/bootstrap.sh
source "$TEST_ROOT/lib/bootstrap.sh"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/my-configs-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
PASS=0
pass() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$PASS" "$1"; }
assert_same() { cmp -s "$1" "$2" || { printf 'Files differ: %s %s\n' "$1" "$2" >&2; exit 1; }; }

# The checker must not create its target or contact the network.
if bash "$TEST_ROOT/setup.sh" --check --no-fonts --target-dir "$TEST_TMP/not-created" >"$TEST_TMP/check.log" 2>&1; then
  printf 'Check unexpectedly accepted an empty destination\n' >&2; exit 1
fi
[[ ! -e "$TEST_TMP/not-created" ]]
(cd "$TEST_TMP" && bash "$TEST_ROOT/setup.sh" --help >/dev/null)
pass 'read-only check and invocation outside the checkout'

MC_TARGET="$TEST_TMP/user files"
MC_STATE="$MC_TARGET/.local/state/my-configs"
MC_BACKUP_DIR='' MC_REPLACE=0 MC_CONFLICTS=0 MC_UPDATE=0
mkdir -p "$MC_STATE/templates"
printf 'original template\n' > "$TEST_TMP/template"
mc_install_config "$TEST_TMP/template" "$MC_TARGET/.zshrc" zshrc
assert_same "$TEST_TMP/template" "$MC_TARGET/.zshrc"
mc_install_config "$TEST_TMP/template" "$MC_TARGET/.zshrc" zshrc
[[ -z "$MC_BACKUP_DIR" ]]
pass 'first install and identical rerun need no backup'

printf 'personal customization\n' >> "$MC_TARGET/.zshrc"
cp "$MC_TARGET/.zshrc" "$TEST_TMP/edited"
printf 'new template\n' > "$TEST_TMP/template"
mc_install_config "$TEST_TMP/template" "$MC_TARGET/.zshrc" zshrc
assert_same "$TEST_TMP/edited" "$MC_TARGET/.zshrc"
assert_same "$TEST_TMP/template" "$MC_TARGET/.zshrc.my-configs-new"
[[ $MC_CONFLICTS == 1 ]]
pass 'edited dotfile remains intact and gets a reviewable candidate'

MC_REPLACE=1
mc_install_config "$TEST_TMP/template" "$MC_TARGET/.zshrc" zshrc
assert_same "$TEST_TMP/edited" "$MC_BACKUP_DIR/zshrc"
assert_same "$TEST_TMP/template" "$MC_TARGET/.zshrc"
[[ -f "$MC_STATE/templates/zshrc" ]]
pass 'explicit replacement saves the exact previous configuration'

# A local Git remote gives the same fetch/checkout behavior without networking.
REMOTE="$TEST_TMP/remote"
git init --quiet "$REMOTE"
git -C "$REMOTE" config user.name 'Bootstrap test'
git -C "$REMOTE" config user.email 'bootstrap-test@example.invalid'
printf 'first\n' > "$REMOTE/component.zsh"
git -C "$REMOTE" add component.zsh
git -C "$REMOTE" commit --quiet -m first
FIRST=$(git -C "$REMOTE" rev-parse HEAD)
DEST="$MC_TARGET/component"
mc_install_repo component "$DEST" "$REMOTE" "$FIRST" "$FIRST" component.zsh
printf 'custom plugin\n' > "$DEST/custom-user-file"
mc_install_repo component "$DEST" "$REMOTE" "$FIRST" "$FIRST" component.zsh
[[ -f "$DEST/custom-user-file" ]]
pass 'repeat dependency install preserves untracked custom files'

printf 'second\n' > "$REMOTE/component.zsh"
git -C "$REMOTE" add component.zsh
git -C "$REMOTE" commit --quiet -m second
SECOND=$(git -C "$REMOTE" rev-parse HEAD)
MC_UPDATE=1
printf 'my change\n' >> "$DEST/component.zsh"
if (mc_install_repo component "$DEST" "$REMOTE" "$SECOND" "$SECOND" component.zsh) >"$TEST_TMP/dirty.log" 2>&1; then
  printf 'Update unexpectedly discarded an edited dependency\n' >&2; exit 1
fi
grep -q 'my change' "$DEST/component.zsh"
[[ $(git -C "$DEST" rev-parse HEAD) == "$FIRST" ]]
pass 'dependency update refuses local modifications'

git -C "$DEST" checkout -- component.zsh
mc_install_repo component "$DEST" "$REMOTE" "$SECOND" "$SECOND" component.zsh
[[ $(git -C "$DEST" rev-parse HEAD) == "$SECOND" && -f "$DEST/custom-user-file" ]]
pass 'clean managed dependency updates without deleting custom files'

mkdir -p "$MC_TARGET/unmanaged"
printf 'custom framework\n' > "$MC_TARGET/unmanaged/component.zsh"
mc_install_repo unmanaged "$MC_TARGET/unmanaged" "$REMOTE" "$SECOND" "$SECOND" component.zsh
grep -q 'custom framework' "$MC_TARGET/unmanaged/component.zsh"
pass 'unmanaged framework is never replaced'

# Reproduce the macOS missing-fc-cache path without changing PATH or HOME.
(
  MC_OS=Darwin
  command() { if [[ "${1:-}" == -v && "${2:-}" == fc-cache ]]; then return 1; fi; builtin command "$@"; }
  mc_download_verified() { :; }
  mc_install_fonts
)
pass 'font install succeeds without Linux font-cache command'

# Simulate a failed gsettings lookup: font configuration stays best effort.
(
  MC_OS=Linux MC_TARGET="$HOME" DBUS_SESSION_BUS_ADDRESS='test-session'
  gsettings() {
    if [[ "$1" == list-schemas ]]; then printf 'org.gnome.Terminal.ProfilesList\n'; else return 1; fi
  }
  mc_configure_terminal_font
)
pass 'unavailable desktop profile does not abort installation'

# A rejected download must never replace an existing destination.
printf 'known-good\n' > "$TEST_TMP/font.ttf"
cp "$TEST_TMP/font.ttf" "$TEST_TMP/font.previous"
if (
  curl() {
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == -o ]]; then printf 'corrupt download\n' > "$2"; return 0; fi
      shift
    done
    return 1
  }
  mc_download_verified 'https://example.invalid/font' "$TEST_TMP/font.ttf" 0000000000000000000000000000000000000000
) >"$TEST_TMP/font.log" 2>&1; then
  printf 'Corrupt download was accepted\n' >&2; exit 1
fi
assert_same "$TEST_TMP/font.previous" "$TEST_TMP/font.ttf"
pass 'download verification preserves the existing file on failure'


# A symlink is a customization even if it points at the previous template bytes.
MC_TARGET="$TEST_TMP/user files"
MC_REPLACE=0 MC_BACKUP_DIR=''
cp "$TEST_TMP/template" "$TEST_TMP/personal-zshrc"
rm "$MC_TARGET/.zshrc"
ln -s "$TEST_TMP/personal-zshrc" "$MC_TARGET/.zshrc"
printf 'next template\n' > "$TEST_TMP/template"
mc_install_config "$TEST_TMP/template" "$MC_TARGET/.zshrc" zshrc
[[ -L "$MC_TARGET/.zshrc" ]]
assert_same "$MC_STATE/templates/zshrc" "$TEST_TMP/personal-zshrc"
assert_same "$TEST_TMP/template" "$MC_TARGET/.zshrc.my-configs-new"
pass 'a symlink to the old template remains a user customization'

# Root protection must operate on resolved paths, not only a literal slash.
ln -s / "$TEST_TMP/root-link"
for target in /tmp/.. "$TEST_TMP/root-link" "$TEST_TMP/does-not-exist/../../../.."; do
  if bash "$TEST_ROOT/setup.sh" --check --no-fonts --target-dir "$target" >"$TEST_TMP/root-check.log" 2>&1; then
    printf 'Root target was accepted: %s\n' "$target" >&2; exit 1
  fi
  grep -q 'Refusing to use /' "$TEST_TMP/root-check.log"
done
[[ ! -e "$TEST_TMP/does-not-exist" ]]
pass 'root aliases are rejected without creating directories'

# A copied installer and small fake components exercise actual flag forwarding.
COPY="$TEST_TMP/installer"
FORWARD_TARGET="$TEST_TMP/forward-target"
mkdir -p "$COPY/lib" "$COPY/scripts" "$FORWARD_TARGET"
cp "$TEST_ROOT/setup.sh" "$COPY/setup.sh"
cp "$TEST_ROOT/lib/bootstrap.sh" "$COPY/lib/bootstrap.sh"
# This test isolates argument forwarding from package availability.
printf '\nmc_require_commands() { :; }\nmc_install_fzf() { :; }\n' >> "$COPY/lib/bootstrap.sh"
printf '# minimal test configuration\n' > "$COPY/zshrc"
cp "$COPY/zshrc" "$COPY/p10k.zsh"
while IFS='|' read -r name relative url ref commit entry; do
  mkdir -p "$FORWARD_TARGET/$relative/$(dirname "$entry")"
  : > "$FORWARD_TARGET/$relative/$entry"
done < <(mc_sources)
cat > "$COPY/scripts/devops.sh" <<'DEVOPS'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MC_TEST_DEVOPS_ARGS"
DEVOPS
MC_TEST_DEVOPS_ARGS="$TEST_TMP/devops-args" bash "$COPY/setup.sh" \
  --skip-packages --no-fonts --no-chsh --devops --target-dir "$FORWARD_TARGET" >"$TEST_TMP/forward.log"
grep -qx -- '--skip-packages' "$TEST_TMP/devops-args"
pass '--skip-packages is forwarded to the optional profile'

# The doctor must reject modified or stale managed dependencies.
(
  MC_TARGET="$TEST_TMP/doctor"
  MC_NO_FONTS=1
  mkdir -p "$MC_TARGET"
  printf '# valid config\n' > "$MC_TARGET/.zshrc"
  cp "$MC_TARGET/.zshrc" "$MC_TARGET/.p10k.zsh"
  mc_sources() { printf 'component|component|%s|%s|%s|component.zsh\n' "$REMOTE" "$SECOND" "$SECOND"; }
  mc_check_fzf() { :; }
  mc_install_repo component "$MC_TARGET/component" "$REMOTE" "$SECOND" "$SECOND" component.zsh
  mc_check_installation >/dev/null
  printf 'personal change\n' >> "$MC_TARGET/component/component.zsh"
  if mc_check_installation >"$TEST_TMP/doctor.log" 2>&1; then exit 1; fi
  grep -q 'tracked modifications' "$TEST_TMP/doctor.log"
  git -C "$MC_TARGET/component" checkout -- component.zsh
  git -C "$MC_TARGET/component" remote set-url origin "$TEST_TMP/foreign-remote"
  if mc_check_installation >"$TEST_TMP/doctor-origin.log" 2>&1; then exit 1; fi
  grep -q 'pinned revision/origin' "$TEST_TMP/doctor-origin.log"
)
pass 'doctor verifies managed origins, revisions and tracked changes'
# Font integrity must not depend on the caller's Git object format.
SHA_REPO="$TEST_TMP/sha256-repo"
if git init --quiet --object-format=sha256 "$SHA_REPO" 2>/dev/null; then
  printf 'known font fixture\n' > "$TEST_TMP/font-fixture"
  expected_font_hash=$(mc_sha256 "$TEST_TMP/font-fixture")
  (
    cd "$SHA_REPO"
    curl() { printf 'An intact font was downloaded again\n' >&2; return 1; }
    mc_download_verified 'https://example.invalid/font' "$TEST_TMP/font-fixture" "$expected_font_hash"
  )
  pass 'font verification works from a SHA-256 Git repository'
else
  printf 'skip - installed Git does not support SHA-256 repositories\n'
fi
# A modern managed fzf supplies its own --zsh integration without distro docs.
(
  MC_TARGET="$TEST_TMP/fzf-target"
  MC_STATE="$MC_TARGET/.local/state/my-configs"
  MC_UPDATE=0
  mkdir -p "$TEST_TMP/fzf-payload"
  printf '#!/bin/sh\nprintf "fzf fixture\\n"\n' > "$TEST_TMP/fzf-payload/fzf"
  tar -czf "$TEST_TMP/fzf-archive.tar.gz" -C "$TEST_TMP/fzf-payload" fzf
  FZF_ARCHIVE_HASH=$(mc_sha256 "$TEST_TMP/fzf-archive.tar.gz")
  FZF_BINARY_HASH=$(mc_sha256 "$TEST_TMP/fzf-payload/fzf")
  mc_fzf_spec() { printf '0.75.0|linux_amd64|%s|%s\n' "$FZF_ARCHIVE_HASH" "$FZF_BINARY_HASH"; }
  curl() {
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == -o ]]; then
        cp "$TEST_TMP/fzf-archive.tar.gz" "$2"
        printf 'download\n' >> "$TEST_TMP/fzf-downloads"
        return 0
      fi
      shift
    done
    return 1
  }
  mc_install_fzf
  mc_check_fzf
  mc_install_fzf
  [[ $(wc -l < "$TEST_TMP/fzf-downloads") -eq 1 ]]
  [[ -x "$MC_TARGET/.local/share/my-configs/bin/fzf" ]]
  cp "$MC_TARGET/.local/share/my-configs/bin/fzf" "$TEST_TMP/good-fzf"
  printf '# local change\n' >> "$MC_TARGET/.local/share/my-configs/bin/fzf"
  if mc_check_fzf >"$TEST_TMP/fzf-check.log" 2>&1; then exit 1; fi
  if (mc_install_fzf) >"$TEST_TMP/fzf-install.log" 2>&1; then exit 1; fi
  grep -q 'local change' "$MC_TARGET/.local/share/my-configs/bin/fzf"
  cp "$TEST_TMP/good-fzf" "$MC_TARGET/.local/share/my-configs/bin/fzf"
  MC_UPDATE=1
  FZF_BINARY_HASH=0000000000000000000000000000000000000000000000000000000000000000
  if (mc_install_fzf) >"$TEST_TMP/fzf-corrupt.log" 2>&1; then exit 1; fi
  assert_same "$TEST_TMP/good-fzf" "$MC_TARGET/.local/share/my-configs/bin/fzf"
)
pass 'managed fzf is verified, idempotent and preserves edits or failed updates'
printf '%s total bootstrap regression checks passed\n' "$PASS"
