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
# Every test gets its own HOME, so the fixed lab-key path ~/.ssh/... resolves
# inside the sandbox and no test can read or write the real ~/.ssh. Retries
# don't sleep.
new_sandbox() {
  SANDBOX=$(mktemp -d "$TEST_TMP/t.XXXXXX")
  export STUB_AWS_DIR=$SANDBOX/aws STUB_CURL_DIR=$SANDBOX/curl STUB_SSH_DIR=$SANDBOX/ssh STUB_LOG=$SANDBOX/calls.log
  export HELIOS_LAB_STATE_DIR=$SANDBOX/state HOME=$SANDBOX/home HELIOS_LAB_RETRY_SECONDS=0
  mkdir -p "$STUB_AWS_DIR" "$STUB_CURL_DIR" "$STUB_SSH_DIR" "$HOME"
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

# run_cli <args...> — run the real entry; sets OUT, ERR and RC (never aborts).
# stdin is /dev/null: no test may ever reach an interactive prompt.
run_cli() {
  RC=0
  OUT=$("$HELIOS_LAB_BIN" "$@" 2>"$SANDBOX/stderr" < /dev/null) || RC=$?
  ERR=$(<"$SANDBOX/stderr")
}

# run_fn <function> [args...] — after load_cli, run one function of the entry
# in a subshell, like run_cli runs the whole entry; sets OUT, ERR and RC. A
# test can redefine an extension point first. errexit must stay on inside, so
# the subshell can't sit in an `||` list (bash ignores -e there).
run_fn() {
  set +e
  ( set -e; "$@" ) > "$SANDBOX/stdout" 2> "$SANDBOX/stderr" < /dev/null
  RC=$?
  set -e
  OUT=$(<"$SANDBOX/stdout")
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

# reply_seq <name> <n> [file] — the reply to the nth call to <name> only
# (stub-replay.sh: <name>.N wins over <name> for call N); an empty stdin
# makes an empty reply
reply_seq() { reply "$1.$2" ${3:+"$3"}; }

# reply_error_seq <name> <n> <exit> <stderr> — the nth call to <name> fails
reply_error_seq() { reply_error "$1.$2" "$3" "$4"; }

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

# --- Lab key -----------------------------------------------------------------
# HOME is the sandbox's, so the fixed lab-key path lives in it. A test key has
# no passphrase, so nothing ever reaches ssh-keygen's prompt.
lab_key_path() { echo "$HOME/.ssh/helios-lab_ed25519"; }

# lab_key — a test lab key at the fixed path
lab_key() {
  mkdir -p "$HOME/.ssh"
  ssh-keygen -q -t ed25519 -N '' -C helios-lab-test -f "$(lab_key_path)"
}
lab_fp() { ssh-keygen -lf "$(lab_key_path).pub" | awk '{ print $2 }'; }

# --- Host scenario builders (U2) ---------------------------------------------
# ssh_reply <name> [file] — the stub ssh's (or ssh-keyscan's) stdout for
# <name>, e.g. ssh-host-progress (naming rule: tests/stubs/ssh)
ssh_reply() { if (( $# > 1 )); then cp "$2" "$STUB_SSH_DIR/$1"; else cat > "$STUB_SSH_DIR/$1"; fi; }

# ssh_reply_seq <name> <n> [file] — the reply to the nth call to <name> only
ssh_reply_seq() { ssh_reply "$1.$2" ${3:+"$3"}; }

# ssh_reply_error <name> <exit> <stderr> — a failing call
ssh_reply_error() { printf '%s\n' "$3" > "$STUB_SSH_DIR/$1.stderr"; echo "$2" > "$STUB_SSH_DIR/$1.exit"; }

# ssh_stdin <name> <n> — what the nth call to <name> read on stdin
ssh_stdin() { cat "$STUB_SSH_DIR/.stdin/$1.$2"; }

# world_host_ok — a running host that verifies and provisions cleanly: the
# console shows the first-boot blocks, the host offers the captured key
# (they match: both are from the spike's host), the push and the unit start
# succeed, and the first progress poll shows a finished run
world_host_ok() {
  reply ec2-get-console-output "$FIXTURES/get-console-output.latest.first-boot.txt"
  ssh_reply ssh-keyscan "$FIXTURES/ssh-keyscan.ed25519.txt"
  echo "$PUSH_EPOCH" | ssh_reply ssh-host-bash   # what helios-lab-host install prints last
  ssh_reply ssh-host-systemctl < /dev/null
  progress_reply 'done' | ssh_reply ssh-host-progress
}

# progress_reply <done|unchanged|packages-running|libvirt-running|guard-failed|died> [run-epoch]
# -> a `helios-lab-host progress` reply for a run that began at run-epoch
# (default: just after the push). Hand-written in the protocol's grammar
# (lib/remote.sh), because the protocol is ours; remote.test.sh checks that
# the helper itself writes exactly this grammar.
readonly PUSH_EPOCH=1792839095 RUN_EPOCH=1792839100
progress_reply() {
  local t=${2:-$RUN_EPOCH}
  case $1 in
    done)             progress_until guard "$t"; echo "$(( t + 44 )) provision done"; echo 'unit inactive success' ;;
    unchanged)        printf '%s\n' "$t provision start" "$t packages skip" "$t libvirt skip" "$t guard skip" \
                        "$t provision done" 'unit inactive success' ;;
    packages-running) printf '%s\n' "$t provision start" "$t packages start" 'unit active running' ;;
    libvirt-running)  progress_until packages "$t"; echo "$(( t + 41 )) libvirt start"; echo 'unit active running' ;;
    guard-failed)     progress_until libvirt "$t"; printf '%s\n' "$(( t + 44 )) guard start" \
                        "$(( t + 46 )) guard fail loading /etc/helios-lab/guard.nft failed (nft -f): see the journal" \
                        "$(( t + 46 )) provision fail guard" 'unit inactive success' ;;
    died)             progress_until packages "$t"; echo "$(( t + 41 )) libvirt start"; echo 'unit failed signal' ;;
  esac
}

# progress_until <packages|libvirt|guard> <run-epoch> — the progress lines of
# a clean run up to and including that stage's done line
progress_until() {
  local t=$2
  printf '%s\n' "$t provision start" "$t packages start" "$(( t + 41 )) packages done 8 packages installed"
  [[ $1 != packages ]] || return 0
  printf '%s\n' "$(( t + 41 )) libvirt start" "$(( t + 44 )) libvirt done kvm ok, default network active"
  [[ $1 != libvirt ]] || return 0
  printf '%s\n' "$(( t + 44 )) guard start" "$(( t + 44 )) guard done virbr0 to 169.254.0.0/16 dropped"
}

# gmt_ago <seconds> -> a manual stop's StateTransitionReason for that long ago
gmt_ago() {
  local t=$(( $(date +%s) - $1 ))
  echo "User initiated ($(date -u -r "$t" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -d "@$t" '+%Y-%m-%d %H:%M:%S') GMT)"
}
