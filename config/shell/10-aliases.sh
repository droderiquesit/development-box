# shellcheck shell=bash
# -----------------------------------------------------------------------------
# Aliases. Kept deliberately short — a handful you will actually use every day,
# not three hundred you will spend a year forgetting. Everything destructive is
# left as the real command so it never fires by muscle memory.
# -----------------------------------------------------------------------------

# ------------------------------------------------------------------ git ------
alias g='git'
alias gs='git status --short --branch'
alias gl='git log --oneline --graph --decorate -20'
alias gd='git diff'
alias gp='git push'
alias gco='git checkout'
alias gb='git branch'
alias lg='lazygit'

# ------------------------------------------------------------ terraform ------
alias tf='terraform'
alias tg='terragrunt'
alias tofu='tofu'
alias tf-init='terraform init -input=false'
alias tf-fmt='terraform fmt -recursive'
alias tf-validate='terraform validate'
alias tf-plan='terraform plan -input=false -lock=false'
alias tf-docs='terraform-docs markdown table --output-file README.md --output-mode inject .'
alias tf-security='devbox terraform security'
alias tf-check='devbox terraform check'
# NOTE: there is intentionally no alias for `terraform apply` or `destroy`.

# ----------------------------------------------------------- kubernetes ------
alias k='kubectl'
alias kgp='kubectl get pods'
alias kgn='kubectl get nodes'
alias kgs='kubectl get svc'
alias kctx='kubectx'
alias kns='kubens'
alias h='helm'

# ------------------------------------------------------------------- ai ------
# `ai`, `claude`, `codex`, `gemini` are real executables, not aliases: the
# wrapper adds consistency, it must never hide the native tools.
alias aim='ai models'
alias aip='ai profile'

# ------------------------------------------------------------- general -------
alias ll='ls -alFh --color=auto'
alias la='ls -A --color=auto'
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias ports='ss -tulpn 2>/dev/null || netstat -tulpn'
alias serve='python3 -m http.server'
