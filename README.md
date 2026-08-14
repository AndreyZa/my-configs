Настройка рабочего места:

```bash
git clone git@github.com:AndreyZa/my-configs.git
bash my-configs/setup.sh
```

Скрипт ставит zsh, kubecolor (нужен алиасам плагина zsh-kubecolor),
oh-my-zsh + powerlevel10k + кастомные плагины (terragrunt, zsh-kubecolor),
шрифты MesloLGS NF (и прописывает их в Ptyxis/GNOME Terminal), кладёт
`.zshrc` + `.p10k.zsh` (rainbow-пресет) и переключает шелл по умолчанию
на zsh.

После установки — просто открыть новый терминал. Поменять стиль промпта:
`p10k configure`.
