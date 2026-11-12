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
printf '%s\n' 'DevOps CLI installation and pinned repeatability OK'
