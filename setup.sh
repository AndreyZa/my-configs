#!/usr/bin/env bash
# Compatible with macOS /bin/bash 3.2.
set -euo pipefail

BOOTSTRAP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bootstrap.sh
source "$BOOTSTRAP_ROOT/lib/bootstrap.sh"

usage() {
  cat <<'HELP'
Usage: bash setup.sh [options]

Install the terminal environment on Ubuntu/Debian or macOS.
  --check               Check prerequisites and installed files; change nothing
  --update              Refresh base OS packages and clean, managed dependency pins
  --replace-config      Replace edited/existing dotfiles after saving a backup
  --skip-packages       Use already installed zsh, git, curl and tar
  --no-fonts            Skip Meslo font installation/checks
  --no-chsh             Leave the login shell unchanged
  --bootstrap-homebrew  Run the official Homebrew installer if brew is missing
  --target-dir DIR      Install user files in DIR (default: current user's home)
                        An alternative target never changes shell/GUI settings
  --devops              Also run the optional scripts/devops.sh profile
  -h, --help            Show this help

Existing customizations are preserved. Conflicting dotfiles are written as
*.my-configs-new; review them or rerun with --replace-config.
On a fresh Mac, install Command Line Tools first: xcode-select --install
HELP
}

MC_TARGET="$HOME"
MC_CHECK=0 MC_UPDATE=0 MC_REPLACE=0 MC_SKIP_PACKAGES=0 MC_NO_FONTS=0 MC_NO_CHSH=0 MC_BOOTSTRAP_BREW=0 MC_DEVOPS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MC_CHECK=1 ;;
    --update) MC_UPDATE=1 ;;
    --replace-config) MC_REPLACE=1 ;;
    --skip-packages) MC_SKIP_PACKAGES=1 ;;
    --no-fonts) MC_NO_FONTS=1 ;;
    --no-chsh) MC_NO_CHSH=1 ;;
    --bootstrap-homebrew) MC_BOOTSTRAP_BREW=1 ;;
    --devops) MC_DEVOPS=1 ;;
    --target-dir)
      [[ $# -ge 2 && -n "$2" ]] || mc_die '--target-dir requires a directory'
      MC_TARGET=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) mc_die "Unknown option: $1" ;;
  esac
  shift
done
case "$MC_TARGET" in /*) ;; *) MC_TARGET="$PWD/$MC_TARGET" ;; esac
MC_TARGET=$(mc_canonical_target "$MC_TARGET")
[[ "$MC_TARGET" != / ]] || mc_die 'Refusing to use / as the user directory'
MC_OS=$(uname -s)
case "$MC_OS" in Linux|Darwin) ;; *) mc_die "Unsupported OS: $MC_OS" ;; esac
if [[ "$MC_OS" == Darwin ]]; then
  if bootstrap_brew=$(mc_find_brew); then eval "$("$bootstrap_brew" shellenv)"; fi
fi
MC_STATE="$MC_TARGET/.local/state/my-configs"
MC_BACKUP_DIR=''
MC_CONFLICTS=0
if [[ "$MC_TARGET" != "$HOME" ]]; then MC_NO_CHSH=1; fi

if (( MC_CHECK )); then
  mc_check_installation
  if (( MC_DEVOPS )); then "$BASH" "$BOOTSTRAP_ROOT/scripts/devops.sh" --check --target-dir "$MC_TARGET"; fi
  exit 0
fi

if (( ! MC_SKIP_PACKAGES )); then mc_install_packages; fi
mc_require_commands git curl zsh tar
mkdir -p "$MC_TARGET" "$MC_STATE/templates"
mc_install_fzf
export PATH="$MC_TARGET/.local/share/my-configs/bin:$PATH"
mc_require_commands fzf
while IFS='|' read -r name relative url ref commit entry; do
  mc_install_repo "$name" "$MC_TARGET/$relative" "$url" "$ref" "$commit" "$entry"
done < <(mc_sources)

if (( ! MC_NO_FONTS )); then
  mc_install_fonts
  mc_configure_terminal_font
fi
mc_install_config "$BOOTSTRAP_ROOT/zshrc" "$MC_TARGET/.zshrc" zshrc
mc_install_config "$BOOTSTRAP_ROOT/p10k.zsh" "$MC_TARGET/.p10k.zsh" p10k.zsh
zsh -n "$MC_TARGET/.zshrc"
zsh -n "$MC_TARGET/.p10k.zsh"
if (( ! MC_NO_CHSH )); then mc_change_shell; fi
if (( MC_DEVOPS )); then
  devops_args=(--target-dir "$MC_TARGET")
  if (( MC_UPDATE )); then devops_args+=(--update); fi
  if (( MC_SKIP_PACKAGES )); then devops_args+=(--skip-packages); fi
  "$BASH" "$BOOTSTRAP_ROOT/scripts/devops.sh" "${devops_args[@]}"
fi
mc_log 'Installation completed. Open a new terminal.'
mc_log 'Local additions belong in ~/.zshrc.local; restyle the prompt with p10k configure.'
if (( MC_CONFLICTS )); then mc_warn 'Existing dotfiles were preserved. Review *.my-configs-new before activation.'; fi
if [[ -n "$MC_BACKUP_DIR" ]]; then mc_log "Backups: $MC_BACKUP_DIR"; fi
if [[ "$MC_OS" == Darwin ]] && (( ! MC_NO_FONTS )); then
  mc_log 'In Terminal/iTerm2 select the installed MesloLGS NF font for your profile.'
fi
