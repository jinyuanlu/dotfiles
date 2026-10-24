# shellcheck shell=bash
#
# stub-replay.sh — shared by every stub in tests/stubs/: record one call,
# replay its scripted reply. Kept outside stubs/ so it is not on PATH.
#
# Reply files live in a per-test scenario dir and are named for the call:
#   <name>          stdout, replayed byte for byte (optional)
#   <name>.stderr   stderr (optional)
#   <name>.exit     exit status (optional; default 0)
# Call sequences: the Nth call to <name> uses <name>.N (with <name>.N.stderr,
# <name>.N.exit) when any of those exist, else the unnumbered files. That lets
# a test model state changes (say, stopping on call 1, stopped on call 2).
#
# A call with no reply at all exits 97, so an unexpected call fails loudly
# instead of passing on empty output.

# stub_record <tool> <args...> — one line per call: "<tool> <args joined by spaces>"
stub_record() { printf '%s\n' "$*" >> "${STUB_LOG:?STUB_LOG is not set}"; }

# stub_replay <scenario-dir> <name> — replays and exits with the scripted status
stub_replay() {
  local dir=$1 name=$2 n base
  n=$(stub_next_call "$dir" "$name")
  base=$dir/$name.$n
  stub_has_reply "$base" || base=$dir/$name
  stub_has_reply "$base" || {
    printf 'stub: no reply for %s (call %s) in %s\n' "$name" "$n" "$dir" >&2
    exit 97
  }
  [[ ! -f $base ]] || cat "$base"
  [[ ! -f $base.stderr ]] || cat "$base.stderr" >&2
  exit "$(cat "$base.exit" 2>/dev/null || echo 0)"
}

stub_has_reply() { [[ -f $1 || -f $1.stderr || -f $1.exit ]]; }

# stub_next_call <dir> <name> -> this call's 1-based number for <name>
stub_next_call() {
  local counter=$1/.calls/$2 n
  mkdir -p "$1/.calls"
  n=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$counter"
  echo "$n"
}
