#!/usr/bin/env bash
# Real portable CLI installation into isolated mise directories; no services.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/my-configs-devops-integration.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
target="$fixture/profile with spaces"
"$BASH" "$repo/scripts/devops.sh" --target-dir "$target"
"$BASH" "$repo/scripts/devops.sh" --check --target-dir "$target"
profile="$target/.config/mise/conf.d/my-configs-devops.toml"
cp "$profile" "$fixture/profile.before"
"$BASH" "$repo/scripts/devops.sh" --skip-packages --target-dir "$target"
cmp "$profile" "$fixture/profile.before"

# Resolve only this fixture's tools; HOME and other global/project configs stay intact.
export MISE_CONFIG_DIR="$target/.config/mise"
export MISE_GLOBAL_CONFIG_FILE="$profile"
export MISE_DATA_DIR="$target/.local/share/mise"
export MISE_CACHE_DIR="$target/.cache/mise"
export MISE_STATE_DIR="$target/.local/state/my-configs/mise"
export MISE_LOCKFILE=false
export UV_PYTHON_INSTALL_DIR="$MISE_DATA_DIR/ansible-python"
export UV_CACHE_DIR="$MISE_CACHE_DIR/uv"
export PATH="$MISE_DATA_DIR/shims:$PATH"
cd /
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
