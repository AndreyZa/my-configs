# Powerlevel10k instant prompt must precede code that can print to the terminal.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Add installed tools without probing Homebrew/mise on every shell startup.
# Inherited PATH entries are retained; sourcing this file again adds no duplicates.
typeset -U path PATH
() {
  local candidate prefix
  local -a tool_paths
  candidate="${ZDOTDIR:-$HOME}/.local/share/my-configs/bin"
  [[ ! -d "$candidate" ]] || tool_paths+=("$candidate")
  candidate="${MISE_DATA_DIR:-$HOME/.local/share/mise}/shims"
  [[ ! -d "$candidate" ]] || tool_paths+=("$candidate")

  if [[ "$OSTYPE" == darwin* ]]; then
    for prefix in "${HOMEBREW_PREFIX:-}" /opt/homebrew /usr/local; do
      if [[ -n "$prefix" && -x "$prefix/bin/brew" ]]; then
        export HOMEBREW_PREFIX="$prefix"
        for candidate in "$prefix/bin" "$prefix/sbin"; do
          [[ -d "$candidate" ]] && tool_paths+=("$candidate")
        done
        break
      fi
    done
  fi

  for candidate in "$HOME/.local/bin" "$HOME/bin" "$HOME/go/bin" \
    /usr/local/go/bin /usr/local/bin /snap/bin "$HOME/.pulumi/bin"; do
    [[ -d "$candidate" ]] && tool_paths+=("$candidate")
  done
  path=("${tool_paths[@]}" "${path[@]}")
}

# Defaults precede personal initialization, including Oh My Zsh's history alias.
HIST_STAMPS="yyyy-mm-dd"
HISTFILE="${HISTFILE:-${ZDOTDIR:-$HOME}/.zsh_history}"
HISTSIZE=50000
SAVEHIST=50000
setopt SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS HIST_VERIFY

# Migrated initialization precedes framework/plugin selection. Existing local
# files without this header retain their original, late-only loading behavior.
_my_configs_local_file="${ZDOTDIR:-$HOME}/.zshrc.local"
if [[ -r "$_my_configs_local_file" ]]; then
  if IFS= read -r _my_configs_local_header < "$_my_configs_local_file" \
    && [[ "$_my_configs_local_header" == '# my-configs: phased local configuration v1' ]]; then
    _MY_CONFIGS_LOCAL_PHASE=early
    source "$_my_configs_local_file"
    unset _MY_CONFIGS_LOCAL_PHASE
  fi
  unset _my_configs_local_header
fi

export ZSH="${ZSH:-${ZDOTDIR:-$HOME}/.oh-my-zsh}"
export ZSH_CUSTOM="${ZSH_CUSTOM:-$ZSH/custom}"
# The installer updates its own pinned checkout via setup.sh --update. Leave
# independently installed Oh My Zsh checkouts on their existing update policy.
if [[ -f "$ZSH/.git/my-configs-owner" ]]; then
  zstyle ':omz:update' mode disabled
fi
if (( ! ${+ZSH_THEME} )); then
  if [[ -r "$ZSH_CUSTOM/themes/powerlevel10k/powerlevel10k.zsh-theme" ]]; then
    ZSH_THEME="powerlevel10k/powerlevel10k"
  else
    ZSH_THEME=""
    PROMPT='%n@%m %~ %# '
  fi
fi

# Optional command-line tools are installed separately. A base terminal should
# never load a missing plugin or advertise aliases for an absent tool.
if (( ! ${+plugins} )); then
  plugins=()
  () {
  local plugin
  local -a available_plugins
  (( $+commands[git] )) && available_plugins+=(git)
  (( $+commands[ansible] )) && available_plugins+=(ansible)
  if (( $+commands[kubectl] )); then
    available_plugins+=(kubectl)
    (( $+commands[kubecolor] )) && available_plugins+=(zsh-kubecolor)
  fi
  (( $+commands[docker] )) && available_plugins+=(docker)
  (( $+commands[docker] || $+commands[docker-compose] )) && available_plugins+=(docker-compose)
  (( $+commands[helm] )) && available_plugins+=(helm)
  (( $+commands[vault] )) && available_plugins+=(vault)
  (( $+commands[terraform] )) && available_plugins+=(terraform)
  [[ "$OSTYPE" == darwin* ]] && (( $+commands[brew] )) && available_plugins+=(brew)

  for plugin in "${available_plugins[@]}"; do
    if [[ -r "$ZSH_CUSTOM/plugins/$plugin/$plugin.plugin.zsh" \
       || -r "$ZSH_CUSTOM/plugins/$plugin/_$plugin" \
       || -r "$ZSH/plugins/$plugin/$plugin.plugin.zsh" \
       || -r "$ZSH/plugins/$plugin/_$plugin" ]]; then
      plugins+=("$plugin")
    fi
  done
  }
fi

[[ ! -r "$ZSH/oh-my-zsh.sh" ]] || source "$ZSH/oh-my-zsh.sh"
[[ ! -r "${ZDOTDIR:-$HOME}/.p10k.zsh" ]] || source "${ZDOTDIR:-$HOME}/.p10k.zsh"

# Prefer the integration shipped by the executable itself: minimal Ubuntu images
# can omit package docs, and a newer binary must not load an older package script.
# Older, independently installed fzf versions fall back to known script locations.
if (( $+commands[fzf] && ! $+functions[fzf-file-widget] )); then
  () {
    local script init_code
    local -a scripts
    if init_code="$(fzf --zsh 2>/dev/null)" && [[ -n "$init_code" ]]; then
      eval "$init_code"
      return
    fi
    [[ -z ${FZF_BASE:-} ]] || scripts+=("$FZF_BASE/shell/key-bindings.zsh")
    [[ -z ${HOMEBREW_PREFIX:-} ]] || scripts+=("$HOMEBREW_PREFIX/opt/fzf/shell/key-bindings.zsh")
    scripts+=(
      /opt/homebrew/opt/fzf/shell/key-bindings.zsh
      /usr/local/opt/fzf/shell/key-bindings.zsh
      /usr/share/doc/fzf/examples/key-bindings.zsh
      /usr/share/fzf/key-bindings.zsh
      "$HOME/.fzf/shell/key-bindings.zsh"
    )
    for script in "${scripts[@]}"; do
      if [[ -r "$script" ]]; then
        source "$script"
        return
      fi
    done
  }
fi

# Ctrl+T can remain the terminal application's New Tab shortcut.
# Ctrl+Alt+F sends ESC followed by Ctrl+F; Esc, Ctrl+F is an equivalent chord.
if (( $+functions[fzf-file-widget] )); then
  bindkey -M emacs '^[^F' fzf-file-widget
  bindkey -M viins '^[^F' fzf-file-widget
fi

if (( $+commands[kubectl] )); then
  alias k='kubectl'
  if (( $+functions[compdef] )) && [[ -n ${_comps[kubectl]-} ]]; then
    # zsh-kubecolor ships an older Bash completion. Restore the native completion
    # maintained by the kubectl plugin, while retaining its useful color aliases.
    autoload -Uz _kubectl
    compdef _kubectl kubectl
    if (( $+commands[kubecolor] )); then
      compdef _kubectl kubecolor
      alias k='kubecolor'
    fi
  fi
fi

# The old third-party plugin used Terragrunt commands removed in modern releases.
# Keep the useful shortcut without loading obsolete prompt helpers/completions.
(( ! $+commands[terragrunt] )) || alias tg='terragrunt'
if (( $+commands[python3] )); then
  alias py='python3'
  alias python='python3'
fi
(( ! $+commands[pip3] )) || alias pip='pip3'
if [[ -z ${EDITOR:-} ]]; then
  if (( $+commands[nano] )); then
    export EDITOR=nano
  elif (( $+commands[vi] )); then
    export EDITOR=vi
  fi
fi

# Machine-specific paths, aliases, credentials integrations and version managers
# belong here. The installer preserves this file.
[[ ! -r "$_my_configs_local_file" ]] || source "$_my_configs_local_file"
unset _my_configs_local_file

# All custom widgets and bindings must exist before these two plugins are loaded.
# Both plugins are sourced here only, not also included in the OMZ plugins array.
[[ ! -r "$ZSH_CUSTOM/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ]] \
  || source "$ZSH_CUSTOM/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
[[ ! -r "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]] \
  || source "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
