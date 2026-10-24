# shellcheck shell=bash source-path=SCRIPTDIR
#
# tests/lib.sh — shared by every *.test.sh: per-test sandbox, CLI runner,
# assertions and scenario builders. tests/run provides the environment
# (HELIOS_LAB_HOME, HELIOS_LAB_BIN, TEST_TMP, TEST_RESULTS, stubs on PATH).
#
# A test is a function named test_*; run_tests finds them with `declare -F`
# and runs each in its own subshell and sandbox. Assertions exit the subshell
# on failure, so the first broken expectation ends the test.

readonly FIXTURES="$HELIOS_LAB_HOME/tests/fixtures"
# shellcheck disable=SC2034  # used by the *.test.sh files that source this
readonly DERIVED="$FIXTURES/derived"

# Discovery row columns (the row contract in lib/state.sh), for set_field.
# shellcheck disable=SC2034  # used by the *.test.sh files that source this
readonly COL_STATE=2 COL_LAUNCH=6 COL_REASON=9

# --- Sandbox and runner ------------------------------------------------------
new_sandbox() {
  SANDBOX=$(mktemp -d "$TEST_TMP/t.XXXXXX")
  export STUB_AWS_DIR=$SANDBOX/aws STUB_CURL_DIR=$SANDBOX/curl STUB_LOG=$SANDBOX/calls.log
  export HELIOS_LAB_STATE_DIR=$SANDBOX/state
  mkdir -p "$STUB_AWS_DIR" "$STUB_CURL_DIR"
  : > "$STUB_LOG"
}

# run_tests — run every test_* function; report; append "pass fail" to TEST_RESULTS
run_tests() {
  local fn rc pass=0 failed=0 log
  for fn in $(declare -F | awk '$3 ~ /^test_/ { print $3 }'); do
    log=$(mktemp "$TEST_TMP/log.XXXXXX")
    set +e
    ( set -euo pipefail; new_sandbox; "$fn" ) > "$log" 2>&1
    rc=$?
    set -e
    if (( rc == 0 )); then
      pass=$(( pass + 1 )); printf '  ok    %s\n' "${fn#test_}"
    else
      failed=$(( failed + 1 )); printf '  FAIL  %s\n' "${fn#test_}"; sed 's/^/        /' "$log"
    fi
  done
  echo "$pass $failed" >> "$TEST_RESULTS"
}

# load_cli — source the entry (and through it the libs) to call functions directly
load_cli() {
  # shellcheck source=../../../bin/helios-lab
  source "$HELIOS_LAB_BIN"
}

# run_cli <args...> — run the real entry; sets OUT, ERR and RC (never aborts)
run_cli() {
  RC=0
  OUT=$("$HELIOS_LAB_BIN" "$@" 2>"$SANDBOX/stderr") || RC=$?
  ERR=$(<"$SANDBOX/stderr")
}

# run_status — every status scenario goes through here, so every one of them
# checks the invariant that status never mutates anything
run_status() {
  run_cli status
  assert_read_only
}

# --- Assertions --------------------------------------------------------------
fail() { printf '%s\n' "$@" >&2; exit 1; }

assert_eq() { [[ $2 == "$1" ]] || fail "expected: $1" "actual:   $2" ${3:+"($3)"}; }
assert_contains() { [[ $1 == *"$2"* ]] || fail "missing: $2" "in:" "$1"; }
assert_not_contains() { [[ $1 != *"$2"* ]] || fail "unexpected: $2" "in:" "$1"; }
assert_rc() { [[ $RC == "$1" ]] || fail "exit status: expected $1, got $RC" "stdout:" "$OUT" "stderr:" "$ERR"; }

# assert_line <n> <expected> — line n (1-based) of OUT
assert_line() { assert_eq "$2" "$(sed -n "${1}p" <<< "$OUT")" "line $1 of: $OUT"; }

# assert_above <first> <second> — some line containing <first> precedes every
# line containing <second> in OUT
assert_above() {
  local a b
  a=$(grep -nF -- "$1" <<< "$OUT" | head -1 | cut -d: -f1)
  b=$(grep -nF -- "$2" <<< "$OUT" | head -1 | cut -d: -f1)
  if [[ -z $a || -z $b ]] || (( a >= b )); then fail "expected '$1' above '$2' in:" "$OUT"; fi
}

# aws_ops -> the operation of every recorded aws call, one per line
aws_ops() { awk '$1 == "aws" { print $3 }' "$STUB_LOG"; }

# assert_read_only — every recorded AWS operation is a read (allowlist), and
# none carries a mutating verb (denylist from the plan, as a second net)
assert_read_only() {
  local op
  while IFS= read -r op; do
    case $op in
      run-*|start-*|stop-*|terminate-*|create-*|authorize-*|revoke-*|modify-*|delete-*)
        fail "status issued a mutating call: $op" ;;
      describe-*|get-*) ;;
      *) fail "status issued a call outside the read-only allowlist: $op" ;;
    esac
  done < <(aws_ops)
}

# --- Scenario builders -------------------------------------------------------
# reply <name> [file] — the stub's stdout for <name> (from <file>, else stdin)
reply() { if (( $# > 1 )); then cp "$2" "$STUB_AWS_DIR/$1"; else cat > "$STUB_AWS_DIR/$1"; fi; }

# reply_error <name> <exit> <stderr> — a failing call
reply_error() { printf '%s\n' "$3" > "$STUB_AWS_DIR/$1.stderr"; echo "$2" > "$STUB_AWS_DIR/$1.exit"; }

# caller_ip_is <text> — what checkip answers; caller_ip_fails — curl exits 7
caller_ip_is() { printf '%s\n' "$1" > "$STUB_CURL_DIR/curl"; }
caller_ip_fails() { echo 7 > "$STUB_CURL_DIR/curl.exit"; }

# set_field <column> <value> — rewrite one column of tab-separated rows on stdin
set_field() { awk -F'\t' -v OFS='\t' -v col="$1" -v val="$2" '{ $col = val; print }'; }

# iso_ago <seconds> -> the EC2 launch-time text for that long ago (UTC)
iso_ago() {
  local t=$(( $(date +%s) - $1 ))
  date -u -r "$t" +%Y-%m-%dT%H:%M:%S+00:00 2>/dev/null || date -u -d "@$t" +%Y-%m-%dT%H:%M:%S+00:00
}

# gmt_ago <seconds> -> a manual stop's StateTransitionReason for that long ago
gmt_ago() {
  local t=$(( $(date +%s) - $1 ))
  echo "User initiated ($(date -u -r "$t" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -d "@$t" '+%Y-%m-%d %H:%M:%S') GMT)"
}
