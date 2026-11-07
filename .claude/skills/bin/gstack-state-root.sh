# shellcheck shell=bash
# gstack-state-root.sh — the one bash owner of where gstack keeps its state
# (twin of lib/state-root.ts; test/state-root-parity.test.ts keeps them equal).
# Sourced, never executed: bin/gstack-paths and the careful/freeze hooks source
# it; other executables run `eval "$(<their dir>/gstack-paths)"` plus the
# `: "${GSTACK_STATE_ROOT:?...}"` guard. Chain: GSTACK_STATE_ROOT → GSTACK_HOME →
# GSTACK_STATE_DIR → CLAUDE_PLUGIN_DATA (only when CLAUDE_PLUGIN_ROOT contains
# "gstack") → $HOME/.gstack → .gstack. Bash builtins only (bash 3.2, no
# subprocess): hooks run it on every tool call. Enforced by
# test/state-root-ratchet.test.ts. Generalizes careful/bin/hook-extract.sh's
# former gstack_hook_state_root. Docs: docs/state-root.md.

# _gstack_user_home — HOME, or USERPROFILE on Windows shells when HOME is unset.
_gstack_user_home() {
  _gstack_home_val="${HOME:-}"
  if [ -z "$_gstack_home_val" ]; then
    case "${OSTYPE:-}" in
      msys*|cygwin*|win32*) _gstack_home_val="${USERPROFILE:-}" ;;
    esac
  fi
}

# gstack_state_root_select — sets _gstack_sr_root and _gstack_sr_var (the
# variable that selected it, or "default") without printing.
gstack_state_root_select() {
  _gstack_user_home
  if [ -n "${GSTACK_STATE_ROOT:-}" ]; then
    _gstack_sr_root="$GSTACK_STATE_ROOT"; _gstack_sr_var="GSTACK_STATE_ROOT"
  elif [ -n "${GSTACK_HOME:-}" ]; then
    _gstack_sr_root="$GSTACK_HOME"; _gstack_sr_var="GSTACK_HOME"
  elif [ -n "${GSTACK_STATE_DIR:-}" ]; then
    _gstack_sr_root="$GSTACK_STATE_DIR"; _gstack_sr_var="GSTACK_STATE_DIR"
  else
    _gstack_sr_root=""
    if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
      case "${CLAUDE_PLUGIN_ROOT:-}" in
        *[gG][sS][tT][aA][cC][kK]*) _gstack_sr_root="$CLAUDE_PLUGIN_DATA"; _gstack_sr_var="CLAUDE_PLUGIN_DATA" ;;
      esac
    fi
    if [ -z "$_gstack_sr_root" ]; then
      if [ -n "$_gstack_home_val" ]; then
        _gstack_sr_root="$_gstack_home_val/.gstack"; _gstack_sr_var="default"
      else
        _gstack_sr_root=".gstack"; _gstack_sr_var="default"
      fi
    fi
  fi
}

# gstack_state_root — print the state root WITHOUT a trailing newline. Capture
# with a sentinel so a root ending in a newline round-trips exactly:
#   r="$(gstack_state_root; printf x)"; r="${r%x}"
gstack_state_root() {
  gstack_state_root_select
  printf '%s' "$_gstack_sr_root"
}

# _gstack_config_from_root ROOT KEY — sets _gstack_cfg_one to the value of the
# last `KEY:` line in ROOT/config.yaml, trimmed ("" when absent). Same parse as
# `gstack-config get`.
_gstack_config_from_root() {
  _gstack_cfg_one=""
  [ -f "$1/config.yaml" ] || return 0
  while IFS= read -r _gstack_cfg_line || [ -n "$_gstack_cfg_line" ]; do
    case "$_gstack_cfg_line" in
      "$2":*)
        _gstack_cfg_one="${_gstack_cfg_line#"$2":}"
        _gstack_cfg_one="${_gstack_cfg_one#"${_gstack_cfg_one%%[![:space:]]*}"}"
        _gstack_cfg_one="${_gstack_cfg_one%"${_gstack_cfg_one##*[![:space:]]}"}"
        ;;
    esac
  done < "$1/config.yaml"
}

# _gstack_config_rank KEY VALUE — sets _gstack_cfg_rank: position in the key's
# most-restrictive-first order, -1 for an unrecognized value, "" when KEY is
# not a merged key.
_gstack_config_rank() {
  case "$1" in
    telemetry) case "$2" in off) _gstack_cfg_rank=0 ;; anonymous) _gstack_cfg_rank=1 ;; community) _gstack_cfg_rank=2 ;; *) _gstack_cfg_rank=-1 ;; esac ;;
    memorable_recall) case "$2" in off) _gstack_cfg_rank=0 ;; on) _gstack_cfg_rank=1 ;; *) _gstack_cfg_rank=-1 ;; esac ;;
    codex_reviews) case "$2" in disabled) _gstack_cfg_rank=0 ;; enabled) _gstack_cfg_rank=1 ;; *) _gstack_cfg_rank=-1 ;; esac ;;
    update_check) case "$2" in false) _gstack_cfg_rank=0 ;; true) _gstack_cfg_rank=1 ;; *) _gstack_cfg_rank=-1 ;; esac ;;
    *) _gstack_cfg_rank="" ;;
  esac
}

# gstack_legacy_root_select — sets _gstack_legacy_root to the second candidate
# root merged privacy settings are also read from: $HOME/.gstack
# (GSTACK_TEST_LEGACY_ROOT in tests), or "" when there is none or it is the
# resolved root. Call after gstack_state_root_select.
gstack_legacy_root_select() {
  _gstack_legacy_root=""
  if [ -n "${GSTACK_TEST_LEGACY_ROOT:-}" ]; then
    _gstack_legacy_root="$GSTACK_TEST_LEGACY_ROOT"
  elif [ -n "$_gstack_home_val" ]; then
    _gstack_legacy_root="$_gstack_home_val/.gstack"
  fi
  [ "$_gstack_legacy_root" = "$_gstack_sr_root" ] && _gstack_legacy_root=""
  return 0
}

# gstack_config_select KEY — sets _gstack_cfg_value and _gstack_cfg_root (the
# root that supplied it; both "" when unset). Merged privacy keys (telemetry,
# memorable_recall, codex_reviews, update_check) take the most restrictive
# value across the resolved root and $HOME/.gstack; every other key reads the
# resolved root only. GSTACK_TEST_LEGACY_ROOT replaces $HOME/.gstack in tests.
gstack_config_select() {
  gstack_state_root_select
  _gstack_config_from_root "$_gstack_sr_root" "$1"
  _gstack_cfg_value="$_gstack_cfg_one"; _gstack_cfg_root=""
  [ -n "$_gstack_cfg_value" ] && _gstack_cfg_root="$_gstack_sr_root"
  _gstack_config_rank "$1" "x"
  [ -n "$_gstack_cfg_rank" ] || return 0
  gstack_legacy_root_select
  [ -n "$_gstack_legacy_root" ] || return 0
  _gstack_cfg_legacy="$_gstack_legacy_root"
  _gstack_config_from_root "$_gstack_cfg_legacy" "$1"
  [ -n "$_gstack_cfg_one" ] || return 0
  if [ -z "$_gstack_cfg_value" ]; then
    _gstack_cfg_value="$_gstack_cfg_one"; _gstack_cfg_root="$_gstack_cfg_legacy"
    return 0
  fi
  _gstack_config_rank "$1" "$_gstack_cfg_value"; _gstack_cfg_best="$_gstack_cfg_rank"
  _gstack_config_rank "$1" "$_gstack_cfg_one"
  if [ "$_gstack_cfg_rank" -lt "$_gstack_cfg_best" ]; then
    _gstack_cfg_value="$_gstack_cfg_one"; _gstack_cfg_root="$_gstack_cfg_legacy"
  fi
}

# gstack_read_config_key KEY — print the (merged) value, no trailing newline.
gstack_read_config_key() {
  gstack_config_select "$1"
  printf '%s' "$_gstack_cfg_value"
}
