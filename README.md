Настройка рабочего места:

```bash
git clone git@github.com:AndreyZa/my-configs.git
bash my-configs/setup.sh
```

Скрипт ставит zsh, kubecolor (нужен алиасам плагина zsh-kubecolor),
oh-my-zsh + powerlevel10k + кастомные плагины (terragrunt, zsh-kubecolor),
кладёт `.zshrc` и переключает шелл по умолчанию на zsh.

После установки вручную:
- установить шрифты: https://github.com/romkatv/powerlevel10k#manual-font-installation
- в новом терминале: `p10k configure`
