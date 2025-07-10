if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

export PATH=$HOME/bin:/usr/local/bin:/snap/bin/:$PATH

export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="powerlevel10k/powerlevel10k"

plugins=(git
ansible
kubectl
docker
docker-compose
helm
terragrunt
terraform)

source $ZSH/oh-my-zsh.sh

[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

export EDITOR=nano

alias py="python3"
alias python="python3"
alias pip="pip3"
alias tg="terragrunt"

# Vagrant
export VAGRANT_WSL_ENABLE_WINDOWS_ACCESS="1"
export VAGRANT_WSL_WINDOWS_ACCESS_USER_HOME_PATH="/mnt/c/Users/Andrey/"
export PATH="$PATH:/mnt/d/Programs/Virtualbox"

# The next line updates PATH for Yandex Cloud CLI.
if [ -f '/home/andrey/yandex-cloud/path.bash.inc' ]; then source '/home/andrey/yandex-cloud/path.bash.inc'; fi

# The next line enables shell command completion for yc.
if [ -f '/home/andrey/yandex-cloud/completion.zsh.inc' ]; then source '/home/andrey/yandex-cloud/completion.zsh.inc'; fi

