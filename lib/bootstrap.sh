# shellcheck shell=bash
# Shared bootstrap functions; sourced by setup.sh and the regression tests.
# No changes are made merely by sourcing this file.
MC_LIBRARY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Keep package-manager maintenance explicit, including Homebrew's implicit work.
mc_brew() {
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 \
    HOMEBREW_NO_INSTALL_CLEANUP=1 "$@"
}

mc_install_packages() {
  local brew_bin installer package status
  local missing_count=0 installed_count=0
  local -a packages missing_packages installed_packages
  case "$MC_OS" in
    Linux)
      command -v apt-get >/dev/null 2>&1 || mc_die 'This installer supports Ubuntu/Debian (apt-get) and macOS'
      packages=(ca-certificates zsh git curl fontconfig python3)
      for package in "${packages[@]}"; do
        status=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null) || status=''
        if [[ "$status" != installed ]]; then
          missing_packages[missing_count]=$package
          missing_count=$((missing_count + 1))
        fi
      done
      if (( MC_UPDATE )); then
        mc_as_root apt-get update
        # Only these targets (and dependencies required by APT) may be upgraded.
        mc_as_root apt-get install -y "${packages[@]}"
      elif (( missing_count )); then
        mc_as_root apt-get update
        mc_as_root apt-get install -y --no-upgrade "${missing_packages[@]}"
      else
        mc_log 'Base APT packages are already installed'
      fi
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
      eval "$(mc_brew "$brew_bin" shellenv)"
      if (( MC_UPDATE )); then mc_brew "$brew_bin" update; fi
      packages=(zsh git curl python)
      for package in "${packages[@]}"; do
        status=$(mc_brew "$brew_bin" list --versions --formula "$package" 2>/dev/null) || status=''
        if [[ -n "$status" ]]; then
          installed_packages[installed_count]=$package
          installed_count=$((installed_count + 1))
        else
          missing_packages[missing_count]=$package
          missing_count=$((missing_count + 1))
        fi
      done
      if (( missing_count )); then mc_brew "$brew_bin" install --formula "${missing_packages[@]}"; fi
      if (( MC_UPDATE && installed_count )); then
        mc_brew "$brew_bin" upgrade --formula "${installed_packages[@]}"
      elif (( ! missing_count )); then
        mc_log 'Base Homebrew formulae are already installed'
      fi
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
  # Do not let mv follow a destination symlink into a directory.
  if [[ -L "$dest" && -d "$dest" ]]; then
    case "$(uname -s)" in
      Darwin) mv -f -h "$stage" "$dest" ;;
      *) mv -f -T "$stage" "$dest" ;;
    esac
  else
    mv -f "$stage" "$dest"
  fi
}

# A pending marker records the exact reviewable candidate without rewriting a
# user's edited *.my-configs-new file. Candidate paths stay beside their dotfile.
mc_pending_candidate() {
  local dest=$1 key=$2 candidate suffix marker
  marker="$MC_STATE/pending/$key"
  if [[ -f "$marker" && ! -L "$marker" ]]; then
    candidate=$(cat "$marker")
    case "$candidate" in
      "$dest.my-configs-new"|"$dest.my-configs-new."*)
        suffix=${candidate#"$dest.my-configs-new"}
        if [[ "$suffix" != */* ]]; then printf '%s\n' "$candidate"; return 0; fi
        ;;
    esac
  fi
  printf '%s\n' "$dest.my-configs-new"
}

mc_prepare_config_candidate() {
  local source=$1 dest=$2 key=$3 candidate marker marker_tmp
  candidate=$(mc_pending_candidate "$dest" "$key")
  if [[ -e "$candidate" || -L "$candidate" ]]; then
    if [[ -L "$candidate" || ! -f "$candidate" ]] || ! cmp -s "$source" "$candidate"; then
      candidate=$(mktemp "$dest.my-configs-new.XXXXXX")
    fi
  fi
  mc_atomic_copy "$source" "$candidate"
  marker="$MC_STATE/pending/$key"
  if [[ ! -f "$marker" || -L "$marker" || $(cat "$marker") != "$candidate" ]]; then
    mkdir -p "$MC_STATE/pending"
    marker_tmp=$(mktemp "$MC_STATE/pending/.candidate.XXXXXX")
    printf '%s\n' "$candidate" > "$marker_tmp"
    mc_atomic_copy "$marker_tmp" "$marker"
    rm -f "$marker_tmp"
  fi
  printf '%s\n' "$candidate"
}

mc_clear_applied_candidates() {
  local source=$1 dest=$2 key=$3 candidate
  candidate=$(mc_pending_candidate "$dest" "$key")
  for candidate in "$candidate" "$dest.my-configs-new"; do
    if [[ -f "$candidate" && ! -L "$candidate" && ! "$dest" -ef "$candidate" ]] \
      && cmp -s "$source" "$candidate"; then
      rm -f "$candidate"
    fi
  done
  rm -f "$MC_STATE/pending/$key"
}

mc_config_is_pending() {
  local dest=$1 key=$2 candidate
  candidate=$(mc_pending_candidate "$dest" "$key")
  if [[ -e "$MC_STATE/pending/$key" || -L "$MC_STATE/pending/$key" ]]; then
    [[ -f "$candidate" && ! -L "$candidate" && -f "$dest" ]] \
      && cmp -s "$candidate" "$dest" && return 1
    return 0
  fi
  # Recognize candidates prepared by older installer versions too. A remaining
  # edited candidate is only a draft when the managed config is already active.
  [[ -e "$candidate" || -L "$candidate" ]] || return 1
  if [[ -f "$dest" && -f "$MC_STATE/templates/$key" ]] && cmp -s "$dest" "$MC_STATE/templates/$key"; then return 1; fi
  [[ -f "$candidate" && ! -L "$candidate" && -f "$dest" ]] \
    && cmp -s "$candidate" "$dest" && return 1
  return 0
}

mc_show_prepared_configs() {
  local key dest
  for key in zshrc p10k.zsh; do
    dest="$MC_TARGET/.$key"
    if mc_config_is_pending "$dest" "$key"; then
      printf '  %s\n' "$(mc_pending_candidate "$dest" "$key")"
    fi
  done
}

mc_activate_prepared_configs() {
  local key dest candidate
  # The accepted files must still be exactly the versions offered for review.
  for key in zshrc p10k.zsh; do
    dest="$MC_TARGET/.$key"
    if mc_config_is_pending "$dest" "$key"; then
      candidate=$(mc_pending_candidate "$dest" "$key")
      if [[ ! -f "$candidate" || -L "$candidate" ]] || ! cmp -s "$BOOTSTRAP_ROOT/$key" "$candidate"; then
        mc_warn "Prepared configuration changed; rerun setup before activation: $candidate"
        return 1
      fi
    fi
  done
  MC_REPLACE=1
  MC_CONFLICTS=0
  for key in zshrc p10k.zsh; do
    dest="$MC_TARGET/.$key"
    if mc_config_is_pending "$dest" "$key"; then
      mc_install_config "$BOOTSTRAP_ROOT/$key" "$dest" "$key"
    elif [[ -f "$dest" ]] && cmp -s "$BOOTSTRAP_ROOT/$key" "$dest"; then
      mc_clear_applied_candidates "$BOOTSTRAP_ROOT/$key" "$dest" "$key"
    fi
  done
}

mc_offer_activation() {
  local answer
  (( MC_CONFLICTS > 0 && ! MC_REPLACE && ! MC_TARGET_EXPLICIT )) || return 0
  [[ -t 0 && -t 1 && "$MC_TARGET" -ef "$HOME" ]] || return 0
  mc_log 'Новые настройки подготовлены для просмотра:'
  mc_show_prepared_configs
  mc_log '1) Включить новые настройки (сохранить резервную копию текущих)'
  mc_log '2) Оставить текущие настройки пока как есть'
  while :; do
    printf 'Выбор [2]: '
    IFS= read -r answer || answer=''
    case "$answer" in
      1) mc_activate_prepared_configs; return 0 ;;
      2|'') return 0 ;;
      *) mc_log 'Введите 1 или 2. Enter оставляет текущие настройки.' ;;
    esac
  done
}

mc_print_activation_command() {
  local -a args
  args=(bash "$BOOTSTRAP_ROOT/setup.sh" --replace-config)
  if (( MC_TARGET_EXPLICIT )); then args+=(--target-dir "$MC_TARGET"); fi
  if (( MC_SKIP_PACKAGES )); then args+=(--skip-packages); fi
  if (( MC_NO_FONTS )); then args+=(--no-fonts); fi
  if (( MC_NO_CHSH )); then args+=(--no-chsh); fi
  if (( MC_BOOTSTRAP_BREW )); then args+=(--bootstrap-homebrew); fi
  if (( MC_DEVOPS )); then args+=(--devops); fi
  if (( MC_UPDATE )); then args+=(--update); fi
  printf '%q ' "${args[@]}"
  printf '\n'
}

mc_install_config() {
  local source=$1 dest=$2 key=$3 baseline candidate local_stage=''
  baseline="$MC_STATE/templates/$key"
  [[ -f "$source" ]] || mc_die "Missing repository configuration: $source"
  if [[ -f "$dest" ]] && cmp -s "$source" "$dest"; then
    # An identical symlink remains in place; only its state baseline is written.
    mc_atomic_copy "$source" "$baseline"
    mc_clear_applied_candidates "$source" "$dest" "$key"
    return 0
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    if (( ! MC_REPLACE )) && { [[ -L "$dest" || ! -f "$baseline" ]] || ! cmp -s "$baseline" "$dest"; }; then
      candidate=$(mc_prepare_config_candidate "$source" "$dest" "$key")
      MC_CONFLICTS=$((MC_CONFLICTS + 1))
      mc_warn "Preserved $dest; prepared configuration: $candidate"
      return 0
    fi
    if [[ "$key" == zshrc && -f "$dest" ]]; then
      local_stage=$(mktemp "$MC_STATE/.local-migration.XXXXXX")
      if ! mc_prepare_local_migration "$dest" "$source" "$baseline" "$MC_TARGET/.zshrc.local" "$local_stage"; then
        rm -f "$local_stage"
        candidate=$(mc_prepare_config_candidate "$source" "$dest" "$key")
        mc_die "Personal settings need review; current configuration preserved. Prepared: $candidate"
      fi
    fi
    mc_ensure_backup || return 1
    # Preserve the symlink itself as well as the destination of a regular file.
    cp -Pp "$dest" "$MC_BACKUP_DIR/$key" || return 1
    if [[ -f "$baseline" ]]; then cp -p "$baseline" "$MC_BACKUP_DIR/$key.template" || return 1; fi
    if [[ -L "$dest" && -f "$dest" ]]; then
      cp -p "$dest" "$MC_BACKUP_DIR/$key.contents" || return 1
    fi
    mc_log "Backed up $dest"
    if [[ -n "$local_stage" ]]; then
      mc_apply_local_migration "$local_stage" || { rm -f "$local_stage"; return 1; }
      rm -f "$local_stage"
    fi
  fi
  mc_atomic_copy "$source" "$dest" || return 1
  mc_atomic_copy "$source" "$baseline" || return 1
  mc_clear_applied_candidates "$source" "$dest" "$key"
}

mc_ensure_backup() {
  if [[ -z "$MC_BACKUP_DIR" ]]; then
    MC_BACKUP_DIR=$(mktemp -d "$MC_STATE/backup-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX") || return 1
  fi
}

# Parse only: the migration helper never sources user configuration. All failure
# paths precede changes to either active file, including an existing local link.
mc_prepare_local_migration() {
  local old=$1 template=$2 baseline=$3 current_local=$4 output=$5
  mc_require_commands python3 zsh
  python3 "$MC_LIBRARY_DIR/migrate_zshrc.py" "$old" "$template" "$baseline" "$current_local" "$output" || return 1
  if [[ -L "$MC_TARGET/.zshrc.local" || -e "$MC_TARGET/.zshrc.local" && ! -f "$MC_TARGET/.zshrc.local" ]]; then
    if [[ ! -f "$MC_TARGET/.zshrc.local" ]] || ! cmp -s "$output" "$MC_TARGET/.zshrc.local"; then
      mc_warn 'Cannot extend a linked or non-regular .zshrc.local automatically; active files are preserved'
      return 1
    fi
  fi
}

mc_apply_local_migration() {
  local stage=$1 dest="$MC_TARGET/.zshrc.local"
  if [[ -f "$dest" ]] && cmp -s "$stage" "$dest"; then return 0; fi
  if [[ ! -s "$stage" && ! -e "$dest" ]]; then return 0; fi
  mc_ensure_backup || return 1
  if [[ -f "$dest" ]]; then cp -p "$dest" "$MC_BACKUP_DIR/zshrc.local" || return 1; fi
  mc_atomic_copy "$stage" "$dest" || return 1
  mc_log "Personal settings preserved in $dest"
}

# Recovery intentionally bypasses packages, downloads, shell and font changes.
# Merge the current active edits first so they win over older recovered settings.
mc_restore_local() {
  local requested=$1 backup old entry entry_old baseline stage_current stage_final
  mc_require_commands python3 zsh
  backup=$requested
  if [[ -z "$backup" ]]; then
    for entry in "$MC_STATE"/backup-*; do
      [[ -d "$entry" ]] || continue
      if [[ -f "$entry/zshrc.contents" ]]; then entry_old="$entry/zshrc.contents"
      elif [[ -f "$entry/zshrc" ]]; then entry_old="$entry/zshrc"
      else continue
      fi
      # Backing up a template upgrade must not hide an older personal config.
      if cmp -s "$entry_old" "$BOOTSTRAP_ROOT/zshrc" \
        || cmp -s "$entry_old" "$entry/zshrc.template" \
        || cmp -s "$entry_old" "$MC_STATE/templates/zshrc"; then continue; fi
      backup=$entry
    done
  fi
  baseline="$MC_STATE/templates/zshrc"
  if [[ -f "$backup/zshrc.template" ]]; then baseline="$backup/zshrc.template"; fi
  [[ -n "$backup" && -d "$backup" ]] || mc_die 'No zshrc backup found; pass its directory after --restore-local'
  if [[ -f "$backup/zshrc.contents" ]]; then old="$backup/zshrc.contents"
  elif [[ -f "$backup/zshrc" ]]; then old="$backup/zshrc"
  else mc_die "No readable zshrc in backup: $backup"
  fi
  mkdir -p "$MC_STATE/templates"
  stage_current=$(mktemp "$MC_STATE/.restore-current.XXXXXX")
  stage_final=$(mktemp "$MC_STATE/.restore-final.XXXXXX")
  if [[ -e "$MC_TARGET/.zshrc" || -L "$MC_TARGET/.zshrc" ]]; then
    if ! mc_prepare_local_migration "$MC_TARGET/.zshrc" "$BOOTSTRAP_ROOT/zshrc" "$MC_STATE/templates/zshrc" "$MC_TARGET/.zshrc.local" "$stage_current"; then
      rm -f "$stage_current" "$stage_final"
      mc_die 'Could not preserve current personal settings; recovery made no changes'
    fi
  elif [[ -f "$MC_TARGET/.zshrc.local" ]]; then
    cp "$MC_TARGET/.zshrc.local" "$stage_current" || return 1
  fi
  if ! mc_prepare_local_migration "$old" "$BOOTSTRAP_ROOT/zshrc" "$baseline" "$stage_current" "$stage_final"; then
    rm -f "$stage_current" "$stage_final"
    mc_die 'Could not migrate the selected backup; recovery made no changes'
  fi
  # No active config is replaced until both merges have passed syntax checks.
  if [[ ! -f "$MC_TARGET/.zshrc" ]] || ! cmp -s "$BOOTSTRAP_ROOT/zshrc" "$MC_TARGET/.zshrc"; then
    mc_ensure_backup || return 1
    if [[ -e "$MC_TARGET/.zshrc" || -L "$MC_TARGET/.zshrc" ]]; then
      cp -Pp "$MC_TARGET/.zshrc" "$MC_BACKUP_DIR/zshrc" || return 1
      if [[ -f "$MC_STATE/templates/zshrc" ]]; then
        cp -p "$MC_STATE/templates/zshrc" "$MC_BACKUP_DIR/zshrc.template" || return 1
      fi
      if [[ -L "$MC_TARGET/.zshrc" && -f "$MC_TARGET/.zshrc" ]]; then
        cp -p "$MC_TARGET/.zshrc" "$MC_BACKUP_DIR/zshrc.contents" || return 1
      fi
    fi
  fi
  mc_apply_local_migration "$stage_final" || return 1
  rm -f "$stage_current" "$stage_final"
  if [[ ! -f "$MC_TARGET/.zshrc" ]] || ! cmp -s "$BOOTSTRAP_ROOT/zshrc" "$MC_TARGET/.zshrc"; then
    mc_atomic_copy "$BOOTSTRAP_ROOT/zshrc" "$MC_TARGET/.zshrc" || return 1
  fi
  mc_atomic_copy "$BOOTSTRAP_ROOT/zshrc" "$MC_STATE/templates/zshrc" || return 1
  mc_clear_applied_candidates "$BOOTSTRAP_ROOT/zshrc" "$MC_TARGET/.zshrc" zshrc
  mc_log "Personal settings recovered from: $backup"
  mc_log 'Откройте новый терминал или выполните: exec zsh'
  if [[ -n "$MC_BACKUP_DIR" ]]; then mc_log "Backups: $MC_BACKUP_DIR"; fi
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
  local font_dir style blob filename encoded manifest cache_digest cache_marker marker_tmp
  local changed=0
  font_dir=$(mc_font_dir)
  manifest=$(mc_font_manifest)
  while IFS='|' read -r style blob; do
    filename="MesloLGS NF $style.ttf"
    encoded=${filename// /%20}
    if [[ ! -f "$font_dir/$filename" ]] || [[ $(mc_sha256 "$font_dir/$filename") != "$blob" ]]; then changed=1; fi
    mc_download_verified "https://raw.githubusercontent.com/romkatv/powerlevel10k-media/145eb9fbc2f42ee408dacd9b22d8e6e0e553f83d/$encoded" "$font_dir/$filename" "$blob"
  done <<< "$manifest"
  if command -v fc-cache >/dev/null 2>&1; then
    cache_marker="$MC_STATE/font-cache.sha256"
    cache_digest=$(printf '%s\n' "$font_dir" "$manifest" | mc_sha256 -)
    if (( changed )) || [[ ! -f "$cache_marker" || $(cat "$cache_marker") != "$cache_digest" ]]; then
      # A failed or interrupted refresh must be retried, even when repaired fonts
      # have the same content as the previous successful manifest.
      rm -f "$cache_marker"
      if fc-cache -f "$font_dir" >/dev/null; then
        mkdir -p "$MC_STATE"
        marker_tmp=$(mktemp "$MC_STATE/.font-cache.XXXXXX")
        printf '%s\n' "$cache_digest" > "$marker_tmp"
        mc_atomic_copy "$marker_tmp" "$cache_marker"
        rm -f "$marker_tmp"
      else
        mc_warn 'Could not refresh the font cache; the next setup run will retry'
      fi
    fi
  fi
  return 0
}

mc_gsettings_set_if_changed() {
  local schema=$1 key=$2 desired=$3 current
  current=$(gsettings get "$schema" "$key" 2>/dev/null) || return 1
  [[ "$current" != "$desired" && "$current" != "'$desired'" ]] || return 0
  gsettings set "$schema" "$key" "$desired" 2>/dev/null
}

mc_configure_terminal_font() {
  local schemas profile schema
  [[ "$MC_OS" == Linux && "$MC_TARGET" == "$HOME" ]] || return 0
  command -v gsettings >/dev/null 2>&1 || return 0
  # Do not manufacture a D-Bus address on headless/WSL machines.
  [[ -n ${DBUS_SESSION_BUS_ADDRESS:-} ]] || return 0
  schemas=$(gsettings list-schemas 2>/dev/null) || return 0
  if printf '%s\n' "$schemas" | grep -qx org.gnome.Ptyxis; then
    if ! mc_gsettings_set_if_changed org.gnome.Ptyxis use-system-font false \
      || ! mc_gsettings_set_if_changed org.gnome.Ptyxis font-name 'MesloLGS NF 11'; then
      mc_warn 'Select MesloLGS NF in Ptyxis settings'
    fi
  fi
  if printf '%s\n' "$schemas" | grep -qx org.gnome.Terminal.ProfilesList; then
    profile=$(gsettings get org.gnome.Terminal.ProfilesList default 2>/dev/null) || profile=''
    profile=${profile//\'/}
    if [[ -n "$profile" ]]; then
      schema="org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:$profile/"
      if ! mc_gsettings_set_if_changed "$schema" use-system-font false \
        || ! mc_gsettings_set_if_changed "$schema" font 'MesloLGS NF 11'; then
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
  for name in git curl zsh tar python3; do
    if ! command -v "$name" >/dev/null 2>&1; then mc_warn "Missing command: $name"; missing=1; fi
  done
  mc_check_fzf || missing=1
  while IFS='|' read -r name relative url ref commit entry; do
    if [[ ! -r "$MC_TARGET/$relative/$entry" ]]; then
      mc_warn "Missing component: $name"; missing=1
    elif [[ -f "$MC_TARGET/$relative/.git/my-configs-owner" ]] && command -v git >/dev/null 2>&1; then
      current=$(GIT_OPTIONAL_LOCKS=0 git -C "$MC_TARGET/$relative" rev-parse HEAD 2>/dev/null) || current=''
      origin=$(GIT_OPTIONAL_LOCKS=0 git -C "$MC_TARGET/$relative" remote get-url origin 2>/dev/null) || origin=''
      changes=$(GIT_OPTIONAL_LOCKS=0 git -C "$MC_TARGET/$relative" status --porcelain --untracked-files=no 2>/dev/null) || changes='unreadable'
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
    if mc_config_is_pending "$MC_TARGET/$name" "${name#.}"; then
      mc_warn "Configuration is prepared but not activated: $MC_TARGET/$name"; missing=1
    fi
    if [[ ! -r "$MC_TARGET/$name" ]]; then mc_warn "Missing $MC_TARGET/$name"; missing=1
    elif command -v zsh >/dev/null 2>&1; then zsh -n "$MC_TARGET/$name" || missing=1
    fi
  done
  if [[ -e "$MC_TARGET/.zshrc.local" || -L "$MC_TARGET/.zshrc.local" ]]; then
    if [[ ! -f "$MC_TARGET/.zshrc.local" ]] \
      || ! zsh -dfn "$MC_TARGET/.zshrc.local" >/dev/null 2>&1; then
      mc_warn 'Local configuration is unreadable or has invalid zsh syntax'; missing=1
    fi
  fi
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
