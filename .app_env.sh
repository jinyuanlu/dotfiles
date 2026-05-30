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

# investmentOS: route the MCP server to the LIVE IB Gateway (port 4001; paper
# is 4002) and arm live-account operation. These are coupled: connecting to a
# live (U-prefix) account WITHOUT ALLOW_LIVE makes assert_paper_account() raise,
# and the MCP server's lifespan does not catch it — the server fails to start
# entirely. So persisting the port requires persisting the flag.
# ⚠️ This arms LIVE order submission by default in every shell/session. To
# return to the default-closed safety model, comment both lines and switch the
# Gateway back to paper (4002).
export IB_PORT=4001
export INVESTMENTOS_ALLOW_LIVE=1
