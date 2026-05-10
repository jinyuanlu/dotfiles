# swagger
export PATH=$(go env GOPATH)/bin:$PATH

# nvm
 export NVM_DIR=~/.nvm
 [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# gbrain: disable dual-pool routing. gbrain v0.31.3 only treats port 6543 as
# a Supabase pooler, so a session-pooler URL on :5432 (Tokyo region default)
# triggers deriveDirectUrl(), which opens admin connections to the IPv6-only
# db.<ref>.supabase.co — ECONNREFUSED. Kill switch routes everything through
# the working pooler URL. See connection-manager.ts:169.
export GBRAIN_DISABLE_DIRECT_POOL=1
