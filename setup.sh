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

# kubecolor: жёсткая зависимость плагина zsh-kubecolor — почти все его
# алиасы (kg, kgp, kaf, ...) зовут kubecolor напрямую и без бинаря биты
install_kubecolor() {
  if command -v kubecolor >/dev/null 2>&1; then
    return
  fi

  case "$OS" in
    Linux)
      if command -v apt >/dev/null 2>&1 \
        && apt-cache policy kubecolor 2>/dev/null | grep -q Candidate; then
        sudo apt install -y kubecolor
      else
        # дистрибутивы без пакета: бинарь из релизов kubecolor/kubecolor
        arch="$(uname -m)"
        case "$arch" in
          x86_64) arch=amd64 ;;
          aarch64) arch=arm64 ;;
        esac
        tag="$(curl -fsSL https://api.github.com/repos/kubecolor/kubecolor/releases/latest \
          | grep -om1 '"tag_name": *"[^"]*"' | grep -o 'v[0-9.]*')"
        curl -fsSL "https://github.com/kubecolor/kubecolor/releases/download/${tag}/kubecolor_${tag#v}_linux_${arch}.tar.gz" \
          | tar xz -C /tmp kubecolor
        sudo install -m0755 /tmp/kubecolor /usr/local/bin/kubecolor
        rm -f /tmp/kubecolor
      fi
      ;;
    Darwin)
      brew install kubecolor
      ;;
  esac
}

install_zsh
install_kubecolor

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

# zshrc берём рядом со скриптом, а не из cwd — иначе запуск не из корня
# репозитория молча копирует не то (или падает)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/zshrc" "$HOME/.zshrc"

# zsh как шелл по умолчанию (раньше приходилось делать руками)
ZSH_BIN="$(command -v zsh)"
if [ "${SHELL:-}" != "$ZSH_BIN" ]; then
  sudo chsh -s "$ZSH_BIN" "$USER" || chsh -s "$ZSH_BIN" \
    || echo "chsh failed — switch manually: chsh -s $ZSH_BIN"
fi

echo "Installation completed. Start a new terminal (or run zsh) and run: p10k configure"
