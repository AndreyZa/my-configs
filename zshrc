if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

export PATH=$HOME/bin:/usr/local/bin:/snap/bin/:$PATH

export ZSH="$HOME/.oh-my-zsh"

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

export EDITOR=nano

alias py="python3"
alias python="python3"
alias pip="pip3"
