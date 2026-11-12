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
REPAIR_IDS='|'
RECIPE_CHANGED=0
MISE_BIN=$(find_mise) || MISE_BIN=''
mark_repair() {
  case "$REPAIR_IDS" in *"|$1|"*) return ;; esac
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
      # Retry a previously unavailable tool even if mise left install metadata.
      if [ -n "$(manifest_field "missing:$name" 2)" ]; then mark_repair "${TOOL_IDS[$index]}"; fi
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
  for name in "${COMMANDS[@]}"; do
    reason=$(manifest_field "missing:$name" 2)
    if [ -n "$reason" ]; then log "Missing $name: $reason"; fi
  done
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
EOF
fi
mise_run() {
  # Both config and state are isolated; existing conf.d fragments cannot shadow
  # the candidate. Only the tool store and the version/download cache are shared.
  (cd / && env MISE_CONFIG_DIR="$TEMP_DIR/config" MISE_GLOBAL_CONFIG_FILE="$ACTIVE_PROFILE" \
    MISE_DATA_DIR="$DATA_DIR" MISE_INSTALLS_DIR="$DATA_DIR/installs" \
    MISE_SHIMS_DIR="$ACTIVE_SHIMS_DIR" MISE_CACHE_DIR="$CACHE_DIR" \
    MISE_STATE_DIR="$TEMP_DIR/state" MISE_LOCKFILE=false MISE_YES=1 NO_COLOR=1 \
    UV_PYTHON_INSTALL_DIR="$DATA_DIR/ansible-python" \
    UV_CACHE_DIR="$CACHE_DIR/uv" UV_PYTHON_DOWNLOADS=automatic \
    "$MISE_BIN" "$@")
}
# Each tool is processed independently. Only an unambiguous final mise HTTP
# 404 is optional: integrity failures and every other error still stop the run.
READY_TOOLS='|'
MISSING_TOOLS='|'
MISSING_COUNT=0
HTTP_404_COUNT=0
warn() { printf 'devops: WARNING: %s\n' "$*" >&2; }
is_http_404() {
  local escaped errors
  escaped=$(printf '\033')
  errors="$TEMP_DIR/primary-errors"
  sed -E "s/${escaped}\\[[0-9;]*[[:alpha:]]//g" "$1" \
    | grep '^mise ERROR ' \
    | grep -Ev '^mise ERROR (Version:|Run with )' > "$errors" || true
  [ -s "$errors" ] || return 1
  # Do not accept an earlier 404 warning when the final failure is unrelated.
  if grep -Eiv '^mise ERROR (Failed to (install|download|resolve|fetch) [^[:space:]]+: )?HTTP status client error \(404 Not Found\) for url \([^)]*\)[[:space:]]*$' "$errors" >/dev/null; then return 1; fi
  if grep -Ei 'checksum.*(mismatch|verification failed)|hash.*mismatch|integrity.*(failed|error)|HTTP status (client|server) error \((40[0-35-9]|4[1-9][0-9]|5[0-9][0-9])' "$errors" >/dev/null; then return 1; fi
}
run_optional_download() {
  local result output
  local -a pipeline_status
  if [ "$1" = latest ]; then
    # stdout is the version consumed by the caller; do not mix progress into it.
    if mise_run "$@" > "$TEMP_DIR/mise.stdout" 2> "$TEMP_DIR/mise.stderr"; then
      cat "$TEMP_DIR/mise.stdout"
      cat "$TEMP_DIR/mise.stderr" >&2
      return 0
    else
      result=$?
      cat "$TEMP_DIR/mise.stdout"
      cat "$TEMP_DIR/mise.stderr" >&2
      output="$TEMP_DIR/mise.stderr"
    fi
  else
    # Keep long downloads visible. Wait for tee to finish before inspecting the
    # complete log, and never mistake a failed log write for an optional 404.
    output="$TEMP_DIR/mise.install.log"
    if mise_run "$@" 2>&1 | tee "$output"; then return 0
    else pipeline_status=("${PIPESTATUS[@]}")
    fi
    if [ "${pipeline_status[1]}" -ne 0 ]; then
      printf 'devops: cannot save the complete mise download log\n' >&2
      return 1
    fi
    result=${pipeline_status[0]}
  fi
  if is_http_404 "$output"; then return 44; fi
  printf 'devops: mise failed (exit %s); refusing to ignore this error\n' "$result" >&2
  return 1
}
contains_tool() { case "$1" in *"|$2|"*) return 0 ;; *) return 1 ;; esac; }
shim_tool() {
  case "$1" in
    kubectl|helm|kubecolor|terraform|terragrunt|uv) printf '%s\n' "$1" ;;
    uvx) printf 'uv\n' ;;
    ansible|ansible-*) printf 'pipx:ansible-core\n' ;;
    *) return 1 ;;
  esac
}
stored_version() {
  local key="tools.$1"
  if mise_run config get --file "$ACTIVE_PROFILE" "$key.version" 2>/dev/null; then return 0; fi
  mise_run config get --file "$ACTIVE_PROFILE" "$key" 2>/dev/null
}
tool_available() {
  local index=0 name executable
  for name in "${COMMANDS[@]}"; do
    if [ "${TOOL_IDS[$index]}" = "$1" ]; then
      executable=$(mise_run which "$name" 2>/dev/null || true)
      if [ ! -f "$executable" ] || [ ! -x "$executable" ]; then return 1; fi
    fi
    index=$((index + 1))
  done
}
keep_or_skip() {
  # The snapshot predates only this tool, so earlier successful tools survive.
  cp -p "$TEMP_DIR/before-tool.toml" "$ACTIVE_PROFILE"
  if [ "$old_healthy" -eq 1 ]; then
    READY_TOOLS="$READY_TOOLS$tool|"
    warn "$tool: $1; keeping installed version $current"
  else
    # Remove the unavailable selection, otherwise mise could try to install it
    # implicitly when a different shim is used. This command only edits TOML.
    if [ -n "$current" ]; then mise_run use --global --remove "$tool" >/dev/null; fi
    MISSING_TOOLS="$MISSING_TOOLS$tool|"
    MISSING_COUNT=$((MISSING_COUNT + 1))
    warn "$tool: $1; skipped (rerun --devops to retry)"
  fi
}
for tool in "${TOOLS[@]}"; do
  cp -p "$ACTIVE_PROFILE" "$TEMP_DIR/before-tool.toml"
  current=$(stored_version "$tool" || true)
  old_healthy=0
  if [ -n "$current" ] && ! contains_tool "$REPAIR_IDS" "$tool"; then
    if [ "$HEALTHY" -eq 1 ] || tool_available "$tool"; then old_healthy=1; fi
  fi
  # A working old Ansible environment is usable without uv. Installing a new
  # environment, however, requires uv; do not fall back to a global pipx/Python.
  if [ "$tool" = 'pipx:ansible-core' ] && ! contains_tool "$READY_TOOLS" uv; then
    keep_or_skip 'uv is unavailable after HTTP 404'
    continue
  fi
  latest=$current
  if [ -z "$current" ] || [ "$UPDATE" -eq 1 ]; then
    if latest=$(run_optional_download latest "$tool@latest"); then :
    else
      result=$?
      if [ "$result" -ne 44 ]; then die "Cannot resolve $tool"; fi
      HTTP_404_COUNT=$((HTTP_404_COUNT + 1))
      keep_or_skip 'HTTP 404 while resolving the version'
      continue
    fi
    [[ "$latest" =~ ^[[:alnum:]][[:alnum:].+_-]*$ ]] || die "Invalid latest version returned for $tool"
  fi
  # Bare CLI paths work on older mise; quoted TOML keys are written by mise.
  key="tools.$tool"
  if [ "$tool" = 'pipx:ansible-core' ] || mise_run config get --file "$ACTIVE_PROFILE" "$key.version" >/dev/null 2>&1; then key="$key.version"; fi
  if [ "$current" != "$latest" ]; then mise_run config set --file "$ACTIVE_PROFILE" --type string -- "$key" "$latest"; fi
  options_changed=0
  if [ "$tool" = 'pipx:ansible-core' ]; then
    key='tools.pipx:ansible-core.uvx_args'
    option=$(mise_run config get --file "$ACTIVE_PROFILE" "$key" 2>/dev/null || true)
    if [ "$option" != "$ANSIBLE_PYTHON_ARGS" ]; then
      mise_run config set --file "$ACTIVE_PROFILE" --type string -- "$key" "$ANSIBLE_PYTHON_ARGS"
      options_changed=1
    fi
  fi
  if [ "$old_healthy" -eq 0 ] || [ "$current" != "$latest" ] || [ "$options_changed" -eq 1 ]; then
    install_args=(install)
    if contains_tool "$REPAIR_IDS" "$tool" \
      || { [ -n "$current" ] && [ "$current" = "$latest" ] && [ "$old_healthy" -eq 0 ]; }; then install_args+=(--force); fi
    if run_optional_download "${install_args[@]}" "$tool"; then :
    else
      result=$?
      if [ "$result" -ne 44 ]; then die "Cannot install $tool"; fi
      HTTP_404_COUNT=$((HTTP_404_COUNT + 1))
      keep_or_skip 'HTTP 404 while downloading the release'
      continue
    fi
  fi
  tool_available "$tool" || die "mise did not install the $tool executable"
  READY_TOOLS="$READY_TOOLS$tool|"
done
PROFILE_CHANGED=1
if [ "$HAD_PROFILE" -eq 1 ] && cmp -s "$ACTIVE_PROFILE" "$PROFILE"; then PROFILE_CHANGED=0; fi
if [ "$PROFILE_CHANGED" -eq 0 ] && [ "$HEALTHY" -eq 1 ]; then
  if [ "$HTTP_404_COUNT" -gt 0 ]; then log 'Installed versions retained; some updates were unavailable'
  else log 'Current stable versions are already installed; no changes'
  fi
  exit 0
fi
# Validate and record only successful tools; missing entries keep --check honest.
digest "$ACTIVE_PROFILE" > "$TEMP_DIR/digest"
{
  printf 'schema\t2\nprofile_sha256\t%s\n' "$(cat "$TEMP_DIR/digest")"
  printf 'recipe_sha256\t%s\n' "$RECIPE_SHA"
  printf 'mise\t%s\t%s\n' "$MISE_BIN" "$(digest "$MISE_BIN")"
} > "$TEMP_DIR/executables"
index=0
for name in "${COMMANDS[@]}"; do
  tool=${TOOL_IDS[$index]}
  if contains_tool "$MISSING_TOOLS" "$tool"; then
    printf 'missing:%s\tHTTP 404 or unavailable uv dependency\n' "$name" >> "$TEMP_DIR/executables"
  else
    executable=$(mise_run which "$name")
    if [ ! -f "$executable" ] || [ ! -x "$executable" ]; then die "mise did not install the $name executable"; fi
    printf 'exe:%s\t%s\t%s\n' "$name" "$executable" "$(file_signature "$executable")" >> "$TEMP_DIR/executables"
  fi
  index=$((index + 1))
done
mise_run reshim
# Only publish our namespace; preserve all unrelated shims and their metadata.
mkdir -p "$DATA_DIR/shims"
for shim in "$ACTIVE_SHIMS_DIR"/*; do
  if [ ! -f "$shim" ] || [ ! -x "$shim" ]; then continue; fi
  name=${shim##*/}
  tool=$(shim_tool "$name") || continue
  contains_tool "$READY_TOOLS" "$tool" || continue
  identity=$(shim_signature "$shim")
  if [ "$identity" != "$(shim_signature "$DATA_DIR/shims/$name" 2>/dev/null || true)" ]; then
    cp -pP "$shim" "$DATA_DIR/shims/.$name.my-configs-$$"
    mv -f "$DATA_DIR/shims/.$name.my-configs-$$" "$DATA_DIR/shims/$name"
  fi
  printf 'shim:%s\t%s\n' "$name" "$identity" >> "$TEMP_DIR/executables"
done
for name in "${COMMANDS[@]}"; do
  tool=$(shim_tool "$name")
  if contains_tool "$READY_TOOLS" "$tool"; then
    [ -x "$DATA_DIR/shims/$name" ] || die "mise did not create the $name shim"
  fi
done
# Remove only our unchanged old shims for now-missing tools, never foreign ones.
if [ -f "$EXECUTABLES" ]; then
  while IFS=$'\t' read -r record expected; do
    case "$record" in shim:*) name=${record#shim:} ;; *) continue ;; esac
    tool=$(shim_tool "$name") || continue
    contains_tool "$MISSING_TOOLS" "$tool" || continue
    identity=''
    if [ -L "$DATA_DIR/shims/$name" ]; then identity="link:$(readlink "$DATA_DIR/shims/$name")"
    elif [ -f "$DATA_DIR/shims/$name" ]; then identity="file:$(file_signature "$DATA_DIR/shims/$name")"
    fi
    if [ -n "$identity" ] && [ "$identity" = "$expected" ]; then rm -f "$DATA_DIR/shims/$name"; fi
  done < "$EXECUTABLES"
fi
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
if [ "$MISSING_COUNT" -gt 0 ]; then
  warn "DevOps profile is partial: $MISSING_COUNT tool(s) unavailable; --check will report missing commands"
else
  log 'DevOps profile is ready: kubectl, Helm, kubecolor, Terraform, Terragrunt and Ansible.'
fi
log "Open a new shell; managed shims: $DATA_DIR/shims"
log 'Docker Desktop/daemon is a separate installation; no services were changed.'
