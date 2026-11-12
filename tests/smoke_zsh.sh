#!/usr/bin/env bash
# Exercise the portable configuration without changing HOME, user history or tools.
# The single-quoted test programs are expanded by the child zsh, not this script.
# shellcheck disable=SC2016
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
zsh_bin="$(command -v zsh)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/my-configs-zsh.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

mkdir -p "$test_dir/minimal" "$test_dir/full/bin" "$test_dir/full/mise/shims"

# The base configuration also starts quietly when optional dependencies are absent.
env ZDOTDIR="$test_dir/minimal" ZSH="$test_dir/minimal/.oh-my-zsh" \
  ZSH_CUSTOM="$test_dir/minimal/.oh-my-zsh/custom" \
  XDG_CACHE_HOME="$test_dir/minimal/cache" HISTFILE=/dev/null \
  MISE_DATA_DIR="$test_dir/minimal/mise" MY_CONFIGS_SMOKE_RC="$repo_dir/zshrc" \
  "$zsh_bin" -dfc '
    source "$MY_CONFIGS_SMOKE_RC" || exit 1
    [[ "$HISTFILE" == /dev/null && $HISTSIZE == 50000 && $SAVEHIST == 50000 ]] || exit 2
    [[ -z "$ZSH_THEME" && -n "$PROMPT" && ${#plugins} == 0 ]] || exit 3
    unique_path=("${(@u)path}")
    [[ ${#unique_path} == ${#path} ]] || exit 4
  '

fixture="$test_dir/full"
mkdir -p "$fixture/.oh-my-zsh/.git"
: > "$fixture/.oh-my-zsh/.git/my-configs-owner"
for command in git kubectl kubecolor terragrunt fzf; do
  printf '#!/bin/sh\nexit 0\n' > "$fixture/bin/$command"
  chmod +x "$fixture/bin/$command"
done
# Older fzf packages reject --zsh and require their separately installed script.
printf '#!/bin/sh\nexit 2\n' > "$fixture/bin/fzf"
cp "$fixture/bin/kubectl" "$fixture/mise/shims/kubectl"

for plugin in git kubectl brew; do
  mkdir -p "$fixture/.oh-my-zsh/plugins/$plugin"
  : > "$fixture/.oh-my-zsh/plugins/$plugin/$plugin.plugin.zsh"
done
for plugin in zsh-kubecolor terragrunt zsh-autosuggestions zsh-syntax-highlighting; do
  mkdir -p "$fixture/.oh-my-zsh/custom/plugins/$plugin"
  : > "$fixture/.oh-my-zsh/custom/plugins/$plugin/$plugin.plugin.zsh"
done
printf 'LEGACY_TG_PLUGIN_LOADED=1\n' \
  > "$fixture/.oh-my-zsh/custom/plugins/terragrunt/terragrunt.plugin.zsh"
mkdir -p "$fixture/.oh-my-zsh/custom/themes/powerlevel10k"
: > "$fixture/.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme"

cat > "$fixture/.oh-my-zsh/oh-my-zsh.sh" <<'ZSH'
typeset -ga TEST_LOAD_ORDER=(omz)
typeset -gA _comps
compdef() {
  local completion=$1 name
  shift
  for name in "$@"; do _comps[$name]=$completion; done
}
fpath=("$ZSH/plugins/kubectl" "${fpath[@]}")
for plugin in "${plugins[@]}"; do
  if [[ -r "$ZSH_CUSTOM/plugins/$plugin/$plugin.plugin.zsh" ]]; then
    source "$ZSH_CUSTOM/plugins/$plugin/$plugin.plugin.zsh"
  else
    source "$ZSH/plugins/$plugin/$plugin.plugin.zsh"
  fi
done
ZSH
printf '_comps[kubectl]=_kubectl\n' > "$fixture/.oh-my-zsh/plugins/kubectl/kubectl.plugin.zsh"
printf 'return 0\n' > "$fixture/.oh-my-zsh/plugins/kubectl/_kubectl"
cat > "$fixture/.oh-my-zsh/custom/plugins/zsh-kubecolor/zsh-kubecolor.plugin.zsh" <<'ZSH'
_comps[kubectl]=legacy_bash_completion
alias kg='kubecolor get'
ZSH
cat > "$fixture/.zshrc.local" <<'ZSH'
TEST_LOAD_ORDER+=(local)
alias local_probe='true'
ZSH
printf 'TEST_LOAD_ORDER+=(autosuggestions)\n' \
  > "$fixture/.oh-my-zsh/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
printf 'TEST_LOAD_ORDER+=(highlighting)\n' \
  > "$fixture/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"

mkdir -p "$fixture/fzf/shell" "$fixture/brew/bin" "$fixture/brew/sbin" \
  "$fixture/brew/opt/fzf/shell"
cat > "$fixture/fzf/shell/key-bindings.zsh" <<'ZSH'
(( TEST_FZF_INIT_COUNT += 1 ))
fzf-file-widget() { :; }
fzf-history-widget() { :; }
fzf-cd-widget() { :; }
zle -N fzf-file-widget
zle -N fzf-history-widget
zle -N fzf-cd-widget
bindkey '^R' fzf-history-widget
bindkey '^[c' fzf-cd-widget
ZSH
cp "$fixture/fzf/shell/key-bindings.zsh" "$fixture/brew/opt/fzf/shell/key-bindings.zsh"
printf '#!/bin/sh\nprintf "brew should not run during shell startup\\n" >&2\nexit 99\n' \
  > "$fixture/brew/bin/brew"
chmod +x "$fixture/brew/bin/brew"

for platform in linux darwin; do
  env ZDOTDIR="$fixture" ZSH="$fixture/.oh-my-zsh" \
    ZSH_CUSTOM="$fixture/.oh-my-zsh/custom" XDG_CACHE_HOME="$fixture/cache" \
    HISTFILE=/dev/null MISE_DATA_DIR="$fixture/mise" \
    PATH="$fixture/bin:$PATH" FZF_DEFAULT_OPTS='--height=40%' \
    MY_CONFIGS_SMOKE_RC="$repo_dir/zshrc" MY_CONFIGS_SMOKE_PLATFORM="$platform" \
    "$zsh_bin" -dfc '
      if [[ "$MY_CONFIGS_SMOKE_PLATFORM" == darwin ]]; then
        OSTYPE=darwin-test
        export HOMEBREW_PREFIX="$ZDOTDIR/brew"
        unset FZF_BASE
      else
        OSTYPE=linux-test
        export FZF_BASE="$ZDOTDIR/fzf"
      fi
      source "$MY_CONFIGS_SMOKE_RC" || exit 10
      zstyle -s ":omz:update" mode test_update_mode
      [[ "$test_update_mode" == disabled ]] || exit 28
      [[ "${TEST_LOAD_ORDER[*]}" == "omz local autosuggestions highlighting" ]] || exit 11
      [[ $TEST_FZF_INIT_COUNT == 1 && $FZF_DEFAULT_OPTS == "--height=40%" ]] || exit 12
      [[ "$(bindkey -M emacs "^[^F")" == *fzf-file-widget ]] || exit 13
      [[ "$(bindkey -M viins "^[^F")" == *fzf-file-widget ]] || exit 14
      [[ "$(bindkey "^R")" == *fzf-history-widget ]] || exit 15
      [[ "$(bindkey "^[c")" == *fzf-cd-widget ]] || exit 16
      [[ $aliases[tg] == terragrunt && $aliases[k] == kubecolor ]] || exit 17
      [[ ${+LEGACY_TG_PLUGIN_LOADED} == 0 && ${plugins[(Ie)terragrunt]} == 0 ]] || exit 29
      [[ $aliases[kg] == "kubecolor get" && $aliases[local_probe] == true ]] || exit 18
      [[ $_comps[kubectl] == _kubectl && $_comps[kubecolor] == _kubectl ]] || exit 19
      autoload +X _kubectl || exit 20
      [[ "$(whence -p kubectl)" == "$MISE_DATA_DIR/shims/kubectl" ]] || exit 21
      if [[ "$MY_CONFIGS_SMOKE_PLATFORM" == darwin ]]; then
        [[ ${plugins[(Ie)brew]} != 0 ]] || exit 22
        [[ "$(whence -p brew)" == "$HOMEBREW_PREFIX/bin/brew" ]] || exit 23
      else
        [[ ${plugins[(Ie)brew]} == 0 ]] || exit 24
      fi
      source "$MY_CONFIGS_SMOKE_RC" || exit 25
      unique_path=("${(@u)path}")
      [[ ${#unique_path} == ${#path} && $TEST_FZF_INIT_COUNT == 1 ]] || exit 26
      [[ "$HISTFILE" == /dev/null && $SAVEHIST == 50000 ]] || exit 27
    '
done

managed_bin="$fixture/.local/share/my-configs/bin"
mkdir -p "$managed_bin"
{
  printf '#!/bin/sh\n[ "$1" = --zsh ] || exit 2\ncat <<\047ZSH\047\n'
  printf 'TEST_FZF_SOURCE=native\n'
  cat "$fixture/fzf/shell/key-bindings.zsh"
  printf 'ZSH\n'
} > "$managed_bin/fzf"
chmod +x "$managed_bin/fzf"
env ZDOTDIR="$fixture" ZSH="$fixture/.oh-my-zsh" \
  ZSH_CUSTOM="$fixture/.oh-my-zsh/custom" XDG_CACHE_HOME="$fixture/cache" \
  HISTFILE=/dev/null MISE_DATA_DIR="$fixture/mise" PATH="$fixture/bin:$PATH" \
  FZF_BASE="$fixture/fzf" MY_CONFIGS_SMOKE_RC="$repo_dir/zshrc" \
  "$zsh_bin" -dfc '
    source "$MY_CONFIGS_SMOKE_RC" || exit 30
    [[ "$(whence -p fzf)" == "$ZDOTDIR/.local/share/my-configs/bin/fzf" ]] || exit 31
    [[ $TEST_FZF_SOURCE == native && $TEST_FZF_INIT_COUNT == 1 ]] || exit 32
    [[ "$(bindkey -M emacs "^[^F")" == *fzf-file-widget ]] || exit 33
    source "$MY_CONFIGS_SMOKE_RC" || exit 34
    [[ $TEST_FZF_INIT_COUNT == 1 ]] || exit 35
  '

printf 'Portable zsh configuration smoke checks passed.\n'
