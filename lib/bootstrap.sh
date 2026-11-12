# shellcheck shell=bash
# Shared bootstrap functions; sourced by setup.sh and the regression tests.
# No changes are made merely by sourcing this file.

mc_log() { printf '%s\n' "$*"; }
mc_warn() { printf 'Warning: %s\n' "$*" >&2; }
mc_die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# Release tags where available; immutable commits for projects without releases.
# Update these reviewed pins in the repository, then run setup.sh --update.
mc_sources() {
  cat <<'SOURCES'
oh-my-zsh|.oh-my-zsh|https://github.com/ohmyzsh/ohmyzsh.git|6010fb6260f359e71d99ba25f05f9215809b3ed2|6010fb6260f359e71d99ba25f05f9215809b3ed2|oh-my-zsh.sh
powerlevel10k|.oh-my-zsh/custom/themes/powerlevel10k|https://github.com/romkatv/powerlevel10k.git|v1.20.0|35833ea15f14b71dbcebc7e54c104d8d56ca5268|powerlevel10k.zsh-theme
zsh-kubecolor|.oh-my-zsh/custom/plugins/zsh-kubecolor|https://github.com/devopstales/zsh-kubecolor.git|bfe53705f715aecda854080c9c72441f61beabb2|bfe53705f715aecda854080c9c72441f61beabb2|zsh-kubecolor.plugin.zsh
zsh-autosuggestions|.oh-my-zsh/custom/plugins/zsh-autosuggestions|https://github.com/zsh-users/zsh-autosuggestions.git|v0.7.1|e52ee8ca55bcc56a17c828767a3f98f22a68d4eb|zsh-autosuggestions.zsh
zsh-syntax-highlighting|.oh-my-zsh/custom/plugins/zsh-syntax-highlighting|https://github.com/zsh-users/zsh-syntax-highlighting.git|0.8.0|db085e4661f6aafd24e5acb5b2e17e4dd5dddf3e|zsh-syntax-highlighting.zsh
SOURCES
}

# Resolve existing parents and lexical dot components without creating anything.
# This catches /tmp/.. and symlink-to-/ targets even in read-only --check mode.
mc_canonical_target() {
  local current=$1 suffix='' part resolved=''
  local -a components
  while [[ ! -d "$current" ]]; do
    [[ ! -e "$current" && ! -L "$current" ]] || mc_die "Not a directory: $current"
    suffix="/$(basename "$current")$suffix"
    current=$(dirname "$current")
  done
  current=$(cd -P "$current" && pwd -P)
  IFS=/ read -r -a components <<< "$current$suffix"
  for part in "${components[@]}"; do
    case "$part" in
      ''|.) ;;
      ..) resolved=${resolved%/*} ;;
      *) resolved="$resolved/$part" ;;
    esac
  done
  resolved=${resolved:-/}
  if [[ -d "$resolved" ]]; then resolved=$(cd -P "$resolved" && pwd -P); fi
  printf '%s\n' "$resolved"
}

mc_require_commands() {
  local name
  for name in "$@"; do command -v "$name" >/dev/null 2>&1 || mc_die "Required command is missing: $name"; done
}

mc_as_root() {
  if [[ $(id -u) == 0 ]]; then "$@"; else
    command -v sudo >/dev/null 2>&1 || mc_die 'sudo is required to install system packages'
    sudo "$@"
  fi
}

mc_find_brew() {
  if command -v brew >/dev/null 2>&1; then command -v brew
  elif [[ -x /opt/homebrew/bin/brew ]]; then printf '%s\n' /opt/homebrew/bin/brew
  elif [[ -x /usr/local/bin/brew ]]; then printf '%s\n' /usr/local/bin/brew
  else return 1
  fi
}

mc_install_packages() {
  local brew_bin installer
  case "$MC_OS" in
    Linux)
      command -v apt-get >/dev/null 2>&1 || mc_die 'This installer supports Ubuntu/Debian (apt-get) and macOS'
      mc_as_root apt-get update
      mc_as_root apt-get install -y ca-certificates zsh git curl fontconfig
      ;;
    Darwin)
      if ! xcode-select -p >/dev/null 2>&1; then
        mc_die 'Install Apple Command Line Tools with xcode-select --install, finish that installation, then rerun setup.sh'
      fi
      brew_bin=$(mc_find_brew) || brew_bin=''
      if [[ -z "$brew_bin" ]]; then
        (( MC_BOOTSTRAP_BREW )) || mc_die 'Homebrew is missing. Rerun with --bootstrap-homebrew, or install it from https://brew.sh'
        installer=$(mktemp "${TMPDIR:-/tmp}/my-configs-homebrew.XXXXXX")
        if ! curl -fL --retry 3 -o "$installer" https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh; then
          rm -f "$installer"; mc_die 'Failed to download the official Homebrew installer'
        fi
        if ! /bin/bash "$installer"; then rm -f "$installer"; mc_die 'Homebrew installation failed'; fi
        rm -f "$installer"
        brew_bin=$(mc_find_brew) || mc_die 'Homebrew was not found after installation'
      fi
      eval "$("$brew_bin" shellenv)"
      "$brew_bin" install zsh git curl
      ;;
  esac
}

mc_install_repo() {
  local name=$1 dest=$2 url=$3 ref=$4 commit=$5 entry=$6 stage current recorded origin
  if [[ -e "$dest" || -L "$dest" ]]; then
    [[ -r "$dest/$entry" ]] || mc_die "$dest exists but does not contain $entry; preserving it"
    if [[ ! -f "$dest/.git/my-configs-owner" ]]; then
      mc_log "Keep existing $name (not managed by this installer)"
      return 0
    fi
    current=$(git -C "$dest" rev-parse HEAD)
    [[ "$current" != "$commit" ]] || return 0
    if (( ! MC_UPDATE )); then mc_log "Keep $name; use --update to apply the repository pin"; return 0; fi
    origin=$(git -C "$dest" remote get-url origin)
    [[ "$origin" == "$url" ]] || mc_die "$name has a different origin; preserving it"
    recorded=$(sed -n '2p' "$dest/.git/my-configs-owner")
    [[ "$current" == "$recorded" ]] || mc_die "$name has local commits; preserving them"
    [[ -z $(git -C "$dest" status --porcelain --untracked-files=no) ]] || mc_die "$name has local modifications; preserving them"
    git -C "$dest" fetch --quiet --depth 1 origin "$ref"
    [[ $(git -C "$dest" rev-parse 'FETCH_HEAD^{commit}') == "$commit" ]] || mc_die "Unexpected commit for $name"
    git -C "$dest" -c advice.detachedHead=false checkout --quiet --detach "$commit"
    printf '%s\n%s\n' "$url" "$commit" > "$dest/.git/my-configs-owner"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  stage=$(mktemp -d "${dest}.install.XXXXXX")
  if ! (
    set -e
    git init --quiet "$stage" || exit 1
    git -C "$stage" remote add origin "$url" || exit 1
    git -C "$stage" fetch --quiet --depth 1 origin "$ref" || exit 1
    [[ $(git -C "$stage" rev-parse 'FETCH_HEAD^{commit}') == "$commit" ]] || exit 1
    git -C "$stage" -c advice.detachedHead=false checkout --quiet --detach "$commit" || exit 1
    [[ -r "$stage/$entry" ]] || exit 1
  ); then
    rm -rf "$stage"
    mc_die "Could not install the verified revision of $name"
  fi
  printf '%s\n%s\n' "$url" "$commit" > "$stage/.git/my-configs-owner"
  mv "$stage" "$dest"
  mc_log "Installed $name ($ref)"
}

mc_atomic_copy() {
  local source=$1 dest=$2 stage
  if [[ -f "$dest" && ! -L "$dest" ]] && cmp -s "$source" "$dest"; then return 0; fi
  mkdir -p "$(dirname "$dest")"
  stage=$(mktemp "${dest}.tmp.XXXXXX")
  if ! cp "$source" "$stage"; then rm -f "$stage"; return 1; fi
  chmod 600 "$stage"
  mv -f "$stage" "$dest"
}

mc_install_config() {
  local source=$1 dest=$2 key=$3 baseline
  baseline="$MC_STATE/templates/$key"
  [[ -f "$source" ]] || mc_die "Missing repository configuration: $source"
  if [[ -f "$dest" && ! -L "$dest" ]] && cmp -s "$source" "$dest"; then
    mc_atomic_copy "$source" "$baseline"
    return 0
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    if (( ! MC_REPLACE )) && { [[ -L "$dest" || ! -f "$baseline" ]] || ! cmp -s "$baseline" "$dest"; }; then
      mc_atomic_copy "$source" "$dest.my-configs-new"
      MC_CONFLICTS=$((MC_CONFLICTS + 1))
      mc_warn "Preserved $dest; new configuration: $dest.my-configs-new"
      return 0
    fi
    if [[ -z "$MC_BACKUP_DIR" ]]; then
      MC_BACKUP_DIR=$(mktemp -d "$MC_STATE/backup-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
    fi
    # Preserve the symlink itself as well as the destination of a regular file.
    cp -Pp "$dest" "$MC_BACKUP_DIR/$key"
    mc_log "Backed up $dest"
  fi
  mc_atomic_copy "$source" "$dest"
  mc_atomic_copy "$source" "$baseline"
}

mc_font_manifest() {
  # SHA-256 of files at immutable powerlevel10k-media commit 145eb9f... .
  # Plain file hashes are independent of the invoking repository's Git format.
  cat <<'FONTS'
Regular|d97946186e97f8d7c0139e8983abf40a1d2d086924f2c5dbf1c29bd8f2c6e57d
Bold|b6c0199cf7c7483c8343ea020658925e6de0aeb318b89908152fcb4d19226003
Italic|6f357bcbe2597704e157a915625928bca38364a89c22a4ac36e7a116dcd392ef
Bold Italic|56b4131adecec052c4b324efb818dd326d586dbc316fc68f98f1cae2eb8d1220
FONTS
}

mc_font_dir() {
  if [[ "$MC_OS" == Darwin ]]; then printf '%s\n' "$MC_TARGET/Library/Fonts"
  else printf '%s\n' "$MC_TARGET/.local/share/fonts"
  fi
}

mc_sha256() {
  local result
  if command -v sha256sum >/dev/null 2>&1; then
    result=$(sha256sum "$1")
  elif command -v shasum >/dev/null 2>&1; then
    result=$(shasum -a 256 "$1")
  else
    mc_die 'SHA-256 verification needs sha256sum (Ubuntu) or shasum (macOS)'
  fi
  printf '%s\n' "${result%% *}"
}

mc_download_verified() {
  local url=$1 dest=$2 expected=$3 stage actual
  if [[ -f "$dest" ]] && [[ $(mc_sha256 "$dest") == "$expected" ]]; then return 0; fi
  mkdir -p "$(dirname "$dest")"
  stage=$(mktemp "${dest}.download.XXXXXX")
  if ! curl -fL --retry 3 --connect-timeout 15 --max-time 120 -o "$stage" "$url"; then
    rm -f "$stage"; mc_die "Download failed: $url"
  fi
  actual=$(mc_sha256 "$stage")
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$stage"; mc_die "Downloaded content failed verification: $url"
  fi
  chmod 644 "$stage"
  mv -f "$stage" "$dest"
}

# fzf's native shell integration is embedded in this same binary on every OS.
# Ubuntu minimal images omit /usr/share/doc, including the old apt fzf scripts.
mc_fzf_spec() {
  local platform arch archive_hash binary_hash
  case "$MC_OS" in Linux) platform=linux ;; Darwin) platform=darwin ;; esac
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) mc_die 'Managed fzf supports x86_64 and arm64 on Ubuntu/macOS' ;;
  esac
  case "${platform}_${arch}" in
    linux_amd64)
      archive_hash=0d6640f83582d991cf429754baad64b07e3a4e439a6019670f4b91da1314141c
      binary_hash=2d70610518863239656b5cafdeea3c1af93e3a0bb8d584aeb1bb090157eec27b ;;
    linux_arm64)
      archive_hash=bd0717badb6a5620387e014bb94209aac4d9eab6ab77b5348eabb0833aeb4d59
      binary_hash=85d0838527dc99fe2e73057e7940fb166cd513ac28c49a878eccc323c46b5446 ;;
    darwin_amd64)
      archive_hash=8fa67fa874468b8e73ecad2df82cc110026f45d10605128aaac6b191262d2844
      binary_hash=fb8fe7b00b5581d586996e7feb44b2187049309f682741cd4ef91a5a1008e41a ;;
    darwin_arm64)
      archive_hash=1e76698eb481436e42119bea6aa6e2bd9552ff090789d769c286e3c3a4e0ded6
      binary_hash=51673b42f93c06c9e56087d2a7ffaba7cd157d11cde1b3a311810aeeaf53b1f7 ;;
  esac
  printf '0.75.0|%s_%s|%s|%s\n' "$platform" "$arch" "$archive_hash" "$binary_hash"
}

mc_install_fzf() (
  local version platform archive_hash binary_hash dest marker current stage archive
  IFS='|' read -r version platform archive_hash binary_hash < <(mc_fzf_spec)
  [[ -n "$binary_hash" ]] || mc_die 'Could not select a verified fzf release'
  dest="$MC_TARGET/.local/share/my-configs/bin/fzf"
  marker="$MC_STATE/fzf.sha256"
  if [[ -e "$dest" || -L "$dest" ]]; then
    [[ -f "$dest" ]] || mc_die "Preserving unexpected fzf path: $dest"
    current=$(mc_sha256 "$dest")
    if [[ "$current" == "$binary_hash" && -x "$dest" ]]; then return 0; fi
    [[ ! -L "$dest" && -f "$marker" && "$current" == "$(cat "$marker")" ]] \
      || mc_die "Preserving untracked/modified fzf: $dest"
    if [[ "$current" != "$binary_hash" ]] && (( ! MC_UPDATE )); then
      mc_die 'The managed fzf pin changed; rerun with --update'
    fi
  fi
  mkdir -p "$(dirname "$dest")" "$MC_STATE"
  stage=$(mktemp -d "$(dirname "$dest")/.fzf-install.XXXXXX")
  trap 'rm -rf "$stage"' EXIT
  archive="$stage/fzf.tar.gz"
  mc_download_verified "https://github.com/junegunn/fzf/releases/download/v$version/fzf-$version-$platform.tar.gz" "$archive" "$archive_hash"
  # Extract one regular payload to stdout; archive permissions/owners are ignored.
  tar -xOf "$archive" fzf > "$stage/fzf" || mc_die 'Could not extract fzf'
  [[ $(mc_sha256 "$stage/fzf") == "$binary_hash" ]] || mc_die 'Extracted fzf failed verification'
  chmod 755 "$stage/fzf"
  mv -f "$stage/fzf" "$dest"
  printf '%s\n' "$binary_hash" > "$stage/digest"
  mc_atomic_copy "$stage/digest" "$marker"
  mc_log "Installed fzf $version ($platform)"
)

mc_check_fzf() {
  local version platform archive_hash binary_hash dest
  IFS='|' read -r version platform archive_hash binary_hash < <(mc_fzf_spec)
  dest="$MC_TARGET/.local/share/my-configs/bin/fzf"
  if [[ ! -x "$dest" || -z "$binary_hash" ]]; then
    mc_warn "Missing managed fzf $version: $dest"; return 1
  fi
  if [[ $(mc_sha256 "$dest") != "$binary_hash" ]]; then
    mc_warn 'Managed fzf does not match the pinned binary checksum'; return 1
  fi
}

mc_install_fonts() {
  local font_dir style blob filename encoded
  font_dir=$(mc_font_dir)
  while IFS='|' read -r style blob; do
    filename="MesloLGS NF $style.ttf"
    encoded=${filename// /%20}
    mc_download_verified "https://raw.githubusercontent.com/romkatv/powerlevel10k-media/145eb9fbc2f42ee408dacd9b22d8e6e0e553f83d/$encoded" "$font_dir/$filename" "$blob"
  done < <(mc_font_manifest)
  if command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f "$font_dir" >/dev/null || mc_warn 'Could not refresh the font cache; fonts were installed'
  fi
  return 0
}

mc_configure_terminal_font() {
  local schemas profile schema
  [[ "$MC_OS" == Linux && "$MC_TARGET" == "$HOME" ]] || return 0
  command -v gsettings >/dev/null 2>&1 || return 0
  # Do not manufacture a D-Bus address on headless/WSL machines.
  [[ -n ${DBUS_SESSION_BUS_ADDRESS:-} ]] || return 0
  schemas=$(gsettings list-schemas 2>/dev/null) || return 0
  if printf '%s\n' "$schemas" | grep -qx org.gnome.Ptyxis; then
    if ! gsettings set org.gnome.Ptyxis use-system-font false 2>/dev/null \
      || ! gsettings set org.gnome.Ptyxis font-name 'MesloLGS NF 11' 2>/dev/null; then
      mc_warn 'Select MesloLGS NF in Ptyxis settings'
    fi
  fi
  if printf '%s\n' "$schemas" | grep -qx org.gnome.Terminal.ProfilesList; then
    profile=$(gsettings get org.gnome.Terminal.ProfilesList default 2>/dev/null) || profile=''
    profile=${profile//\'/}
    if [[ -n "$profile" ]]; then
      schema="org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:$profile/"
      if ! gsettings set "$schema" use-system-font false 2>/dev/null \
        || ! gsettings set "$schema" font 'MesloLGS NF 11' 2>/dev/null; then
        mc_warn 'Select MesloLGS NF in GNOME Terminal settings'
      fi
    fi
  fi
  return 0
}

mc_change_shell() {
  local shell_bin username current
  shell_bin=$(command -v zsh); username=$(id -un)
  if [[ "$MC_OS" == Darwin ]]; then
    current=$(dscl . -read "/Users/$username" UserShell 2>/dev/null | awk '{print $2}') || current=${SHELL:-}
  else
    current=$(getent passwd "$username" | cut -d: -f7) || current=${SHELL:-}
  fi
  [[ "$current" != "$shell_bin" ]] || return 0
  if ! grep -qxF "$shell_bin" /etc/shells; then
    printf '%s\n' "$shell_bin" | mc_as_root tee -a /etc/shells >/dev/null
  fi
  mc_as_root chsh -s "$shell_bin" "$username" || mc_warn "Run manually: chsh -s $shell_bin"
}

mc_check_installation() {
  local missing=0 unmanaged=0 name relative url ref commit entry style blob font_dir current origin changes
  for name in git curl zsh tar; do
    if ! command -v "$name" >/dev/null 2>&1; then mc_warn "Missing command: $name"; missing=1; fi
  done
  mc_check_fzf || missing=1
  while IFS='|' read -r name relative url ref commit entry; do
    if [[ ! -r "$MC_TARGET/$relative/$entry" ]]; then
      mc_warn "Missing component: $name"; missing=1
    elif [[ -f "$MC_TARGET/$relative/.git/my-configs-owner" ]] && command -v git >/dev/null 2>&1; then
      current=$(git -C "$MC_TARGET/$relative" rev-parse HEAD 2>/dev/null) || current=''
      origin=$(git -C "$MC_TARGET/$relative" remote get-url origin 2>/dev/null) || origin=''
      changes=$(git -C "$MC_TARGET/$relative" status --porcelain --untracked-files=no 2>/dev/null) || changes='unreadable'
      if [[ "$current" != "$commit" || "$origin" != "$url" ]]; then
        mc_warn "Managed component does not match its pinned revision/origin: $name"; missing=1
      fi
      if [[ -n "$changes" ]]; then mc_warn "Managed component has tracked modifications: $name"; missing=1; fi
    else
      mc_warn "Existing $name is unmanaged; its revision was not verified"
      unmanaged=$((unmanaged + 1))
    fi
  done < <(mc_sources)
  for name in .zshrc .p10k.zsh; do
    if [[ ! -r "$MC_TARGET/$name" ]]; then mc_warn "Missing $MC_TARGET/$name"; missing=1
    elif command -v zsh >/dev/null 2>&1; then zsh -n "$MC_TARGET/$name" || missing=1
    fi
  done
  if (( ! MC_NO_FONTS )); then
    font_dir=$(mc_font_dir)
    while IFS='|' read -r style blob; do
      if [[ ! -r "$font_dir/MesloLGS NF $style.ttf" ]]; then mc_warn "Missing Meslo font: $style"; missing=1
      elif [[ $(mc_sha256 "$font_dir/MesloLGS NF $style.ttf") != "$blob" ]]; then
        mc_warn "Font verification failed: $style"; missing=1
      fi
    done < <(mc_font_manifest)
  fi
  (( missing == 0 )) || return 1
  mc_log "Check passed for files and syntax in $MC_TARGET ($unmanaged unmanaged revisions not verified)"
}
