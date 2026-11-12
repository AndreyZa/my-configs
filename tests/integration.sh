#!/usr/bin/env bash
# Real dependency downloads and shell load; use only with prerequisites installed.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/my-configs-integration.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
target="$fixture/target with spaces"

# Invoke from another directory to catch accidental reliance on the caller's cwd.
cd "$fixture"
bash "$repo/setup.sh" --skip-packages --no-chsh --target-dir "$target"
bash "$repo/setup.sh" --check --target-dir "$target"
python3 "$repo/tests/pty_smoke.py" "$target"

printf '%s\n' 'local user plugin' > "$target/.oh-my-zsh/custom/keep-user-file"
printf '%s\n' '# local aliases are preserved' > "$target/.zshrc.local"
cp "$target/.zshrc" "$fixture/original-zshrc"
bash "$repo/setup.sh" --skip-packages --no-chsh --target-dir "$target"
cmp "$target/.zshrc" "$fixture/original-zshrc"
test -f "$target/.oh-my-zsh/custom/keep-user-file"
test -f "$target/.zshrc.local"

printf '%s\n' '# manual customization' >> "$target/.zshrc"
cp "$target/.zshrc" "$fixture/custom-zshrc"
bash "$repo/setup.sh" --skip-packages --no-chsh --target-dir "$target"
cmp "$target/.zshrc" "$fixture/custom-zshrc"
test -f "$target/.zshrc.my-configs-new"
cmp "$target/.zshrc.my-configs-new" "$repo/zshrc"
printf '%s\n' 'Real install, repeated install and user-config preservation OK'
