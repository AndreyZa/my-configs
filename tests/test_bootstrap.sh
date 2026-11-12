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
if "$BASH" "$TEST_ROOT/setup.sh" --check --no-fonts --target-dir "$TEST_TMP/not-created" >"$TEST_TMP/check.log" 2>&1; then
  printf 'Check unexpectedly accepted an empty destination\n' >&2; exit 1
fi
[[ ! -e "$TEST_TMP/not-created" ]]
(cd "$TEST_TMP" && "$BASH" "$TEST_ROOT/setup.sh" --help >/dev/null)
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
  # ShellCheck 0.9 cannot see this wrapper being called by mc_install_fonts.
  # shellcheck disable=SC2317
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
# macOS TMPDIR can be deep and /tmp or /var can be symlinks: count physical parents.
TEST_PHYSICAL_TMP=$(cd "$TEST_TMP" && pwd -P)
ROOT_PARENT_PATH="$TEST_PHYSICAL_TMP"
ROOT_DOT_PATH="$TEST_PHYSICAL_TMP"
ROOT_MISSING_PATH="$TEST_PHYSICAL_TMP/does-not-exist/.."
while [[ "$ROOT_PARENT_PATH" != / ]]; do
  ROOT_DOT_PATH="$ROOT_DOT_PATH/.."
  ROOT_MISSING_PATH="$ROOT_MISSING_PATH/.."
  ROOT_PARENT_PATH=$(dirname "$ROOT_PARENT_PATH")
done
ln -s / "$TEST_TMP/root-link"
for target in "$ROOT_DOT_PATH" "$TEST_TMP/root-link" "$ROOT_MISSING_PATH"; do
  if "$BASH" "$TEST_ROOT/setup.sh" --check --no-fonts --target-dir "$target" >"$TEST_TMP/root-check.log" 2>&1; then
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
cp "$TEST_ROOT/lib/migrate_zshrc.py" "$COPY/lib/migrate_zshrc.py"
# This test isolates argument forwarding from package availability.
printf '\nmc_require_commands() { :; }\nmc_install_fzf() { :; }\nmc_install_packages() { echo unexpected-package-install >&2; return 1; }\nmc_install_fonts() { echo unexpected-font-install >&2; return 1; }\n' >> "$COPY/lib/bootstrap.sh"
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
MC_TEST_DEVOPS_ARGS="$TEST_TMP/devops-args" "$BASH" "$COPY/setup.sh" \
  --skip-packages --no-fonts --no-chsh --devops --target-dir "$FORWARD_TARGET" >"$TEST_TMP/forward.log"
grep -qx -- '--skip-packages' "$TEST_TMP/devops-args"
pass '--skip-packages is forwarded to the optional profile'

# The doctor must reject modified or stale managed dependencies.
(
  MC_TARGET="$TEST_TMP/doctor"
  MC_STATE="$MC_TARGET/.local/state/my-configs"
  MC_NO_FONTS=1
  mkdir -p "$MC_TARGET"
  printf '# valid config\n' > "$MC_TARGET/.zshrc"
  cp "$MC_TARGET/.zshrc" "$MC_TARGET/.p10k.zsh"
  mc_sources() { printf 'component|component|%s|%s|%s|component.zsh\n' "$REMOTE" "$SECOND" "$SECOND"; }
  mc_check_fzf() { :; }
  mc_install_repo component "$MC_TARGET/component" "$REMOTE" "$SECOND" "$SECOND" component.zsh
  mc_check_installation >/dev/null
  cp "$MC_TARGET/component/.git/index" "$TEST_TMP/doctor-index-before"
  touch "$MC_TARGET/component/component.zsh"
  mc_check_installation >/dev/null
  assert_same "$TEST_TMP/doctor-index-before" "$MC_TARGET/component/.git/index"
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


# Default package installation never refreshes or upgrades a complete system.
(
  MC_OS=Linux MC_UPDATE=0
  MC_TEST_APT_MISSING=''
  MC_TEST_APT_LOG="$TEST_TMP/apt-calls"
  : > "$MC_TEST_APT_LOG"
  mc_as_root() { "$@"; }
  # Called indirectly by mc_as_root's command dispatch.
  # shellcheck disable=SC2317
  apt-get() { printf '%s\n' "$*" >> "$MC_TEST_APT_LOG"; }
  dpkg-query() {
    local package
    for package in "$@"; do :; done
    [[ "$package" != "$MC_TEST_APT_MISSING" ]] || return 1
    printf 'installed'
  }
  mc_install_packages
  [[ ! -s "$MC_TEST_APT_LOG" ]]
  MC_TEST_APT_MISSING=curl
  mc_install_packages
  printf 'update\ninstall -y --no-upgrade curl\n' > "$TEST_TMP/apt-expected"
  assert_same "$TEST_TMP/apt-expected" "$MC_TEST_APT_LOG"
  : > "$MC_TEST_APT_LOG"
  MC_TEST_APT_MISSING='' MC_UPDATE=1
  mc_install_packages
  printf 'update\ninstall -y ca-certificates zsh git curl fontconfig python3\n' > "$TEST_TMP/apt-expected"
  assert_same "$TEST_TMP/apt-expected" "$MC_TEST_APT_LOG"
)
pass 'APT defaults to no-op or missing-only install; update targets named packages'

# Homebrew formula checks are read-only; explicit update never means upgrade-all.
(
  MC_OS=Darwin MC_UPDATE=0 MC_BOOTSTRAP_BREW=0
  MC_TEST_BREW_MISSING=''
  MC_TEST_BREW_LOG="$TEST_TMP/brew-calls"
  : > "$MC_TEST_BREW_LOG"
  xcode-select() { return 0; }
  mc_find_brew() { printf 'mc_test_brew\n'; }
  # Called indirectly through the command returned by mc_find_brew.
  # shellcheck disable=SC2317
  mc_test_brew() {
    [[ ${HOMEBREW_NO_AUTO_UPDATE:-} == 1 \
      && ${HOMEBREW_NO_INSTALL_UPGRADE:-} == 1 \
      && ${HOMEBREW_NO_INSTALL_CLEANUP:-} == 1 ]] || return 77
    printf '%s\n' "$*" >> "$MC_TEST_BREW_LOG"
    case "$1" in
      shellenv) ;;
      list)
        if [[ "$MC_TEST_BREW_MISSING" == all || "$4" == "$MC_TEST_BREW_MISSING" ]]; then return 1; fi
        printf '%s 1.0\n' "$4" ;;
      update|install|upgrade) ;;
      *) return 1 ;;
    esac
  }
  mc_install_packages
  if grep -Eq '^(update|install|upgrade)' "$MC_TEST_BREW_LOG"; then exit 1; fi
  : > "$MC_TEST_BREW_LOG"
  MC_TEST_BREW_MISSING=curl
  mc_install_packages
  grep -qx 'install --formula curl' "$MC_TEST_BREW_LOG"
  if grep -Eq '^(update|upgrade)' "$MC_TEST_BREW_LOG"; then exit 1; fi
  : > "$MC_TEST_BREW_LOG"
  MC_UPDATE=1
  mc_install_packages
  grep -qx update "$MC_TEST_BREW_LOG"
  grep -qx 'install --formula curl' "$MC_TEST_BREW_LOG"
  grep -qx 'upgrade --formula zsh git python' "$MC_TEST_BREW_LOG"
  : > "$MC_TEST_BREW_LOG"
  MC_TEST_BREW_MISSING=all
  mc_install_packages
  grep -qx 'install --formula zsh git curl python' "$MC_TEST_BREW_LOG"
  if grep -q '^upgrade' "$MC_TEST_BREW_LOG"; then exit 1; fi
)
pass 'Homebrew no-op/missing/update paths disable implicit maintenance and cleanup'

# Cache only new/changed fonts. A failed rebuild must remain retryable even if
# the repaired bytes match the previously successful manifest.
(
  MC_OS=Linux MC_TARGET="$TEST_TMP/font-cache-target"
  MC_STATE="$MC_TARGET/.local/state/my-configs"
  MC_TEST_FONT_PAYLOAD="$TEST_TMP/font-cache-payload"
  MC_TEST_FONT_LOG="$TEST_TMP/font-cache-calls"
  MC_TEST_FONT_FAIL=0
  printf 'font version one\n' > "$MC_TEST_FONT_PAYLOAD"
  MC_TEST_FONT_HASH=$(mc_sha256 "$MC_TEST_FONT_PAYLOAD")
  : > "$MC_TEST_FONT_LOG"
  mc_font_manifest() { printf 'Regular|%s\n' "$MC_TEST_FONT_HASH"; }
  mc_download_verified() {
    mkdir -p "$(dirname "$2")"
    if [[ ! -f "$2" ]] || ! cmp -s "$MC_TEST_FONT_PAYLOAD" "$2"; then cp "$MC_TEST_FONT_PAYLOAD" "$2"; fi
  }
  fc-cache() {
    printf 'refresh\n' >> "$MC_TEST_FONT_LOG"
    [[ "$MC_TEST_FONT_FAIL" == 0 ]]
  }
  mc_install_fonts
  [[ $(wc -l < "$MC_TEST_FONT_LOG") -eq 1 ]]
  cp "$MC_STATE/font-cache.sha256" "$TEST_TMP/font-cache-first-marker"
  mc_install_fonts
  [[ $(wc -l < "$MC_TEST_FONT_LOG") -eq 1 ]]
  assert_same "$TEST_TMP/font-cache-first-marker" "$MC_STATE/font-cache.sha256"
  printf 'damaged font\n' > "$MC_TARGET/.local/share/fonts/MesloLGS NF Regular.ttf"
  MC_TEST_FONT_FAIL=1
  mc_install_fonts
  [[ $(wc -l < "$MC_TEST_FONT_LOG") -eq 2 && ! -e "$MC_STATE/font-cache.sha256" ]]
  MC_TEST_FONT_FAIL=0
  mc_install_fonts
  [[ $(wc -l < "$MC_TEST_FONT_LOG") -eq 3 && -f "$MC_STATE/font-cache.sha256" ]]
  mc_install_fonts
  [[ $(wc -l < "$MC_TEST_FONT_LOG") -eq 3 ]]
  printf 'font version two\n' > "$MC_TEST_FONT_PAYLOAD"
  MC_TEST_FONT_HASH=$(mc_sha256 "$MC_TEST_FONT_PAYLOAD")
  mc_install_fonts
  [[ $(wc -l < "$MC_TEST_FONT_LOG") -eq 4 ]]
)
pass 'font-cache refresh is change-driven and retries after a failed rebuild'

# gsettings values have GVariant string quoting; matching settings need no writes.
(
  MC_OS=Linux MC_TARGET="$HOME" DBUS_SESSION_BUS_ADDRESS='test-session'
  MC_TEST_GSET_DIR="$TEST_TMP/gsettings"
  MC_TEST_GSET_LOG="$TEST_TMP/gsettings-sets"
  mkdir -p "$MC_TEST_GSET_DIR"
  printf 'false\n' > "$MC_TEST_GSET_DIR/use-system-font"
  printf "'MesloLGS NF 11'\n" > "$MC_TEST_GSET_DIR/font-name"
  : > "$MC_TEST_GSET_LOG"
  gsettings() {
    case "$1" in
      list-schemas) printf 'org.gnome.Ptyxis\n' ;;
      get) cat "$MC_TEST_GSET_DIR/$3" ;;
      set)
        printf '%s\n' "$*" >> "$MC_TEST_GSET_LOG"
        if [[ "$4" == false || "$4" == true ]]; then printf '%s\n' "$4" > "$MC_TEST_GSET_DIR/$3"
        else printf "'%s'\n" "$4" > "$MC_TEST_GSET_DIR/$3"
        fi ;;
      *) return 1 ;;
    esac
  }
  mc_configure_terminal_font
  [[ ! -s "$MC_TEST_GSET_LOG" ]]
  printf "'Monospace 12'\n" > "$MC_TEST_GSET_DIR/font-name"
  mc_configure_terminal_font
  [[ $(wc -l < "$MC_TEST_GSET_LOG") -eq 1 ]]
  grep -qx 'set org.gnome.Ptyxis font-name MesloLGS NF 11' "$MC_TEST_GSET_LOG"
  mc_configure_terminal_font
  [[ $(wc -l < "$MC_TEST_GSET_LOG") -eq 1 ]]
  printf 'true\n' > "$MC_TEST_GSET_DIR/use-system-font"
  mc_configure_terminal_font
  [[ $(wc -l < "$MC_TEST_GSET_LOG") -eq 2 ]]
)
pass 'desktop font settings compare current values before writing changes'


# Prepared candidates are durable review artifacts; edits and symlinks must survive.
(
  MC_TARGET="$TEST_TMP/activation-user"
  MC_STATE="$MC_TARGET/.local/state/my-configs"
  MC_REPLACE=0 MC_CONFLICTS=0 MC_BACKUP_DIR=''
  mkdir -p "$MC_TARGET" "$MC_STATE/templates"
  printf '# current user configuration\n' > "$MC_TARGET/.zshrc"
  printf '# prepared configuration\n' > "$TEST_TMP/activation-source"
  mc_install_config "$TEST_TMP/activation-source" "$MC_TARGET/.zshrc" zshrc
  mc_config_is_pending "$MC_TARGET/.zshrc" zshrc
  printf '# draft written by the user\n' >> "$MC_TARGET/.zshrc.my-configs-new"
  cp "$MC_TARGET/.zshrc.my-configs-new" "$TEST_TMP/user-draft"
  mc_install_config "$TEST_TMP/activation-source" "$MC_TARGET/.zshrc" zshrc
  prepared=$(mc_pending_candidate "$MC_TARGET/.zshrc" zshrc)
  [[ "$prepared" != "$MC_TARGET/.zshrc.my-configs-new" ]]
  assert_same "$TEST_TMP/activation-source" "$prepared"
  assert_same "$TEST_TMP/user-draft" "$MC_TARGET/.zshrc.my-configs-new"
  mc_install_config "$TEST_TMP/activation-source" "$MC_TARGET/.zshrc" zshrc
  [[ "$prepared" == "$(mc_pending_candidate "$MC_TARGET/.zshrc" zshrc)" ]]
  MC_REPLACE=1
  mc_install_config "$TEST_TMP/activation-source" "$MC_TARGET/.zshrc" zshrc
  [[ ! -e "$prepared" && ! -e "$MC_STATE/pending/zshrc" ]]
  assert_same "$TEST_TMP/activation-source" "$MC_TARGET/.zshrc"
  assert_same "$TEST_TMP/user-draft" "$MC_TARGET/.zshrc.my-configs-new"
  if mc_config_is_pending "$MC_TARGET/.zshrc" zshrc; then exit 1; fi
  printf '# external candidate draft\n' > "$TEST_TMP/linked-draft"
  ln -s "$TEST_TMP/linked-draft" "$MC_TARGET/.p10k.zsh.my-configs-new"
  mc_install_config "$TEST_TMP/activation-source" "$MC_TARGET/.p10k.zsh" p10k.zsh
  [[ -L "$MC_TARGET/.p10k.zsh.my-configs-new" ]]
  grep -q 'external candidate draft' "$TEST_TMP/linked-draft"
  cp "$TEST_TMP/activation-source" "$MC_TARGET/.linked.my-configs-new"
  ln -s "$MC_TARGET/.linked.my-configs-new" "$MC_TARGET/.linked"
  mc_install_config "$TEST_TMP/activation-source" "$MC_TARGET/.linked" linked
  [[ -L "$MC_TARGET/.linked" && -f "$MC_TARGET/.linked.my-configs-new" ]]
)
pass 'activation cleans matching candidates while preserving edited drafts and symlinks'

# An active symlink still needs a baseline when an edited draft outlives its marker.
(
  MC_TARGET="$TEST_TMP/activation-identical-symlink"
  MC_STATE="$MC_TARGET/.local/state/my-configs"
  MC_REPLACE=0 MC_CONFLICTS=0 MC_BACKUP_DIR=''
  mkdir -p "$MC_TARGET" "$MC_STATE/templates"
  printf '# repository configuration\n' > "$TEST_TMP/identical-symlink-source"
  printf '# current user configuration\n' > "$MC_TARGET/.zshrc"
  mc_install_config "$TEST_TMP/identical-symlink-source" "$MC_TARGET/.zshrc" zshrc
  printf '# edited draft\n' >> "$MC_TARGET/.zshrc.my-configs-new"
  rm "$MC_TARGET/.zshrc"
  ln -s "$TEST_TMP/identical-symlink-source" "$MC_TARGET/.zshrc"
  MC_CONFLICTS=0
  mc_install_config "$TEST_TMP/identical-symlink-source" "$MC_TARGET/.zshrc" zshrc
  [[ -L "$MC_TARGET/.zshrc" && $MC_CONFLICTS -eq 0 ]]
  [[ ! -e "$MC_STATE/pending/zshrc" ]]
  assert_same "$TEST_TMP/identical-symlink-source" "$MC_STATE/templates/zshrc"
  grep -q 'edited draft' "$MC_TARGET/.zshrc.my-configs-new"
  if mc_config_is_pending "$MC_TARGET/.zshrc" zshrc; then exit 1; fi
)
pass 'identical symlink records a baseline and clears stale pending state'

# Atomic replacement targets the symlink itself, never the referenced directory.
(
  MC_TARGET="$TEST_TMP/atomic-directory-symlink"
  MC_STATE="$MC_TARGET/.local/state/my-configs"
  MC_REPLACE=1 MC_CONFLICTS=0 MC_BACKUP_DIR=''
  mkdir -p "$MC_TARGET" "$MC_STATE/templates" "$TEST_TMP/atomic-actual-directory"
  printf '# repository configuration\n' > "$TEST_TMP/atomic-source"
  ln -s "$TEST_TMP/atomic-actual-directory" "$MC_TARGET/.zshrc"
  mc_install_config "$TEST_TMP/atomic-source" "$MC_TARGET/.zshrc" zshrc
  [[ ! -L "$MC_TARGET/.zshrc" && -f "$MC_TARGET/.zshrc" ]]
  assert_same "$TEST_TMP/atomic-source" "$MC_TARGET/.zshrc"
  [[ -L "$MC_BACKUP_DIR/zshrc" ]]
  [[ $(readlink "$MC_BACKUP_DIR/zshrc") == "$TEST_TMP/atomic-actual-directory" ]]
  [[ -z $(find "$TEST_TMP/atomic-actual-directory" -mindepth 1 -print -quit) ]]
)
pass 'atomic copy replaces a directory symlink without entering its target'

# A pending configuration is not a successful doctor result, including legacy
# candidates created before pending-state markers existed.
(
  MC_TARGET="$TEST_TMP/pending-doctor"
  MC_STATE="$MC_TARGET/.local/state/my-configs"
  MC_NO_FONTS=1 MC_REPLACE=0 MC_CONFLICTS=0 MC_BACKUP_DIR=''
  mkdir -p "$MC_TARGET" "$MC_STATE/templates"
  printf '# active old config\n' > "$MC_TARGET/.zshrc"
  cp "$MC_TARGET/.zshrc" "$MC_TARGET/.p10k.zsh"
  printf '# new candidate\n' > "$MC_TARGET/.zshrc.my-configs-new"
  mc_sources() { :; }
  mc_check_fzf() { :; }
  if mc_check_installation >"$TEST_TMP/pending-check.log" 2>&1; then exit 1; fi
  grep -q 'prepared but not activated' "$TEST_TMP/pending-check.log"
  mc_install_config "$TEST_TMP/activation-source" "$MC_TARGET/.zshrc" zshrc
  if mc_check_installation >"$TEST_TMP/pending-check.log" 2>&1; then exit 1; fi
  grep -q 'prepared but not activated' "$TEST_TMP/pending-check.log"
  MC_REPLACE=1
  mc_install_config "$TEST_TMP/activation-source" "$MC_TARGET/.zshrc" zshrc
  mc_check_installation >"$TEST_TMP/activated-check.log"
)
pass 'doctor rejects prepared configurations until they are activated'

# A noninteractive run keeps the old config and prints a usable, quoted command
# carrying the target and skip flags. Executing that explicit command activates it.
ACTIVATION_COPY="$TEST_TMP/installer with spaces"
mv "$COPY" "$ACTIVATION_COPY"
printf '# local customization\n' >> "$FORWARD_TARGET/.zshrc"
cp "$FORWARD_TARGET/.zshrc" "$TEST_TMP/before-nontty"
MC_TEST_DEVOPS_ARGS="$TEST_TMP/devops-args" "$BASH" "$ACTIVATION_COPY/setup.sh" \
  --skip-packages --no-fonts --no-chsh --devops --target-dir "$FORWARD_TARGET" \
  </dev/null >"$TEST_TMP/activation-output" 2>&1
assert_same "$TEST_TMP/before-nontty" "$FORWARD_TARGET/.zshrc"
grep -q 'Настройки подготовлены, но не включены' "$TEST_TMP/activation-output"
if grep -Eq 'Installation completed|Выбор' "$TEST_TMP/activation-output"; then exit 1; fi
activation_command=$(grep '^bash ' "$TEST_TMP/activation-output")
[[ "$activation_command" == *--replace-config* && "$activation_command" == *--target-dir* \
  && "$activation_command" == *--skip-packages* && "$activation_command" == *--no-fonts* \
  && "$activation_command" == *--no-chsh* && "$activation_command" == *--devops* ]]
MC_TEST_DEVOPS_ARGS="$TEST_TMP/devops-args" "$BASH" -c "$activation_command" \
  </dev/null >"$TEST_TMP/activation-rerun-output" 2>&1
assert_same "$ACTIVATION_COPY/zshrc" "$FORWARD_TARGET/.zshrc"
[[ ! -e "$FORWARD_TARGET/.zshrc.my-configs-new" ]]
grep -qx -- '--skip-packages' "$TEST_TMP/devops-args"
pass 'noninteractive preparation prints an executable activation command with preserved flags'

# Editing a candidate while the activation menu is open must not silently apply
# different repository bytes or replace either active file before validation.
(
  MC_TARGET="$TEST_TMP/changed-candidate"
  MC_STATE="$MC_TARGET/.local/state/my-configs"
  BOOTSTRAP_ROOT="$TEST_TMP/reviewed-source"
  MC_REPLACE=0 MC_CONFLICTS=0 MC_BACKUP_DIR=''
  mkdir -p "$MC_TARGET" "$MC_STATE/templates" "$BOOTSTRAP_ROOT"
  for key in zshrc p10k.zsh; do
    printf '# old active config\n' > "$MC_TARGET/.$key"
    printf '# new prepared config\n' > "$BOOTSTRAP_ROOT/$key"
    mc_install_config "$BOOTSTRAP_ROOT/$key" "$MC_TARGET/.$key" "$key"
  done
  printf '# edited during review\n' >> "$(mc_pending_candidate "$MC_TARGET/.p10k.zsh" p10k.zsh)"
  if (mc_activate_prepared_configs) >"$TEST_TMP/changed-candidate.log" 2>&1; then exit 1; fi
  grep -q 'Prepared configuration changed' "$TEST_TMP/changed-candidate.log"
  grep -qx '# old active config' "$MC_TARGET/.zshrc"
  grep -qx '# old active config' "$MC_TARGET/.p10k.zsh"
)
pass 'activation refuses a changed candidate before replacing any active file'

python3 "$TEST_ROOT/tests/activation_tty.py" "$TEST_ROOT/lib/bootstrap.sh"
pass 'TTY activation requires an explicit choice and respects noninteractive guards'
printf '%s total bootstrap regression checks passed\n' "$PASS"
