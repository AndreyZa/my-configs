#!/usr/bin/env bash
# Optional CLI profile. Docker Desktop/daemon is deliberately installed separately.
# https://mise.jdx.dev/installing-mise.html
set -euo pipefail

CHECK=0
UPDATE=0
SKIP_PACKAGES=0
TARGET_DIR="$HOME"
usage() {
  cat <<'EOF'
Usage: bash scripts/devops.sh [--check] [--update] [--target-dir DIR] [--skip-packages]

Install kubectl, Helm, kubecolor, Terraform, Terragrunt and Ansible through mise.
Ansible uses its own uv-managed Python 3.14, without changing the system Python.
--check          Check the profile, shims and real tool executables; no writes/network.
--update         Resolve current stable releases and save their exact versions.
--target-dir DIR Store this profile and its tool data beneath DIR (default: home).
--skip-packages  Require an existing mise; do not install its OS package.

mise itself is updated by APT/Homebrew. Docker and services are not installed.
EOF
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --update) UPDATE=1 ;;
    --skip-packages) SKIP_PACKAGES=1 ;;
    --target-dir)
      [ "$#" -ge 2 ] || { echo '--target-dir needs a directory' >&2; exit 2; }
      TARGET_DIR=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
case "$TARGET_DIR" in /*) ;; *) echo '--target-dir must be absolute' >&2; exit 2 ;; esac
case "$TARGET_DIR" in *$'\n'*|*$'\t'*) echo '--target-dir cannot contain tabs or newlines' >&2; exit 2 ;; esac
[ "$CHECK" -eq 0 ] || [ "$UPDATE" -eq 0 ] || { echo '--check and --update are mutually exclusive' >&2; exit 2; }

PLATFORM=$(uname -s)
case "$PLATFORM" in Linux|Darwin) ;; *) echo "Unsupported OS: $PLATFORM" >&2; exit 1 ;; esac
CONFIG_DIR="$TARGET_DIR/.config/mise"
DATA_DIR="$TARGET_DIR/.local/share/mise"
CACHE_DIR="$TARGET_DIR/.cache/mise"
STATE_DIR="$TARGET_DIR/.local/state/my-configs"
PROFILE="$CONFIG_DIR/conf.d/my-configs-devops.toml"
STAMP="$STATE_DIR/devops-profile.sha256"
EXECUTABLES="$STATE_DIR/devops-executables.tsv"
COMMANDS=(kubectl helm kubecolor terraform terragrunt ansible ansible-playbook uv)
TOOL_IDS=(kubectl helm kubecolor terraform terragrunt 'pipx:ansible-core' 'pipx:ansible-core' uv)
TOOLS=(kubectl helm kubecolor terraform terragrunt uv 'pipx:ansible-core')
LATEST=(kubectl@latest helm@latest kubecolor@latest terraform@latest terragrunt@latest uv@latest 'pipx:ansible-core@latest')
ANSIBLE_PYTHON_ARGS='--python 3.14'

log() { printf 'devops: %s\n' "$*"; }
die() { printf 'devops: %s\n' "$*" >&2; exit 1; }
digest() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@" | awk '{print $1}'
  else shasum -a 256 "$@" | awk '{print $1}'
  fi
}
file_signature() {
  local mode
  mode=$(stat -c '%a' "$1" 2>/dev/null) || mode=$(stat -f '%Lp' "$1")
  printf '%s:%s\n' "$mode" "$(digest "$1")"
}
shim_signature() {
  if [ ! -f "$1" ] || [ ! -x "$1" ]; then return 1; fi
  if [ -L "$1" ]; then printf 'link:%s\n' "$(readlink "$1")"
  else printf 'file:%s\n' "$(file_signature "$1")"
  fi
}
find_mise() {
  if command -v mise >/dev/null 2>&1; then command -v mise
  elif [ -x /opt/homebrew/bin/mise ]; then printf '%s\n' /opt/homebrew/bin/mise
  elif [ -x /usr/local/bin/mise ]; then printf '%s\n' /usr/local/bin/mise
  else return 1
  fi
}
profile_is_managed() {
  [ -f "$PROFILE" ] && [ -f "$STAMP" ] && [ "$(digest "$PROFILE")" = "$(cat "$STAMP")" ]
}
manifest_field() {
  if [ -f "$EXECUTABLES" ]; then
    awk -F '\t' -v key="$1" -v field="$2" '$1 == key {print $field; exit}' "$EXECUTABLES"
  fi
}
RECIPE_SHA=$(printf '%s\n' "${LATEST[@]}" "$ANSIBLE_PYTHON_ARGS" | digest)
HEALTHY=1
REPAIR_COUNT=0
REPAIR_IDS='|'
REPAIR_TOOLS=()
RECIPE_CHANGED=0
MISE_BIN=$(find_mise) || MISE_BIN=''
mark_repair() {
  case "$REPAIR_IDS" in *"|$1|"*) return ;; esac
  REPAIR_TOOLS[REPAIR_COUNT]=$1
  REPAIR_COUNT=$((REPAIR_COUNT + 1))
  REPAIR_IDS="$REPAIR_IDS$1|"
}
assess_profile() {
  local schema index name executable expected actual record
  profile_is_managed || HEALTHY=0
  schema=$(manifest_field schema 2)
  if [ "$schema" != 2 ] || [ ! -f "$STAMP" ] \
    || [ "$(manifest_field profile_sha256 2)" != "$(cat "$STAMP" 2>/dev/null)" ]; then
    HEALTHY=0
  fi
  if [ -n "$(manifest_field recipe_sha256 2)" ] && [ "$(manifest_field recipe_sha256 2)" != "$RECIPE_SHA" ]; then
    RECIPE_CHANGED=1; HEALTHY=0
  fi
  if [ -z "$MISE_BIN" ] || [ "$MISE_BIN" != "$(manifest_field mise 2)" ] \
    || [ "$(digest "$MISE_BIN" 2>/dev/null || true)" != "$(manifest_field mise 3)" ]; then
    HEALTHY=0
  fi
  index=0
  for name in "${COMMANDS[@]}"; do
    executable=$(manifest_field "exe:$name" 2)
    expected=$(manifest_field "exe:$name" 3)
    if [ "$schema" != 2 ]; then executable=$(manifest_field "$name" 2); fi
    if [ -z "$executable" ]; then
      # Missing/old metadata is discovered with mise which before deciding to repair.
      HEALTHY=0
    elif [ ! -f "$executable" ] || [ ! -x "$executable" ]; then
      mark_repair "${TOOL_IDS[$index]}"; HEALTHY=0
    elif [ "$schema" = 2 ]; then
      if [ -z "$expected" ]; then HEALTHY=0
      elif [ "$(file_signature "$executable")" != "$expected" ]; then
        mark_repair "${TOOL_IDS[$index]}"; HEALTHY=0
      fi
    fi
    actual=$(shim_signature "$DATA_DIR/shims/$name" 2>/dev/null || true)
    if [ -z "$actual" ] || [ "$actual" != "$(manifest_field "shim:$name" 2)" ]; then
      HEALTHY=0
    fi
    index=$((index + 1))
  done
  # Also retain and check auxiliary shims (ansible-galaxy, uvx, etc.).
  if [ -f "$EXECUTABLES" ]; then
    while IFS=$'\t' read -r record expected; do
      case "$record" in
        shim:*)
          name=${record#shim:}
          actual=$(shim_signature "$DATA_DIR/shims/$name" 2>/dev/null || true)
          if [ -z "$actual" ] || [ "$actual" != "$expected" ]; then HEALTHY=0; fi
          ;;
      esac
    done < "$EXECUTABLES"
  fi
}
assess_profile
if [ "$CHECK" -eq 1 ]; then
  if [ "$HEALTHY" -eq 1 ]; then log 'Managed profile, CLI binaries and shims match'; exit 0; fi
  log 'Managed DevOps profile is missing, locally modified or needs repair'
  exit 1
fi
if [ "$UPDATE" -eq 0 ] && [ "$HEALTHY" -eq 1 ]; then
  log 'DevOps profile is already current; no changes'
  exit 0
fi
if [ -e "$PROFILE" ] && ! profile_is_managed && [ "$UPDATE" -eq 0 ]; then
  die "Locally modified profile: $PROFILE. Review it, then rerun with --update."
fi
if [ "$RECIPE_CHANGED" -eq 1 ] && [ "$UPDATE" -eq 0 ]; then
  die 'DevOps tool definitions changed; rerun with --update to apply them'
fi
[ ! -e "$CONFIG_DIR/mise.lock" ] || die "Existing global mise.lock found. Keep it unchanged and integrate this optional profile manually, or use a separate --target-dir."

as_admin() {
  if [ "$(id -u)" -eq 0 ]; then "$@"
  else command -v sudo >/dev/null 2>&1 || die 'sudo is required to install mise'; sudo "$@"
  fi
}
if ! MISE_BIN=$(find_mise); then
  [ "$SKIP_PACKAGES" -eq 0 ] || die 'mise is missing; remove --skip-packages to install it'
  case "$PLATFORM" in
    Linux)
      command -v apt-get >/dev/null 2>&1 || die 'Automatic Linux installation supports Ubuntu/Debian with APT'
      as_admin apt-get update
      as_admin apt-get install -y ca-certificates extrepo
      as_admin extrepo enable mise
      as_admin apt-get update
      as_admin apt-get install -y mise
      ;;
    Darwin)
      if command -v brew >/dev/null 2>&1; then BREW_BIN=$(command -v brew)
      elif [ -x /opt/homebrew/bin/brew ]; then BREW_BIN=/opt/homebrew/bin/brew
      elif [ -x /usr/local/bin/brew ]; then BREW_BIN=/usr/local/bin/brew
      else die 'Homebrew is required; run the base setup with --bootstrap-homebrew first'
      fi
      "$BREW_BIN" install mise
      ;;
  esac
  MISE_BIN=$(find_mise) || die 'mise installation did not expose an executable'
fi


TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/my-configs-devops.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT
ACTIVE_PROFILE="$TEMP_DIR/profile.toml"
ACTIVE_SHIMS_DIR="$TEMP_DIR/shims"
HAD_PROFILE=0
if [ -f "$PROFILE" ]; then
  HAD_PROFILE=1
  cp -p "$PROFILE" "$ACTIVE_PROFILE"
else
  cat > "$ACTIVE_PROFILE" <<'EOF'
# Managed by my-configs/scripts/devops.sh; exact versions are resolved on install.
# Project-level mise config takes priority. Update with: setup.sh --devops --update
[tools]
"pipx:ansible-core" = { version = "latest", uvx_args = "--python 3.14" }
EOF
fi
mise_run() {
  # Both config and state are isolated; existing conf.d fragments cannot shadow
  # the candidate. Only the tool store and the version/download cache are shared.
  (cd / && env MISE_CONFIG_DIR="$TEMP_DIR/config" MISE_GLOBAL_CONFIG_FILE="$ACTIVE_PROFILE" \
    MISE_DATA_DIR="$DATA_DIR" MISE_INSTALLS_DIR="$DATA_DIR/installs" \
    MISE_SHIMS_DIR="$ACTIVE_SHIMS_DIR" MISE_CACHE_DIR="$CACHE_DIR" \
    MISE_STATE_DIR="$TEMP_DIR/state" MISE_LOCKFILE=false MISE_YES=1 \
    UV_PYTHON_INSTALL_DIR="$DATA_DIR/ansible-python" \
    UV_CACHE_DIR="$CACHE_DIR/uv" UV_PYTHON_DOWNLOADS=automatic \
    "$MISE_BIN" "$@")
}
# Resolve without installing. mise use --dry-run-code may report changes even
# for an already-pinned version, so compare stored values through the TOML API.
if [ "$HAD_PROFILE" -eq 0 ] || [ "$UPDATE" -eq 1 ]; then
  for tool in "${TOOLS[@]}"; do
    key="tools.\"$tool\""
    if current=$(mise_run config get --file "$ACTIVE_PROFILE" "$key.version" 2>/dev/null); then
      key="$key.version"
    else
      current=$(mise_run config get --file "$ACTIVE_PROFILE" "$key" 2>/dev/null || true)
    fi
    latest=$(mise_run latest "$tool@latest")
    [[ "$latest" =~ ^[[:alnum:]][[:alnum:].+_-]*$ ]] || die "Invalid latest version returned for $tool"
    if [ "$current" != "$latest" ]; then
      mise_run config set --file "$ACTIVE_PROFILE" --type string -- "$key" "$latest"
    fi
  done
  key='tools."pipx:ansible-core".uvx_args'
  current=$(mise_run config get --file "$ACTIVE_PROFILE" "$key" 2>/dev/null || true)
  if [ "$current" != "$ANSIBLE_PYTHON_ARGS" ]; then
    mise_run config set --file "$ACTIVE_PROFILE" --type string -- "$key" "$ANSIBLE_PYTHON_ARGS"
  fi
fi
PROFILE_CHANGED=1
if [ "$HAD_PROFILE" -eq 1 ] && cmp -s "$ACTIVE_PROFILE" "$PROFILE"; then PROFILE_CHANGED=0; fi
if [ "$PROFILE_CHANGED" -eq 0 ] && [ "$HEALTHY" -eq 1 ]; then
  log 'Current stable versions are already installed; no changes'
  exit 0
fi
if [ "$PROFILE_CHANGED" -eq 1 ]; then mise_run install "${TOOLS[@]}"; fi
if [ "$HAD_PROFILE" -eq 1 ] && [ "$REPAIR_COUNT" -gt 0 ]; then
  mise_run install --force "${REPAIR_TOOLS[@]}"
fi
# Validate all actual executables before exposing the candidate to the shell.
digest "$ACTIVE_PROFILE" > "$TEMP_DIR/digest"
{
  printf 'schema\t2\nprofile_sha256\t%s\n' "$(cat "$TEMP_DIR/digest")"
  printf 'recipe_sha256\t%s\n' "$RECIPE_SHA"
  printf 'mise\t%s\t%s\n' "$MISE_BIN" "$(digest "$MISE_BIN")"
} > "$TEMP_DIR/executables"
index=0
for name in "${COMMANDS[@]}"; do
  executable=$(mise_run which "$name" 2>/dev/null || true)
  if [ ! -f "$executable" ] || [ ! -x "$executable" ]; then
    mise_run install --force "${TOOL_IDS[$index]}"
    executable=$(mise_run which "$name")
    if [ ! -f "$executable" ] || [ ! -x "$executable" ]; then die "mise did not install the $name executable"; fi
  fi
  printf 'exe:%s\t%s\t%s\n' "$name" "$executable" "$(file_signature "$executable")" >> "$TEMP_DIR/executables"
  index=$((index + 1))
done
mise_run reshim
# Only publish our namespace; preserve all unrelated shims and their metadata.
mkdir -p "$DATA_DIR/shims"
for shim in "$ACTIVE_SHIMS_DIR"/*; do
  if [ ! -f "$shim" ] || [ ! -x "$shim" ]; then continue; fi
  name=${shim##*/}
  case "$name" in kubectl|helm|kubecolor|terraform|terragrunt|uv|uvx|ansible|ansible-*) ;; *) continue ;; esac
  identity=$(shim_signature "$shim")
  if [ "$identity" != "$(shim_signature "$DATA_DIR/shims/$name" 2>/dev/null || true)" ]; then
    cp -pP "$shim" "$DATA_DIR/shims/.$name.my-configs-$$"
    mv -f "$DATA_DIR/shims/.$name.my-configs-$$" "$DATA_DIR/shims/$name"
  fi
  printf 'shim:%s\t%s\n' "$name" "$identity" >> "$TEMP_DIR/executables"
done
for name in "${COMMANDS[@]}"; do
  [ -x "$DATA_DIR/shims/$name" ] || die "mise did not create the $name shim"
done
mkdir -p "$CONFIG_DIR/conf.d" "$STATE_DIR"
if [ "$PROFILE_CHANGED" -eq 1 ]; then
  if [ "$HAD_PROFILE" -eq 1 ]; then
    backup_dir=$(mktemp -d "$STATE_DIR/devops-backup-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
    cp -p "$PROFILE" "$backup_dir/my-configs-devops.toml"
    chmod 600 "$backup_dir/my-configs-devops.toml"
    log "Saved profile backup: $backup_dir"
  fi
  cp -p "$ACTIVE_PROFILE" "$PROFILE.my-configs-$$"
  mv -f "$PROFILE.my-configs-$$" "$PROFILE"
fi
if [ ! -f "$EXECUTABLES" ] || ! cmp -s "$TEMP_DIR/executables" "$EXECUTABLES"; then
  cp "$TEMP_DIR/executables" "$EXECUTABLES.my-configs-$$"
  mv -f "$EXECUTABLES.my-configs-$$" "$EXECUTABLES"
fi
if [ ! -f "$STAMP" ] || ! cmp -s "$TEMP_DIR/digest" "$STAMP"; then
  cp "$TEMP_DIR/digest" "$STAMP.my-configs-$$"
  mv -f "$STAMP.my-configs-$$" "$STAMP"
fi
log 'DevOps profile is ready: kubectl, Helm, kubecolor, Terraform, Terragrunt and Ansible.'
log "Open a new shell; managed shims: $DATA_DIR/shims"
log 'Docker Desktop/daemon is a separate installation; no services were changed.'
