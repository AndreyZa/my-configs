#!/usr/bin/env bash
# Real portable CLI installation into isolated mise directories; no services.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/my-configs-devops-integration.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
target="$fixture/profile with spaces"
"$BASH" "$repo/scripts/devops.sh" --target-dir "$target"
profile="$target/.config/mise/conf.d/my-configs-devops.toml"
# Resolve only this fixture's tools; HOME and unrelated config stay intact.
export MISE_CONFIG_DIR="$target/.config/mise"
export MISE_GLOBAL_CONFIG_FILE="$profile"
export MISE_DATA_DIR="$target/.local/share/mise"
export MISE_CACHE_DIR="$target/.cache/mise"
# Version-observation bookkeeping belongs to the test, not the installed tree.
export MISE_STATE_DIR="$fixture/query-state"
export MISE_LOCKFILE=false
export UV_PYTHON_INSTALL_DIR="$MISE_DATA_DIR/ansible-python"
export UV_CACHE_DIR="$MISE_CACHE_DIR/uv"
export PATH="$MISE_DATA_DIR/shims:$PATH"
cd /
snapshot_versions() {
  mise ls --current --json | python3 -c '
import json, sys
tools = json.load(sys.stdin)
print(json.dumps({name: sorted(item["version"] for item in versions)
                  for name, versions in tools.items()}, sort_keys=True))
'
}
cp "$profile" "$fixture/profile.before"
snapshot_versions > "$fixture/versions.before"
python3 "$repo/tests/snapshot_tree.py" capture "$target" "$fixture/before-repeat.json"
"$BASH" "$repo/scripts/devops.sh" --check --target-dir "$target"
"$BASH" "$repo/scripts/devops.sh" --skip-packages --target-dir "$target"
python3 "$repo/tests/snapshot_tree.py" check "$target" "$fixture/before-repeat.json"
cmp "$profile" "$fixture/profile.before"

# Explicit refresh may change resolver caches, but identical resolved versions
# must not rewrite live configuration, installed binaries, shims or backups.
python3 "$repo/tests/snapshot_tree.py" capture "$target" "$fixture/before-update.json" \
  --exclude .cache/mise
"$BASH" "$repo/scripts/devops.sh" --skip-packages --update --target-dir "$target"
snapshot_versions > "$fixture/versions.after"
if cmp -s "$fixture/versions.before" "$fixture/versions.after"; then
  cmp "$profile" "$fixture/profile.before"
  python3 "$repo/tests/snapshot_tree.py" check "$target" "$fixture/before-update.json"
else
  printf '%s\n' 'A new upstream version appeared during the check; update changed the profile.'
fi

"$MISE_DATA_DIR/shims/kubectl" version --client
"$MISE_DATA_DIR/shims/helm" version --short
# kubecolor forwards kubectl arguments; exercise it with the managed kubectl.
"$MISE_DATA_DIR/shims/kubecolor" version --client
"$MISE_DATA_DIR/shims/terraform" version
"$MISE_DATA_DIR/shims/terragrunt" --version
"$MISE_DATA_DIR/shims/ansible" --version
test ! -e "$MISE_DATA_DIR/shims/python"
test ! -e "$MISE_DATA_DIR/shims/python3"

# Inject one real-CLI-boundary failure without relying on an upstream outage.
# Other mise operations and the remaining installed tools stay real.
export MY_CONFIGS_REAL_MISE
MY_CONFIGS_REAL_MISE=$(command -v mise)
terraform_executable=$(mise which terraform)
python3 - "$target" "$terraform_executable" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1]).resolve()
executable = Path(sys.argv[2])
executable.resolve(strict=True).relative_to(root)
assert executable.is_file()
PY
cp -pP "$terraform_executable" "$fixture/terraform-before-404"
rm "$terraform_executable"
mkdir -p "$fixture/fault-bin"
cat > "$fixture/fault-bin/mise" <<'FAULT'
#!/bin/sh
# mise may link generated shims to the wrapper found in PATH. Preserve that
# dispatch contract instead of turning `kubectl version` into `mise version`.
if [ "${0##*/}" != mise ]; then
  exec "$MY_CONFIGS_REAL_MISE" exec -- "${0##*/}" "$@"
fi
if [ "${MY_CONFIGS_INJECT_404:-0}" = 1 ] && [ "${1:-}" = install ]; then
  for argument do
    case "$argument" in
      terraform|terraform@*)
        printf '%s\n' 'mise ERROR Failed to install aqua:hashicorp/terraform: HTTP status client error (404 Not Found) for url (https://example.invalid/terraform.zip)' >&2
        exit 1
        ;;
    esac
  done
fi
exec "$MY_CONFIGS_REAL_MISE" "$@"
FAULT
chmod +x "$fixture/fault-bin/mise"
export PATH="$fixture/fault-bin:$PATH"
export MY_CONFIGS_INJECT_404=1
"$BASH" "$repo/scripts/devops.sh" --skip-packages --target-dir "$target" > "$fixture/404.log" 2>&1
grep -qi 'warning' "$fixture/404.log"
grep -q '404' "$fixture/404.log"
if "$BASH" "$repo/scripts/devops.sh" --check --target-dir "$target" > "$fixture/404-check.log" 2>&1; then
  printf '%s\n' 'Incomplete HTTP 404 install incorrectly passed --check' >&2
  exit 1
fi
test ! -e "$MISE_DATA_DIR/shims/terraform"
test ! -L "$MISE_DATA_DIR/shims/terraform"
for command in kubectl helm kubecolor terragrunt ansible; do
  test -x "$MISE_DATA_DIR/shims/$command"
done
"$MISE_DATA_DIR/shims/kubectl" version --client
"$MISE_DATA_DIR/shims/helm" version --short
"$MISE_DATA_DIR/shims/ansible" --version
printf '%s\n' 'HTTP 404 warned and continued; incomplete profile and remaining CLIs verified'

# Recovered availability completes the profile on the next ordinary run.
unset MY_CONFIGS_INJECT_404
cp -pP "$fixture/terraform-before-404" "$terraform_executable"
"$BASH" "$repo/scripts/devops.sh" --skip-packages --target-dir "$target"
"$BASH" "$repo/scripts/devops.sh" --check --target-dir "$target"
python3 "$repo/tests/snapshot_tree.py" capture "$target" "$fixture/after-recovery.json"
"$BASH" "$repo/scripts/devops.sh" --skip-packages --target-dir "$target"
python3 "$repo/tests/snapshot_tree.py" check "$target" "$fixture/after-recovery.json"
printf '%s\n' 'DevOps CLI installation and pinned repeatability OK'
