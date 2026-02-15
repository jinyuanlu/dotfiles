# dotfiles
case "${(L)$(hostname -s)}" in
  *pro*)    export DOTFILES_DIR="/Users/admin/Code/dotfiles" ;;
  *studio*) export DOTFILES_DIR="TODO" ;;  # TODO: update path
esac

# swagger
export PATH=$(go env GOPATH)/bin:$PATH

# nvm
 export NVM_DIR=~/.nvm
 [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
