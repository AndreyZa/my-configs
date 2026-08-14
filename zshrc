if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# export PATH=$HOME/bin:/usr/local/bin:/snap/bin/:$PATH

export ZSH="$HOME/.oh-my-zsh"

HIST_STAMPS="yyyy-mm-dd"

ZSH_THEME="powerlevel10k/powerlevel10k"

plugins=(git
ansible
brew
kubectl
zsh-kubecolor
docker
docker-compose
helm
vault
terragrunt
terraform)

source $ZSH/oh-my-zsh.sh

[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# история в риалтайме: каждая команда сразу в файл и видна другим сессиям
# (oh-my-zsh включает share_history сам, но фиксируем явно)
setopt SHARE_HISTORY

# fzf: Ctrl+R — fuzzy-поиск по истории, Ctrl+T — по файлам, Alt+C — cd
if [ -f /usr/share/doc/fzf/examples/key-bindings.zsh ]; then
    source /usr/share/doc/fzf/examples/key-bindings.zsh
fi

if command -v kubecolor &> /dev/null; then
  compdef kubecolor=kubectl
fi

export EDITOR=nano

alias py="python3"
alias python="python3"
alias pip="pip3"
