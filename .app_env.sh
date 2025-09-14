# swagger
export PATH=$(go env GOPATH)/bin:$PATH

# nvm
 export NVM_DIR=~/.nvm
 [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

 # pipx
 pipx ensurepath
 sudo pipx ensurepath --global
