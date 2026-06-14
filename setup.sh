#!/usr/bin/env bash

set -euo pipefail

OS="$(uname -s)"

install_zsh() {
  case "$OS" in
    Linux)
      if command -v apt >/dev/null 2>&1; then
        sudo apt update
        sudo apt install -y zsh git curl
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y zsh git curl
      elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y zsh git curl
      elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm zsh git curl
      else
        echo "Unsupported Linux package manager"
        exit 1
      fi
      ;;
    Darwin)
      if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew is not installed:"
        echo "https://brew.sh"
        exit 1
      fi

      brew install git curl
      # zsh обычно уже есть в macOS
      ;;
    *)
      echo "Unsupported OS: $OS"
      exit 1
      ;;
  esac
}

install_zsh

rm -rf "$HOME/.oh-my-zsh"

RUNZSH=no CHSH=no sh -c \
  "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

# Powerlevel10k
git clone --depth=1 \
  https://github.com/romkatv/powerlevel10k.git \
  "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"

git clone \
  https://github.com/jkavan/terragrunt-oh-my-zsh-plugin \
  "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/terragrunt"

git clone \
  https://github.com/devopstales/zsh-kubecolor.git \
  "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-kubecolor"

cp zshrc "$HOME/.zshrc"

echo "Installation completed."
