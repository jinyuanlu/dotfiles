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
readonly COL_STATE=2 COL_LAUNCH=6 COL_REASON=9 COL_TAG=10

# --- Sandbox and runner ------------------------------------------------------
# Every test gets its own HOME, so the fixed lab-key path ~/.ssh/... resolves
# inside the sandbox and no test can read or write the real ~/.ssh. Retries
# don't sleep: tests/stubs/sleep only records.
new_sandbox() {
  SANDBOX=$(mktemp -d "$TEST_TMP/t.XXXXXX")
  export STUB_AWS_DIR=$SANDBOX/aws STUB_CURL_DIR=$SANDBOX/curl STUB_SSH_DIR=$SANDBOX/ssh STUB_LOG=$SANDBOX/calls.log
  export HELIOS_LAB_STATE_DIR=$SANDBOX/state HOME=$SANDBOX/home
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
# none carries a mutating verb (denylist from the plan, as a second net).
# The host is not mutated either: status's only ssh call is the 3-second,
# non-prompting probe of the helper's read-only `status` (U3), and it never
# scans or pins a host key.
readonly STATUS_PROBE_CALL='-o ConnectTimeout=3 -o BatchMode=yes host sudo /usr/local/libexec/helios-lab/helios-lab-host status'
assert_read_only() {
  local op line
  while IFS= read -r op; do
    case $op in
      run-*|start-*|stop-*|terminate-*|create-*|authorize-*|revoke-*|modify-*|delete-*)
        fail "status issued a mutating call: $op" ;;
      describe-*|get-*) ;;
      *) fail "status issued a call outside the read-only allowlist: $op" ;;
    esac
  done < <(aws_ops)
  while IFS= read -r line; do
    [[ -z $line || $line == "ssh -F $HELIOS_LAB_STATE_DIR/ssh_config $STATUS_PROBE_CALL" ]] \
      || fail "status issued an ssh call outside its read-only probe: $line"
  done <<< "$(grep '^ssh' "$STUB_LOG" || true)"
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

# tagged — discovery rows on stdin, carrying the test lab key's
# KeyFingerprint tag (the captures have none: their column is None)
tagged() { set_field "$COL_TAG" "$(lab_fp)"; }

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

# world_host_ok — a running host that verifies, provisions and boots its
# guest cleanly: the console shows the first-boot blocks, the host offers the
# captured key (they match: both are from the spike's host), the push and the
# unit start succeed, the first progress poll shows a finished run, the host
# sees the new guest answer on tcp/22, and the guest passes the smoke check
world_host_ok() {
  reply ec2-get-console-output "$FIXTURES/get-console-output.latest.first-boot.txt"
  ssh_reply ssh-keyscan "$FIXTURES/ssh-keyscan.ed25519.txt"
  echo "$PUSH_EPOCH" | ssh_reply ssh-host-bash   # what helios-lab-host install prints last
  ssh_reply ssh-host-systemctl < /dev/null
  progress_reply 'done' | ssh_reply ssh-host-progress
  guest_status_reply first-boot | ssh_reply ssh-host-status
  guest_smoke_ok
  ssh_reply ssh-host-guest-verified < /dev/null
}

# guest_smoke_ok — the guest answers both smoke checks as the spike's did.
# Hand-written (no capture): uname -o's one word, and what dtrace prints for
# a BEGIN probe that exits (its "matched 1 probe" line is stderr's, which
# the smoke command joins in).
readonly DTRACE_BEGIN_OUT="dtrace: description 'BEGIN ' matched 1 probe
CPU     ID                    FUNCTION:NAME
  0      1                           :BEGIN"
guest_smoke_ok() { smoke_reply illumos 0 "$DTRACE_BEGIN_OUT" 0 | ssh_reply ssh-guest-uname; }

# smoke_reply <uname output> <its exit status> [<dtrace output> <its exit
# status>] -> what the guest prints for the smoke command, lib/remote.sh
# SMOKE_COMMAND (the stub names its reply ssh-guest-uname, for the command's
# first word): each check's output, then its marker line
smoke_reply() {
  printf '%s\n' "$1" "helios-lab-smoke uname $2"
  (( $# < 4 )) || printf '%s\n' "$3" "helios-lab-smoke dtrace $4"
}

# progress_reply <done|unchanged|packages-running|libvirt-running|guard-failed|died|seed-timeout> [run-epoch]
# -> a `helios-lab-host progress` reply for a run that began at run-epoch
# (default: just after the push). Hand-written in the protocol's grammar
# (lib/remote.sh), because the protocol is ours; remote.test.sh and
# guest.test.sh check that the helper itself writes exactly this grammar.
readonly PUSH_EPOCH=1792839095 RUN_EPOCH=1792839100
readonly SEED_TIMEOUT_REASON='seed download timed out after 20 min (download.sh retries forever; pkg.oxide.computer may be slow or unreachable): helios-lab up resumes it'
progress_reply() {
  local t=${2:-$RUN_EPOCH}
  case $1 in
    done)             progress_until guest "$t"; echo "$(( t + 429 )) provision done"; echo 'unit inactive success' ;;
    unchanged)        printf '%s\n' "$t provision start" "$t packages skip" "$t libvirt skip" "$t guard skip" \
                        "$t engvm skip" "$t seed skip" "$t guest start" "$t guest done verified guest running" \
                        "$t provision done" 'unit inactive success' ;;
    packages-running) printf '%s\n' "$t provision start" "$t packages start" 'unit active running' ;;
    libvirt-running)  progress_until packages "$t"; echo "$(( t + 41 )) libvirt start"; echo 'unit active running' ;;
    guard-failed)     progress_until libvirt "$t"; printf '%s\n' "$(( t + 44 )) guard start" \
                        "$(( t + 46 )) guard fail loading /etc/helios-lab/guard.nft failed (nft -f): see the journal" \
                        "$(( t + 46 )) provision fail guard" 'unit inactive success' ;;
    died)             progress_until packages "$t"; echo "$(( t + 41 )) libvirt start"; echo 'unit failed signal' ;;
    seed-timeout)     progress_until engvm "$t"; printf '%s\n' "$(( t + 53 )) seed start" \
                        "$(( t + 1253 )) seed fail $SEED_TIMEOUT_REASON" "$(( t + 1253 )) provision fail seed" \
                        'unit inactive success' ;;
  esac
}

# progress_until <packages|libvirt|guard|engvm|seed|guest> <run-epoch> — the
# progress lines of a clean first run up to and including that stage's done
# line (the timings are the spike's)
progress_until() {
  local t=$2
  printf '%s\n' "$t provision start" "$t packages start" "$(( t + 41 )) packages done 8 packages installed"
  [[ $1 != packages ]] || return 0
  printf '%s\n' "$(( t + 41 )) libvirt start" "$(( t + 44 )) libvirt done kvm ok, default network active"
  [[ $1 != libvirt ]] || return 0
  printf '%s\n' "$(( t + 44 )) guard start" "$(( t + 44 )) guard done virbr0 to 169.254.0.0/16 dropped"
  [[ $1 != guard ]] || return 0
  printf '%s\n' "$(( t + 44 )) engvm start" "$(( t + 53 )) engvm done @8ef18ef · lab: $LAB_SIZING"
  [[ $1 != engvm ]] || return 0
  printf '%s\n' "$(( t + 53 )) seed start" "$(( t + 364 )) seed done verified against engvm's pinned checksums"
  [[ $1 != seed ]] || return 0
  printf '%s\n' "$(( t + 364 )) guest start" "$(( t + 429 )) guest done created · first boot under way"
}

# idle_status_reply [kind] -> the idle lines of a `helios-lab-host status`
# reply (U4). Hand-written in the grammar host/helios-lab-host idle_facts
# writes (idle.test.sh checks the helper writes exactly this). Epochs are
# relative to now, because status counts down from the real clock. Kinds:
#   armed      the idle timer armed, its last check found the host busy (default)
#   counting   3 idle checks of 12 so far, the last a minute ago
#   inhibited  a keep in force for 3 more hours
#   failed     the last check could not read the ssh sessions (so it counted as idle)
#   crashed    systemd says the last check failed; its record is an older, clean one
#   unarmed    the idle timer not armed, the dead-man timer still armed
#   bare       neither timer armed
#   both       both timers armed
#   legacy     nothing at all: a helper older than U4
idle_status_reply() {
  local now idle='active success' run deadman=inactive inhibit=none
  now=$(date +%s)
  run="$(( now - 60 )) reset 0 12"
  case ${1:-armed} in
    armed)     ;;
    counting)  run="$(( now - 60 )) increment 3 12" ;;
    inhibited) inhibit=$(( now + 10800 )) ;;
    failed)    idle='active exit-code' run="$(( now - 60 )) increment 4 12 could not use the ssh sessions" ;;
    crashed)   idle='active exit-code' ;;
    unarmed)   idle='inactive success' deadman=active run=none ;;
    bare)      idle='inactive success' run=none ;;
    both)      deadman=active ;;
    legacy)    return 0 ;;
  esac
  printf '%s\n' "idle $idle" "idle-run $run" "inhibit $inhibit" "deadman $deadman"
}

# guest_status_reply <kind> [progress kind] [idle kind] -> a `helios-lab-host
# status` reply: the progress (progress_reply, 'done' by default), the idle
# lines (idle_status_reply, 'armed' by default), then the guest lines.
# Hand-written in the grammar host/helios-lab-host cmd_status writes
# (guest.test.sh checks the helper writes exactly this); the console lines
# are the end of the spike's first-boot transcript. Kinds:
#   first-boot        unverified, its create unit running, answering on tcp/22
#   booting           unverified, no DHCP lease yet
#   verified          verified and running, answering
#   verified-booting  verified and running, no lease yet (a restart)
#   other-sizing      verified, but the pushed sizing is not what it was built with
#   not-built         no guest at all
#   shut-off          unverified, its domain shut off, no create unit
readonly LAB_PIN=8ef18ef53d3baa03eebe5f2238a3a4ceef1b6f4a LAB_SIZING='3 vCPU, 8 GiB, 60G'
readonly GUEST_IP=192.168.122.45   # libvirt's default NAT range
guest_status_reply() {
  local verified=no pushed="$LAB_PIN $LAB_SIZING" domain=running create=active lease=$GUEST_IP sshd=open
  local console=$'INFO ok, run complete\nHostname: helios' line
  case $1 in
    first-boot)       ;;
    booting)          lease=none sshd=closed console='Loading smf(7) service descriptions: 112/112' ;;
    verified)         verified=$pushed create=inactive console='' ;;
    verified-booting) verified=$pushed create=inactive lease=none sshd=closed console='' ;;
    other-sizing)     verified=$pushed pushed="$LAB_PIN 4 vCPU, 8 GiB, 60G" create=inactive console='' ;;
    not-built)        domain=absent create=inactive lease=none sshd=closed console='' ;;
    shut-off)         domain='shut off' create=inactive lease=none sshd=closed ;;
  esac
  progress_reply "${2:-done}"
  idle_status_reply "${3:-armed}"
  printf '%s\n' "verified $verified" "pushed $pushed" "domain $domain" "create $create" "lease $lease" "sshd $sshd"
  [[ -n $console ]] || return 0
  while IFS= read -r line; do echo "console $line"; done <<< "$console"
}

# gmt_ago <seconds> -> a manual stop's StateTransitionReason for that long ago
gmt_ago() {
  local t=$(( $(date +%s) - $1 ))
  echo "User initiated ($(date -u -r "$t" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -d "@$t" '+%Y-%m-%d %H:%M:%S') GMT)"
}
