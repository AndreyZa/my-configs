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
COMMANDS=(kubectl helm kubecolor terraform terragrunt ansible)
# Registry names use mise's maintained, verified release backends.
TOOLS=(kubectl helm kubecolor terraform terragrunt uv 'pipx:ansible-core')
LATEST=(kubectl@latest helm@latest kubecolor@latest terraform@latest terragrunt@latest uv@latest 'pipx:ansible-core[uvx_args=--python 3.14]@latest')

log() { printf 'devops: %s\n' "$*"; }
die() { printf 'devops: %s\n' "$*" >&2; exit 1; }
digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
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

if [ "$CHECK" -eq 1 ]; then
  missing=0
  find_mise >/dev/null || { log 'Missing mise'; missing=1; }
  profile_is_managed || { log 'Managed DevOps profile is missing or locally modified'; missing=1; }
  if [ ! -f "$EXECUTABLES" ] || [ ! -f "$STAMP" ] \
    || [ "$(awk -F '\t' '$1 == "profile_sha256" {print $2}' "$EXECUTABLES")" != "$(cat "$STAMP")" ]; then
    log 'Executable manifest is missing or stale'; missing=1
  fi
  for name in "${COMMANDS[@]}"; do
    [ -x "$DATA_DIR/shims/$name" ] || { log "Missing shim: $name"; missing=1; }
    executable=''
    if [ -f "$EXECUTABLES" ]; then
      executable=$(awk -F '\t' -v name="$name" '$1 == name {print $2}' "$EXECUTABLES")
    fi
    [ -f "$executable" ] && [ -x "$executable" ] \
      || { log "Missing installed executable: $name"; missing=1; }
  done
  [ "$missing" -eq 0 ] && log 'Managed profile, shims and installed CLI executables are present'
  exit "$missing"
fi

# Refuse to overwrite an existing, untracked/edited profile unless explicitly asked.
if [ -e "$PROFILE" ] && ! profile_is_managed && [ "$UPDATE" -eq 0 ]; then
  die "Locally modified profile: $PROFILE. Review it, then rerun with --update to preserve a backup and update the managed tools."
fi
# This profile uses pinned versions rather than changing a foreign global lockfile.
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

mkdir -p "$CONFIG_DIR/conf.d" "$DATA_DIR" "$CACHE_DIR" "$STATE_DIR"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/my-configs-devops.XXXXXX")
# mise may create shims after each individual install. Keep them private until
# every requested CLI is installed, so a failed first run cannot shadow tools.
ACTIVE_SHIMS_DIR="$TEMP_DIR/shims"
HAD_PROFILE=0
CHANGING_PROFILE=0
if [ -f "$PROFILE" ]; then HAD_PROFILE=1; cp -p "$PROFILE" "$TEMP_DIR/previous.toml"; fi
cleanup() {
  result=$?
  if [ "$result" -ne 0 ] && [ "$CHANGING_PROFILE" -eq 1 ]; then
    if [ "$HAD_PROFILE" -eq 1 ]; then cp -p "$TEMP_DIR/previous.toml" "$PROFILE"
    else rm -f "$PROFILE"
    fi
  fi
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

mise_run() {
  # Read only this profile; never install tools from unrelated global/project config.
  # Exact pinned versions avoid touching a foreign global lockfile.
  (cd / && env MISE_CONFIG_DIR="$CONFIG_DIR" MISE_GLOBAL_CONFIG_FILE="$PROFILE" \
    MISE_DATA_DIR="$DATA_DIR" MISE_INSTALLS_DIR="$DATA_DIR/installs" \
    MISE_SHIMS_DIR="$ACTIVE_SHIMS_DIR" MISE_CACHE_DIR="$CACHE_DIR" \
    MISE_STATE_DIR="$STATE_DIR/mise" MISE_LOCKFILE=false MISE_YES=1 \
    UV_PYTHON_INSTALL_DIR="$DATA_DIR/ansible-python" \
    UV_CACHE_DIR="$CACHE_DIR/uv" UV_PYTHON_DOWNLOADS=automatic \
    "$MISE_BIN" "$@")
}

if [ "$HAD_PROFILE" -eq 0 ] || [ "$UPDATE" -eq 1 ]; then
  if [ "$HAD_PROFILE" -eq 1 ]; then
    backup_dir=$(mktemp -d "$STATE_DIR/devops-backup-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
    cp -p "$PROFILE" "$backup_dir/my-configs-devops.toml"
    chmod 600 "$backup_dir/my-configs-devops.toml"
    log "Saved profile backup: $backup_dir"
  fi
  CHANGING_PROFILE=1
  if [ "$HAD_PROFILE" -eq 0 ]; then
    cat > "$TEMP_DIR/profile.toml" <<'EOF'
# Managed by my-configs/scripts/devops.sh; exact versions are resolved on install.
# Project-level mise config takes priority. Update with: setup.sh --devops --update
[tools]
EOF
    mv "$TEMP_DIR/profile.toml" "$PROFILE"
  fi
  mise_run use --global --pin "${LATEST[@]}"
else
  mise_run install "${TOOLS[@]}"
fi
digest "$PROFILE" > "$TEMP_DIR/digest"
printf 'profile_sha256\t%s\n' "$(cat "$TEMP_DIR/digest")" > "$TEMP_DIR/executables"
for name in "${COMMANDS[@]}"; do
  executable=$(mise_run which "$name")
  [ -f "$executable" ] && [ -x "$executable" ] || die "mise did not install the $name executable"
  printf '%s\t%s\n' "$name" "$executable" >> "$TEMP_DIR/executables"
done
ACTIVE_SHIMS_DIR="$DATA_DIR/shims"
mise_run reshim
for name in "${COMMANDS[@]}"; do
  [ -x "$DATA_DIR/shims/$name" ] || die "mise did not create the $name shim"
done
if [ ! -f "$EXECUTABLES" ] || ! cmp -s "$TEMP_DIR/executables" "$EXECUTABLES"; then
  mv "$TEMP_DIR/executables" "$EXECUTABLES"
fi
if [ ! -f "$STAMP" ] || ! cmp -s "$TEMP_DIR/digest" "$STAMP"; then
  mv "$TEMP_DIR/digest" "$STAMP"
fi
CHANGING_PROFILE=0
log "Installed kubectl, Helm, kubecolor, Terraform, Terragrunt and Ansible."
log "Open a new shell; managed shims: $DATA_DIR/shims"
log 'Docker Desktop/daemon is a separate installation; no services were changed.'
