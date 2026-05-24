alias k=kubectl
alias kc=kubectx
alias ee=emacsclient
alias trf=terraform
alias ls='ls --color=auto'
alias claude='claude --dangerously-skip-permissions --mcp-config $HOME/.claude/mcp.json'

# Git/GitHub identity switch — sets local user.email + flips active gh account.
# Run inside the target repo. Requires `gh auth login` for both accounts first.
work() {
  git config user.email lu.j@ctw.inc && git config user.name "Lu Jinyuan"
  gh auth switch -u ljy-ctw 2>/dev/null
  echo "  -> work  ($(git config user.email) | gh: $(gh api user --jq .login 2>/dev/null))"
}
personal() {
  git config user.email t@luke.archi && git config user.name Luke
  gh auth switch -u jinyuanlu 2>/dev/null
  echo "  -> personal  ($(git config user.email) | gh: $(gh api user --jq .login 2>/dev/null))"
}
