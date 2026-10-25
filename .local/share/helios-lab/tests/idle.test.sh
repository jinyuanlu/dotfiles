#!/bin/bash
# shellcheck source-path=SCRIPTDIR
#
# idle.test.sh — U4: the idle auto-stop and keep. Host side
# (host/helios-lab-host): the idle decision table and its pure helpers, one
# idle check run against faked tools, keep, the idle units and the sshd
# drop-in, the install's arming handoff, and the idle lines of the status
# reply. Mac side: keep's duration parser and the keep command, status's
# auto-stop field, idle detail and anomalies, the ready screen with a keep in
# force, and the billing notice once a push has armed the idle timer.
#
# Mac scenarios run the real entry against the aws, curl and ssh stubs, with
# host replies hand-written in the grammar the helper writes (tests/lib.sh
# idle_status_reply); the contract test proves the helper writes exactly
# that. The helper is sourced, never executed (host_env), with its paths in
# the sandbox and every tool it would run on the host (ss, systemctl,
# timeout, date, sshd) a recording function (fake_idle_tools), so nothing
# here powers anything off. The helper and the entry are never loaded into
# the same shell.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --- Fixtures ----------------------------------------------------------------
readonly RUNNING=$DERIVED/describe-instances.running.discover.txt
readonly STOPPED_IDLE=$DERIVED/describe-instances.stopped-idle.discover.txt
readonly RULES_CONVERGED=$DERIVED/describe-security-group-rules.converged.rules.txt
readonly INGRESS=$DERIVED/describe-security-group-rules.converged.ingress.txt
readonly KEYSCAN=$FIXTURES/ssh-keyscan.ed25519.txt
readonly HELPER=$HELIOS_LAB_HOME/host/helios-lab-host
readonly HOST_DIR=$HELIOS_LAB_HOME/host

readonly LAB_ID=i-0123456789abcdef0
readonly HOST_IP=203.0.113.10          # the fixtures' (sanitized) public IP
readonly OTHER_IP=198.51.100.7         # another Mac (documentation range)
readonly HELPER_PATH=/usr/local/libexec/helios-lab/helios-lab-host
readonly NOW=1792839100                # the host clock in host-side tests
readonly DEADMAN_UTC=12:51             # RUNNING's launch (10:50:39Z) + 2h, to the minute
readonly SS_ARGS="ss -Htn state established ( sport = :22 )"

# --- Mac scenario builders ---------------------------------------------------
# world_running — one running lab instance with the test key, a converged
# group, this Mac at the allowed IP, its key pinned, and a host and guest
# that come up cleanly (tests/lib.sh world_host_ok)
world_running() {
  lab_key
  tagged < "$RUNNING" | reply ec2-describe-instances
  reply ec2-describe-security-group-rules "$RULES_CONVERGED"
  reply ec2-wait < /dev/null
  caller_ip_is "$HOST_IP"
  world_host_ok
  pinned
}

# world_status <idle kind> — what status finds for a running host this Mac
# may reach, whose key is pinned, with a verified guest and those idle facts
world_status() {
  reply ec2-describe-instances "$RUNNING"
  reply ec2-describe-security-group-rules "$INGRESS"
  caller_ip_is "$HOST_IP"
  pinned
  guest_status_reply verified unchanged "$1" | ssh_reply ssh-host-status
}

pinned() {
  mkdir -p "$HELIOS_LAB_STATE_DIR"
  echo "$LAB_ID $(awk 'NR == 2 { print $2, $3 }' "$KEYSCAN")" >> "$HELIOS_LAB_STATE_DIR/known_hosts"
}

# again — the next command against the same world: AWS replies restart their
# sequence, the log starts empty
again() { rm -rf "$STUB_AWS_DIR/.calls"; : > "$STUB_LOG"; }

calls() { cat "$STUB_LOG"; }
ssh_calls() { grep '^ssh ' "$STUB_LOG" || true; }
cfg() { echo "$HELIOS_LAB_STATE_DIR/ssh_config"; }
hhmm_utc() { date -u -r "$1" +%H:%M 2>/dev/null || date -u -d "@$1" +%H:%M; }

# replied <key> [field] — a field of the status reply the stub serves (the
# epochs in it are relative to when it was built, so tests read them back
# rather than ask the clock again across a minute boundary)
replied() { awk -v k="$1" -v f="${2:-2}" '$1 == k { print $f; exit }' "$STUB_SSH_DIR/ssh-host-status"; }

# unpack_push <n> <dir> — what the nth push would write on the host
unpack_push() { mkdir -p "$2"; (cd "$2" && /bin/bash -s) < "$STUB_SSH_DIR/.stdin/ssh-host-bash.$1"; }

# --- Host environment --------------------------------------------------------
# host_env — the helper, sourced, with its root in the sandbox
host_env() {
  export HELIOS_LAB_HOST_ROOT=$SANDBOX/root
  # shellcheck source=../host/helios-lab-host
  source "$HELPER"
  require_root() { :; }
}

# host_conf <idle-minutes> — the host.conf a push leaves
host_conf() {
  mkdir -p "$SANDBOX/root/etc/helios-lab"
  printf '# rendered\nIDLE_MINUTES=%s\nENGVM_PIN=%s\n' "$1" "$LAB_PIN" > "$SANDBOX/root/etc/helios-lab/host.conf"
}

# record <text> — the last check's record, as /run holds it
record() { mkdir -p "$SANDBOX/root/run/helios-lab"; printf '%s\n' "$1" > "$SANDBOX/root/run/helios-lab/idle"; }
recorded() { cat "$SANDBOX/root/run/helios-lab/idle"; }

# uptime_is <seconds> — /proc/uptime, in its own format
uptime_is() { mkdir -p "$SANDBOX/root/proc"; printf '%s.42 %s.17\n' "$1" $(( $1 * 3 )) > "$SANDBOX/root/proc/uptime"; }

tools_log() { cat "$SANDBOX/tools.log" 2>/dev/null || true; }

# fake_idle_tools — after host_env: the tools an idle check, keep, status and
# install run, as functions that record their arguments and answer from
# FAKE_* settings: FAKE_NOW (the clock), FAKE_SESSIONS (established ones on
# :22), FAKE_SS=fail, FAKE_SHOW=fail, FAKE_PROVISION and FAKE_ENTER_US (the
# provision unit), FAKE_IDLE_TIMER, FAKE_IDLE_RESULT, FAKE_DEADMAN,
# FAKE_POWEROFF=fail, FAKE_ARM=fail, FAKE_SSHD=fail
# shellcheck disable=SC2329  # the fakes are called by the helper
fake_idle_tools() {
  tool() { echo "$*" >> "$SANDBOX/tools.log"; }
  timeout() { tool timeout "$1"; shift; "$@"; }
  date() { echo "${FAKE_NOW:-$NOW}"; }
  sshd() { tool sshd "$@"; [[ ${FAKE_SSHD:-ok} == ok ]] || { echo '/etc/ssh/sshd_config.d/10-helios-lab.conf line 3: Bad configuration option: Bogus' >&2; return 255; }; }
  ss() {
    local n
    tool ss "$@"
    [[ ${FAKE_SS:-ok} == ok ]] || return 1
    for (( n = 1; n <= ${FAKE_SESSIONS:-0}; n++ )); do echo "ESTAB 0 0 172.31.0.10:22 $HOST_IP:5100$n"; done
  }
  systemctl() {
    tool systemctl "$@"
    case $1 in
      show)             fake_show "$@" ;;
      poweroff)         [[ ${FAKE_POWEROFF:-ok} == ok ]] ;;
      enable|is-active) [[ ${FAKE_ARM:-ok} == ok ]] ;;
      *)                return 0 ;;
    esac
  }
}

# shellcheck disable=SC2329  # called by the systemctl fake
fake_show() {
  [[ ${FAKE_SHOW:-ok} == ok ]] || return 1
  case $2:$3:$4:$5 in
    -p:ActiveState:-p:Result) fake_show_blocks "${@:6}" ;;   # status's, every unit at once
    *) printf 'ActiveState=%s\nActiveEnterTimestampMonotonic=%s\n' "${FAKE_PROVISION:-inactive}" "${FAKE_ENTER_US:-0}" ;;
  esac
}

# fake_show_blocks <unit>... — one KEY=value block per unit, one blank line apart
# shellcheck disable=SC2329  # called by fake_show
fake_show_blocks() {
  local unit sep='' state result
  for unit in "$@"; do
    state=inactive result=success
    case $unit in
      helios-lab-idle.timer)    state=${FAKE_IDLE_TIMER:-active} ;;
      helios-lab-idle.service)  result=${FAKE_IDLE_RESULT:-success} ;;
      helios-lab-deadman.timer) state=${FAKE_DEADMAN:-inactive} ;;
    esac
    printf '%sActiveState=%s\nResult=%s\n' "$sep" "$state" "$result"
    sep=$'\n'
  done
}

# idle_run — one idle check as the timer runs it, in a subshell (it turns
# errexit off for itself); sets RC and JOURNAL (its stdout and stderr)
idle_run() {
  RC=0
  JOURNAL=$( (cmd_idle_check) 2>&1 ) || RC=$?
}

# decide <provision> <age> <inhibit> <sessions> <count> <required> -> the
# pure decision at NOW
decide() { idle_decision "$1" "$2" "$NOW" "$3" "$4" "$5" "$6"; }

# --- Host: the decision table (pure) -----------------------------------------
test_a_provision_run_active_for_30_min_resets() {
  host_env
  assert_eq reset "$(decide active 1800 none 0 11 12)" 'idle for 55 min, but provisioning'
  assert_eq reset "$(decide active 1800 none 0 0 12)"
  assert_eq reset "$(decide active 7199 none 0 11 12)" 'just under 2h'
}

test_a_provision_run_active_for_2h05m_is_evaluated_normally() {
  host_env
  assert_eq poweroff "$(decide active 7500 none 0 11 12)" 'hung for 2h05m: the host can stop'
  assert_eq increment "$(decide active 7500 none 0 3 12)"
  assert_eq reset "$(decide active 7500 none 1 11 12)" 'a session still holds it'
  assert_eq increment "$(decide active 7200 none 0 3 12)" 'exactly 2h no longer defers'
}

test_a_failed_provision_unit_is_evaluated_normally() {
  host_env
  local state
  for state in failed inactive activating deactivating; do
    assert_eq poweroff "$(decide "$state" - none 0 11 12)" "$state"
    assert_eq increment "$(decide "$state" - none 0 3 12)" "$state"
  done
}

test_a_keep_in_the_future_resets_and_one_in_the_past_is_evaluated_normally() {
  host_env
  assert_eq reset "$(decide inactive - $(( NOW + 3600 )) 0 11 12)" 'kept for another hour'
  assert_eq reset "$(decide inactive - $(( NOW + 43200 )) 0 11 12)" 'kept for the whole 12h'
  assert_eq poweroff "$(decide inactive - $(( NOW - 60 )) 0 11 12)" 'the keep ended a minute ago'
  assert_eq poweroff "$(decide inactive - "$NOW" 0 11 12)" 'the keep ends now'
  assert_eq increment "$(decide inactive - $(( NOW - 60 )) 0 3 12)"
  # Beyond the cap a keep is never trusted: an unusable input, so an idle tick.
  assert_eq increment "$(decide inactive - $(( NOW + 86400 )) 0 3 12)" 'a 24h keep, hand-edited'
}

test_one_or_more_established_sessions_reset() {
  host_env
  assert_eq reset "$(decide inactive - none 1 11 12)"
  assert_eq reset "$(decide failed - none 3 11 12)"
}

test_no_session_no_keep_the_check_that_reaches_the_window_powers_off_and_one_below_counts() {
  host_env
  assert_eq poweroff "$(decide inactive - none 0 11 12)" 'the 12th idle check of 12'
  assert_eq increment "$(decide inactive - none 0 10 12)" 'the 11th: one below'
  assert_eq increment "$(decide inactive - none 0 0 12)" 'the first'
  assert_eq poweroff "$(decide inactive - none 0 0 1)" 'a 5-min window: the first idle check'
  assert_eq poweroff "$(decide inactive - none 0 30 12)" 'past the window (a poweroff that failed)'
  assert_eq 12 "$(idle_next_count poweroff 11)"
  assert_eq 11 "$(idle_next_count increment 10)"
  assert_eq 0 "$(idle_next_count reset 11)"
}

test_an_unreadable_input_counts_as_an_idle_tick_and_repeated_ones_power_off() {
  host_env
  local count=0 n decision
  assert_eq increment "$(decide inactive - none '?' 0 12)" 'the session count could not be read'
  # Fail closed: an error never resets, not even with sessions present.
  assert_eq increment "$(decide '?' - none 2 0 12)" 'the provision unit could not be read'
  assert_eq increment "$(idle_decision inactive - '?' none 2 0 12)" 'the clock'
  assert_eq increment "$(decide inactive - '?' 2 0 12)" 'the keep deadline could not be read'
  assert_eq increment "$(decide active '?' none 2 0 12)" "the provision run's age"
  assert_eq increment "$(decide inactive - none 2 '?' 12)" 'the idle count: it starts again at 0'
  assert_eq poweroff "$(decide inactive - none 2 11 '?')" 'the idle window: the default 12 checks'
  # Repeated failures reach the window, like idle checks do.
  for (( n = 1; n <= 12; n++ )); do
    decision=$(decide inactive - none '?' "$count" 12)
    count=$(idle_next_count "$decision" "$count")
    [[ $decision != poweroff ]] || break
  done
  assert_eq poweroff "$decision"
  assert_eq 12 "$n" 'powered off at the 12th failing check, not before'
}

test_idle_problems_name_each_input_it_cannot_use() {
  host_env
  assert_eq '' "$(idle_problems inactive - "$NOW" none 0 3 12)" 'all usable'
  assert_eq '' "$(idle_problems active 1800 "$NOW" $(( NOW + 60 )) 2 0 12)"
  assert_eq 'the ssh sessions' "$(idle_problems inactive - "$NOW" none '?' 3 12)"
  assert_eq 'the provision unit, the keep deadline' "$(idle_problems '?' - "$NOW" garbage 0 3 12)"
  assert_eq "the provision run's age" "$(idle_problems active '?' "$NOW" none 0 3 12)"
  assert_eq 'the clock, the keep deadline' "$(idle_problems inactive - '?' "$NOW" 0 3 12)"
  assert_eq 'the clock' "$(idle_problems inactive - '?' none 0 3 12)" 'no keep needs no clock'
  assert_eq 'the idle count, the idle window' "$(idle_problems inactive - "$NOW" none 0 007 0)"
  assert_eq 'the ssh sessions' "$(idle_problems inactive - "$NOW" none -1 3 12)"
}

test_inhibit_state_trusts_only_a_keep_within_the_cap() {
  host_env
  assert_eq none "$(inhibit_state "$NOW" none)"
  assert_eq none "$(inhibit_state '?' none)"
  assert_eq $(( NOW + 60 )) "$(inhibit_state "$NOW" $(( NOW + 60 )))"
  assert_eq $(( NOW + 43200 + 300 )) "$(inhibit_state "$NOW" $(( NOW + 43200 + 300 )))" 'the cap and one check of slack'
  assert_eq invalid "$(inhibit_state "$NOW" $(( NOW + 43200 + 301 )))"
  assert_eq none "$(inhibit_state "$NOW" "$NOW")" 'it ends at its deadline'
  assert_eq none "$(inhibit_state "$NOW" 1)"
  local bad
  for bad in '?' '' garbage -5 0123 '1 2' $(( NOW + 60 ))x; do
    assert_eq invalid "$(inhibit_state "$NOW" "$bad")" "'$bad'"
  done
  assert_eq invalid "$(inhibit_state '?' $(( NOW + 60 )))" 'a keep needs a clock'
}

test_keep_until_takes_the_deadline_on_the_hosts_clock_and_enforces_the_cap() {
  host_env
  assert_eq $(( NOW + 10800 )) "$(keep_until "$NOW" 10800)"
  assert_eq $(( NOW + 43200 )) "$(keep_until "$NOW" 43200)" '12h'
  assert_eq $(( NOW + 1 )) "$(keep_until "$NOW" 1)"
  local bad
  for bad in 43201 46800 0 -60 '' 1h 060 99999999; do
    if keep_until "$NOW" "$bad" >/dev/null; then fail "a keep of '$bad'"; fi
  done
}

test_the_provision_runs_age_comes_from_the_monotonic_clock() {
  host_env
  assert_eq 1800 "$(active_seconds 8200000000 '10000.42 30000.17')"
  assert_eq 0 "$(active_seconds 10000900000 '10000.42 30000.17')" 'entered this very second'
  if active_seconds 0 '10000.42 30000.17' >/dev/null; then fail 'never entered'; fi
  if active_seconds 20000000000 '10000.42 30000.17' >/dev/null; then fail 'entered in the future'; fi
  if active_seconds 8200000000 '' >/dev/null; then fail 'no uptime'; fi
  if active_seconds x '10000.42 30000.17' >/dev/null; then fail 'garbage'; fi
}

test_the_record_carries_the_count_from_one_check_to_the_next() {
  host_env
  assert_eq "$NOW increment 4 12" "$(idle_record "$NOW" increment 4 12 '')"
  assert_eq "$NOW increment 4 12 could not use the ssh sessions" "$(idle_record "$NOW" increment 4 12 'could not use the ssh sessions')"
  assert_eq 4 "$(idle_record_count "$NOW increment 4 12 could not use the ssh sessions")"
  assert_eq 0 "$(idle_record_count none)" 'a fresh boot'
  assert_eq '?' "$(idle_record_count '?')"
  assert_eq '?' "$(idle_record_count "$NOW increment x 12")"
  assert_eq 12 "$(idle_required $'# rendered\nIDLE_MINUTES=60\nENGVM_PIN=x')"
  assert_eq 1 "$(idle_required 'IDLE_MINUTES=5')"
  assert_eq 144 "$(idle_required 'IDLE_MINUTES=720')"
  assert_eq '?' "$(idle_required 'IDLE_MINUTES=7')"
  assert_eq '?' "$(idle_required '')"
  assert_eq increment "$(idle_escalate increment yes)"
  assert_eq poweroff "$(idle_escalate increment no)" 'a count that cannot be kept'
  assert_eq reset "$(idle_escalate reset no)" 'busy stays busy'
}

# --- Host: one idle check against faked tools --------------------------------
test_an_idle_check_on_an_idle_host_counts_and_records_it() {
  host_env
  fake_idle_tools
  host_conf 60
  idle_run
  assert_eq 0 "$RC" "$JOURNAL"
  assert_eq "$NOW increment 1 12" "$(recorded)" 'a fresh boot: the first idle check'
  assert_contains "$JOURNAL" 'idle-check: provision inactive (age -), keep none, sessions 0, count 0 of 12: increment'
  assert_eq "timeout 10
systemctl show -p ActiveState -p ActiveEnterTimestampMonotonic helios-lab-provision.service
timeout 10
$SS_ARGS" "$(tools_log)" 'every input bounded; nothing acted on'
  idle_run
  assert_eq "$NOW increment 2 12" "$(recorded)" 'the next check reads the count back'
}

test_the_check_that_reaches_the_window_powers_off_and_only_powers_off() {
  host_env
  fake_idle_tools
  host_conf 60
  record "$(( NOW - 300 )) increment 11 12"
  idle_run
  assert_eq 0 "$RC" "$JOURNAL"
  assert_eq "$NOW poweroff 12 12" "$(recorded)"
  assert_eq 'systemctl poweroff' "$(tools_log | grep -v -e '^timeout ' -e '^systemctl show ' -e '^ss ')" 'its only action'
  assert_contains "$JOURNAL" 'powering off (EC2 stops the instance)'
  # Invariant: the idle path only ever stops. The instance's shutdown
  # behaviour is stop (mutations.test.sh checks the launch), and nothing on
  # the host's idle path can terminate it.
  assert_not_contains "$(sed -n '/^cmd_idle_check()/,/^cmd_keep()/p' "$HELPER")" 'terminate'
}

test_a_session_on_22_resets_the_count() {
  host_env
  fake_idle_tools
  host_conf 60
  record "$(( NOW - 300 )) increment 11 12"
  FAKE_SESSIONS=2 idle_run
  assert_eq 0 "$RC"
  assert_eq "$NOW reset 0 12" "$(recorded)"
  assert_contains "$JOURNAL" 'sessions 2, count 11 of 12: reset'
  assert_not_contains "$(tools_log)" 'poweroff'
}

test_an_unreadable_session_count_is_an_idle_tick_and_repeated_ones_power_off() {
  host_env
  fake_idle_tools
  host_conf 60
  local n
  for (( n = 1; n <= 11; n++ )); do
    FAKE_SS=fail FAKE_SESSIONS=3 idle_run
    assert_eq 1 "$RC" "check $n fails, so systemd shows it"
    assert_eq "$NOW increment $n 12 could not use the ssh sessions" "$(recorded)" "check $n"
  done
  assert_not_contains "$(tools_log)" 'poweroff'
  assert_contains "$JOURNAL" 'idle-check: could not use the ssh sessions'
  FAKE_SS=fail FAKE_SESSIONS=3 idle_run
  assert_eq "$NOW poweroff 12 12 could not use the ssh sessions" "$(recorded)"
  assert_contains "$(tools_log)" 'systemctl poweroff'
}

test_systemctl_show_failing_counts_as_idle() {
  host_env
  fake_idle_tools
  host_conf 60
  FAKE_SHOW=fail FAKE_SESSIONS=1 idle_run
  assert_eq 1 "$RC"
  assert_eq "$NOW increment 1 12 could not use the provision unit" "$(recorded)" 'even with a session present'
}

test_a_provision_run_active_for_30_min_holds_the_host_and_one_from_2h05m_ago_does_not() {
  host_env
  fake_idle_tools
  host_conf 60
  uptime_is 10000
  record "$(( NOW - 300 )) increment 11 12"
  FAKE_PROVISION=active FAKE_ENTER_US=$(( (10000 - 1800) * 1000000 )) idle_run
  assert_eq 0 "$RC" "$JOURNAL"
  assert_eq "$NOW reset 0 12" "$(recorded)"
  assert_contains "$JOURNAL" 'provision active (age 1800)'
  record "$(( NOW - 300 )) increment 11 12"
  FAKE_PROVISION=active FAKE_ENTER_US=$(( (10000 - 7500) * 1000000 )) idle_run
  assert_eq "$NOW poweroff 12 12" "$(recorded)"
  rm "$SANDBOX/root/proc/uptime"   # an active run whose age can't be read: fail closed
  FAKE_PROVISION=active FAKE_ENTER_US=$(( (10000 - 1800) * 1000000 )) idle_run
  assert_eq 1 "$RC"
  assert_contains "$(recorded)" "could not use the provision run's age"
}

test_a_bad_host_conf_falls_back_to_the_default_window_and_counts_as_idle() {
  host_env
  fake_idle_tools
  FAKE_SESSIONS=2 idle_run   # no host.conf at all
  assert_eq 1 "$RC"
  assert_eq "$NOW increment 1 12 could not use the idle window" "$(recorded)"
  host_conf 7
  record "$NOW increment 11 12"
  idle_run
  assert_eq "$NOW poweroff 12 12 could not use the idle window" "$(recorded)"
}

test_a_count_that_cannot_be_recorded_powers_off_now() {
  host_env
  fake_idle_tools
  host_conf 60
  mkdir -p "$SANDBOX/root/run/helios-lab/idle.new"   # the atomic write can't happen
  idle_run
  assert_eq 1 "$RC"
  assert_contains "$(tools_log)" 'systemctl poweroff'
  assert_contains "$JOURNAL" 'could not record the idle count, so this check powers off'
  : > "$SANDBOX/tools.log"
  FAKE_SESSIONS=1 idle_run
  assert_not_contains "$(tools_log)" 'poweroff' 'a busy host is never powered off for it'
}

test_a_failed_poweroff_is_recorded_and_the_next_check_tries_again() {
  host_env
  fake_idle_tools
  host_conf 60
  record "$NOW increment 11 12"
  FAKE_POWEROFF=fail idle_run
  assert_eq 1 "$RC"
  assert_eq "$NOW poweroff 12 12 systemctl poweroff failed" "$(recorded)"
  : > "$SANDBOX/tools.log"
  idle_run
  assert_eq 0 "$RC"
  assert_contains "$(tools_log)" 'systemctl poweroff'
  assert_eq "$NOW poweroff 13 12" "$(recorded)"
}

test_keep_writes_a_capped_deadline_on_disk_that_holds_the_host_and_off_clears_it() {
  host_env
  fake_idle_tools
  host_conf 60
  local file=$SANDBOX/root/var/lib/helios-lab/inhibit-until
  assert_eq $(( NOW + 10800 )) "$(cmd_keep 10800)"
  assert_eq $(( NOW + 10800 )) "$(<"$file")" 'on disk: it survives a stop and start'
  record "$NOW increment 11 12"
  idle_run
  assert_eq "$NOW reset 0 12" "$(recorded)" 'kept: no poweroff'
  FAKE_NOW=$(( NOW + 10801 )) idle_run
  assert_eq "$(( NOW + 10801 )) increment 1 12" "$(recorded)" 'after the deadline the window counts again'
  local bad
  for bad in 43201 0 -1 '' 3h forever; do
    RC=0; ( cmd_keep "$bad" ) > /dev/null 2>&1 || RC=$?
    assert_eq 1 "$RC" "keep '$bad'"
  done
  assert_eq $(( NOW + 10800 )) "$(<"$file")" 'a refused keep changes nothing'
  assert_eq off "$(cmd_keep off)"
  [[ ! -e $file ]] || fail 'keep off left the deadline'
  assert_eq off "$(cmd_keep off)" 'clearing twice is fine'
  echo $(( NOW + 86400 )) > "$file"   # beyond the cap, by hand
  idle_run
  assert_eq 1 "$RC"
  assert_eq "$NOW increment 2 12 could not use the keep deadline" "$(recorded)"
}

# --- Host: units, the sshd drop-in, the install's handoff --------------------
test_the_idle_units_check_every_5_min_as_the_mac_counts_down() {
  local service timer mac host
  service=$(grep -vE '^[[:space:]]*#' "$HOST_DIR/helios-lab-idle.service")
  timer=$(grep -vE '^[[:space:]]*#' "$HOST_DIR/helios-lab-idle.timer")
  assert_eq 'Type=oneshot' "$(grep '^Type=' <<< "$service")"
  assert_eq "ExecStart=$HELPER_PATH idle-check" "$(grep '^ExecStart=' <<< "$service")"
  assert_contains "$service" 'TimeoutStartSec='   # a hung check can't hold off every later one
  assert_not_contains "$service" '[Install]'       # the timer starts it
  assert_contains "$timer" $'OnBootSec=5min\nOnUnitActiveSec=5min'
  assert_eq 'Unit=helios-lab-idle.service' "$(grep '^Unit=' <<< "$timer")"
  assert_contains "$timer" $'[Install]\nWantedBy=timers.target'   # armed on every boot once enabled
  # shellcheck disable=SC2153  # IDLE_CHECK_S and KEEP_CAP_S come from lib/state.sh, through load_cli
  mac=$( load_cli; echo "$IDLE_CHECK_S $KEEP_CAP_S" )
  host=$( host_env; echo "$IDLE_TICK_S $KEEP_MAX_S $(install_dest helios-lab-idle.service) $(install_dest helios-lab-idle.timer)" )
  assert_eq "300 43200 $SANDBOX/root/etc/systemd/system/helios-lab-idle.service 0644 $SANDBOX/root/etc/systemd/system/helios-lab-idle.timer 0644" "$host"
  assert_eq "$(cut -d' ' -f1,2 <<< "$host")" "$mac" "the Mac counts down with the host's period and cap"
}

test_the_sshd_drop_in_drops_a_vanished_client_within_3_minutes() {
  assert_eq $'ClientAliveInterval 60\nClientAliveCountMax 3' "$(grep -vE '^[[:space:]]*(#|$)' "$HOST_DIR/sshd-helios-lab.conf")"
  host_env
  # sshd keeps the first value it reads; drop-ins come first, in name order.
  assert_eq "$SANDBOX/root/etc/ssh/sshd_config.d/10-helios-lab.conf 0644" "$(install_dest sshd-helios-lab.conf)"
}

# install_pushed — run a real up, then the install its push would run on the
# host, against recording fakes; the dead-man timer user-data installs is there
install_pushed() {
  world_running
  run_cli up
  assert_rc 0
  STAGE=$SANDBOX/tmp/helios-lab-push.test
  unpack_push 1 "$STAGE"
  host_env
  fake_idle_tools
  mkdir -p "$SANDBOX/root/etc/systemd/system"
  : > "$SANDBOX/root/etc/systemd/system/helios-lab-deadman.timer"
}

test_the_push_arms_the_idle_timer_before_it_disarms_the_dead_man() {
  install_pushed
  local printed
  printed=$(cmd_install "$STAGE")
  [[ $printed =~ ^[0-9]+$ ]] || fail "install printed: $printed"
  assert_eq "systemctl daemon-reload
sshd -t
systemctl try-reload-or-restart ssh.service
systemctl enable --now helios-lab-idle.timer
systemctl is-active --quiet helios-lab-idle.timer
systemctl disable --now helios-lab-deadman.timer" "$(tools_log)"
}

test_when_arming_fails_the_dead_man_is_never_disarmed() {
  install_pushed
  RC=0; ERR=$( (FAKE_ARM=fail cmd_install "$STAGE") 2>&1 >/dev/null ) || RC=$?
  assert_eq 1 "$RC"
  assert_contains "$ERR" 'cannot arm helios-lab-idle.timer: the dead-man timer stays armed, so the host still stops 2h after boot'
  assert_eq 0 "$(tools_log | grep -c 'deadman' || true)" 'no disarm'
  assert_eq 'systemctl enable --now helios-lab-idle.timer' "$(tools_log | tail -1)" 'nothing after the failed enable'
}

test_a_drop_in_sshd_rejects_is_removed_and_the_stop_is_not_handed_over() {
  install_pushed
  RC=0; ERR=$( (FAKE_SSHD=fail cmd_install "$STAGE") 2>&1 >/dev/null ) || RC=$?
  assert_eq 1 "$RC"
  assert_contains "$ERR" 'sshd -t rejects the ssh config, so /etc/ssh/sshd_config.d/10-helios-lab.conf was removed again'
  assert_contains "$ERR" 'Bad configuration option'
  [[ ! -e $SANDBOX/root/etc/ssh/sshd_config.d/10-helios-lab.conf ]] || fail 'the rejected drop-in stayed: sshd would not start at the next boot'
  assert_not_contains "$(tools_log)" 'idle.timer'
  assert_not_contains "$(tools_log)" 'deadman'
}

# A host idle for 55 of its 60 min when up reattaches: its brief sessions
# are unlikely to meet a check, so without the push's restart the next
# check (5 min away at most) would stop it right after up said ready.
test_a_reattaching_up_restarts_the_idle_window_and_its_ready_screen_says_so() {
  local before after
  world_running
  run_cli up
  assert_rc 0
  STAGE=$SANDBOX/tmp/helios-lab-push.test
  unpack_push 1 "$STAGE"
  before=$( host_env; fake_idle_tools; host_conf 60; record "$NOW increment 11 12"; idle_facts "$(unit_show)" )
  after=$( host_env; fake_idle_tools; FAKE_NOW=$(( NOW + 60 ))
           cmd_install "$STAGE" > /dev/null; idle_facts "$(unit_show)" )
  assert_eq "$(( NOW + 60 )) reset 0 12" "$(recorded)" 'the push restarted the window'
  load_cli
  assert_eq 'auto-stops in ~5 min' "$(idle_field "$before" "$NOW" 60)" 'as the host stood before the push'
  assert_eq '  auto-stops after 60 min idle · helios-lab keep 3h to hold it · helios-lab stop when done' \
    "$(ready_screen 30 60 "$(inhibit_of "$after")" "$(idle_field "$after" $(( NOW + 60 )) 60)" | sed -n 3p)" \
    'the full window, right after the reattach'
}

test_the_window_restart_comes_before_the_handoff_and_dies_without_one() {
  install_pushed
  mkdir -p "$SANDBOX/root/run"
  : > "$SANDBOX/root/run/helios-lab"   # a file where its directory belongs: the record can't be written
  RC=0; ERR=$( (cmd_install "$STAGE") 2>&1 >/dev/null ) || RC=$?
  assert_eq 1 "$RC"
  assert_contains "$ERR" 'cannot restart the idle window in /run/helios-lab/idle: the stop was not handed over'
  assert_not_contains "$(tools_log)" 'idle.timer'
  assert_not_contains "$(tools_log)" 'deadman'
}

# The ready screen reads the host's own countdown from a status reply taken
# once the guest is verified: a first boot's wait can span idle checks.
test_the_ready_screen_shows_the_hosts_own_countdown_after_the_guest_wait() {
  world_running
  # calls 1 and 2: up's look before provisioning, then the guest's
  guest_status_reply first-boot 'done' counting | ssh_reply_seq ssh-host-status 3
  run_cli up
  assert_rc 0
  assert_eq '  auto-stops in ~44 min · helios-lab keep 3h to hold it · helios-lab stop when done' \
    "$(tail -2 <<< "$OUT" | head -1)" '3 idle checks of 12 so far, the last a minute ago'
  # A host that can't be asked once more: the reply in hand, and up still succeeds.
  rm -rf "$STUB_SSH_DIR"/{.calls,.stdin} "$STUB_SSH_DIR"/ssh-host-status.3
  again
  ssh_reply_error ssh-host-status.3 255 "ssh: connect to host $HOST_IP port 22: Operation timed out"
  run_cli up
  assert_rc 0
  assert_eq '  auto-stops after 60 min idle · helios-lab keep 3h to hold it · helios-lab stop when done' \
    "$(tail -2 <<< "$OUT" | head -1)"
  assert_eq '' "$ERR"
}

test_up_fails_loudly_when_the_install_cannot_arm_the_idle_timer() {
  world_running
  ssh_reply_error ssh-host-bash 1 'helios-lab-host: cannot arm helios-lab-idle.timer: the dead-man timer stays armed, so the host still stops 2h after boot'
  export TZ=UTC
  run_cli up
  assert_rc 1
  assert_contains "$ERR" 'installing the host code failed on the host (exit 1)'
  assert_contains "$ERR" 'the dead-man timer stays armed'
  assert_contains "$ERR" "it stops itself after 60 min idle (idle timer), or by about $DEADMAN_UTC if no up has pushed to it yet (dead-man timer)"
  assert_eq 0 "$(ssh_calls | grep -c 'systemctl start' || true)" 'no provisioning without a stop handed over'
}

# fresh_host — a host root with nothing written yet (a fresh boot, no keep)
fresh_host() { rm -rf "$SANDBOX/root" "$SANDBOX/tools.log"; }

normalize() { sed -E 's/[0-9]{10}/EPOCH/g'; }

test_the_helpers_idle_lines_are_exactly_what_the_mac_parses() {
  local armed failed kept bare
  armed=$( host_env; fake_idle_tools; host_conf 60
           FAKE_SESSIONS=1 idle_run; idle_facts "$(unit_show)" )
  fresh_host
  failed=$( host_env; fake_idle_tools; host_conf 60; record "$NOW increment 3 12"
            FAKE_SS=fail idle_run; FAKE_IDLE_RESULT=exit-code; idle_facts "$(unit_show)" )
  fresh_host
  kept=$( host_env; fake_idle_tools; host_conf 60
          FAKE_SESSIONS=1 idle_run; cmd_keep 10800 > /dev/null; idle_facts "$(unit_show)" )
  fresh_host
  bare=$( host_env; fake_idle_tools; FAKE_IDLE_TIMER=inactive; idle_facts "$(unit_show)" )
  assert_eq "$(idle_status_reply armed | normalize)" "$(normalize <<< "$armed")" 'armed'
  assert_eq "$(idle_status_reply failed | normalize)" "$(normalize <<< "$failed")" 'a failed check'
  assert_eq "$(idle_status_reply inhibited | normalize)" "$(normalize <<< "$kept")" 'a keep in force'
  assert_eq "$(idle_status_reply bare | normalize)" "$(normalize <<< "$bare")" 'no timer armed, a fresh boot'
  load_cli
  assert_eq idle "$(stops_armed "$armed")"
  assert_eq 'auto-stops after 60 min idle' "$(idle_field "$armed" "$NOW" 60)"
  assert_eq 'could not use the ssh sessions' "$(idle_problem_of "$failed")"
  assert_eq $(( NOW + 10800 )) "$(inhibit_of "$kept")"
  assert_eq none "$(stops_armed "$bare")"
}

test_the_helpers_status_reads_only() {
  local log
  log=$( host_env; fake_idle_tools; host_conf 60; record "$NOW increment 3 12"
         idle_facts "$(unit_show)" > /dev/null; tools_log )
  assert_eq 'systemctl show -p ActiveState -p Result helios-lab-provision.service helios-lab-idle.timer helios-lab-idle.service helios-lab-deadman.timer helios-lab-create.service' \
    "$log" 'one systemctl show, nothing else'
}

# --- Mac: keep ---------------------------------------------------------------
test_keep_accepts_90m_3h_and_12h_and_rejects_the_rest() {
  load_cli
  local spec arg want bad
  for spec in 90m:5400 3h:10800 12h:43200 720m:43200 1m:60 1h:3600; do
    arg=${spec%%:*} want=${spec#*:}
    assert_eq "$want" "$(keep_seconds "$arg")" "keep $arg"
  done
  for bad in 13h 721m forever -1h '' 0h 0m 1d 1.5h ' 3h' '3h ' 3H 3 h 03h 3hh 1h30m 99999m; do
    if keep_seconds "$bad" >/dev/null; then fail "accepted '$bad'"; fi
  done
}

test_keep_refuses_a_bad_duration_with_a_usage_error_before_any_call() {
  local arg
  for arg in 13h forever -1h '' garbage; do
    : > "$STUB_LOG"
    run_cli keep "$arg"
    assert_rc 2
    assert_contains "$ERR" "keep: '$arg' is not a duration from 1m to 12h"
    assert_contains "$ERR" 'helios-lab keep 90m, helios-lab keep 3h, or helios-lab keep off'
    assert_eq '' "$(calls)" "keep '$arg': no call at all"
  done
  run_cli keep
  assert_rc 2
  assert_contains "$ERR" 'keep takes one argument'
  run_cli keep 3h 4h
  assert_rc 2
  assert_eq '' "$(calls)"
}

test_keep_3h_holds_off_the_idle_stop_on_a_running_host() {
  world_running
  export TZ=UTC
  local deadline=$(( $(date +%s) + 10800 ))
  echo "$deadline" | ssh_reply ssh-host-keep
  run_cli keep 3h
  assert_rc 0
  assert_eq "keep · auto-stop inhibited until $(hhmm_utc "$deadline"), then it stops after 60 min idle · helios-lab keep off clears it" "$(tail -1 <<< "$OUT")"
  assert_eq "ssh -F $(cfg) host sudo $HELPER_PATH keep 10800" "$(ssh_calls)"
  assert_contains "$(calls)" 'aws ec2 describe-security-group-rules'   # the ingress refresh, first
  assert_contains "$(calls)" "Tags[?Key=='KeyFingerprint']"            # and the lab key
  assert_eq '' "$ERR"
}

# keep's stdout is its result alone, as ssh's is the command's: what it
# prints while connecting (the ingress rule moving to this Mac's new IP, a
# first host-key pin) goes to stderr, so a script can read the deadline.
test_keep_prints_only_its_result_on_stdout_even_when_it_moves_the_rule_and_pins_the_key() {
  lab_key   # world_running without its pin: this keep verifies the host key
  tagged < "$RUNNING" | reply ec2-describe-instances
  reply ec2-describe-security-group-rules "$RULES_CONVERGED"
  reply ec2-revoke-security-group-ingress "$DERIVED/revoke-security-group-egress.return.txt"   # same shape
  reply ec2-authorize-security-group-ingress "$DERIVED/authorize-security-group-ingress.return.txt"
  caller_ip_is "$OTHER_IP"
  world_host_ok
  export TZ=UTC
  local deadline=$(( $(date +%s) + 10800 ))
  echo "$deadline" | ssh_reply ssh-host-keep
  run_cli keep 3h
  assert_rc 0
  assert_eq "keep · auto-stop inhibited until $(hhmm_utc "$deadline"), then it stops after 60 min idle · helios-lab keep off clears it" "$OUT"
  assert_contains "$ERR" "ssh ingress: $OTHER_IP/32 only (removed tcp/22 $HOST_IP/32)"
  assert_contains "$ERR" "host key · waiting for $LAB_ID's fingerprints on its console"
  assert_contains "$ERR" 'matches the console · pinned'
  assert_contains "$(calls)" 'authorize-security-group-ingress'   # the rule did change
}

test_keep_off_clears_it() {
  world_running
  echo off | ssh_reply ssh-host-keep
  export HELIOS_LAB_IDLE_MINUTES=90
  run_cli keep off
  assert_rc 0
  assert_eq 'keep · cleared · the host auto-stops after 90 min idle' "$OUT"
  assert_eq "ssh -F $(cfg) host sudo $HELPER_PATH keep off" "$(ssh_calls)"
}

test_keep_refuses_a_stopped_host_like_ssh_and_never_reaches_it() {
  lab_key
  reply ec2-describe-instances "$STOPPED_IDLE"
  run_cli keep 3h
  assert_rc 1
  assert_contains "$ERR" "$LAB_ID stopped itself (idle) — run helios-lab up"
  assert_contains "$ERR" 'helios-lab keep never starts the host: it bills while it runs'
  assert_eq '' "$(grep -E '^(ssh|ssh-keyscan) ' "$STUB_LOG" || true)" 'no ssh at all'
  assert_eq describe-instances "$(aws_ops)" 'discovery only'
}

test_keep_against_a_helper_without_keep_says_up_pushes_it() {
  world_running
  ssh_reply_error ssh-host-keep 1 'helios-lab-host: usage: helios-lab-host install <dir> | provision | progress-reset'
  run_cli keep 3h
  assert_rc 1
  assert_contains "$ERR" 'setting the keep failed on the host (exit 1)'
  assert_contains "$ERR" 'a helper older than keep has none: helios-lab up pushes the current one'
  rm "$STUB_SSH_DIR"/ssh-host-keep.*
  echo 'something else' | ssh_reply ssh-host-keep
  again
  run_cli keep 3h
  assert_rc 1
  assert_contains "$ERR" "the host answered 'something else' to keep, neither a deadline nor off"
}

# --- Mac: status -------------------------------------------------------------
test_a_failed_idle_check_shows_above_the_state_line() {
  world_status failed
  run_status
  assert_rc 0
  assert_line 1 "! the last idle check failed (could not use the ssh sessions): it counts what it can't use as idle, so it fails toward a stop; why: helios-lab ssh host journalctl -u helios-lab-idle"
  assert_contains "$(sed -n 2p <<< "$OUT")" 'running · guest ready · up '
  assert_contains "$(sed -n 2p <<< "$OUT")" 'auto-stops in ~'   # its idle tick still counts
}

test_an_idle_check_that_did_not_finish_shows_above_the_state_line() {
  world_status crashed
  run_status
  assert_rc 0
  assert_line 1 '! the last idle check did not finish (systemd: exit-code), so idle time may go uncounted: helios-lab up pushes the current helper; why: helios-lab ssh host journalctl -u helios-lab-idle'
  assert_contains "$(sed -n 2p <<< "$OUT")" 'running · guest ready · up '
}

test_status_counts_down_from_the_hosts_idle_checks() {
  world_status counting
  export TZ=UTC
  run_status
  assert_rc 0
  # 3 of 12 idle checks, the last a minute ago: 9 more, 5 min apart, less that minute.
  assert_contains "$(sed -n 1p <<< "$OUT")" ' · auto-stops in ~44 min'
  assert_contains "$OUT" "  idle      last check $(hhmm_utc "$(replied idle-run)"): idle, 3 of 12 checks"
  assert_not_contains "$OUT" '!'
}

test_status_shows_a_keep_deadline() {
  world_status inhibited
  export TZ=UTC
  run_status
  assert_rc 0
  assert_contains "$(sed -n 1p <<< "$OUT")" " · auto-stop inhibited until $(hhmm_utc "$(replied inhibit)")"
}

test_status_shows_the_window_while_busy_in_the_hosts_own_terms() {
  world_status armed
  run_status
  assert_contains "$(sed -n 1p <<< "$OUT")" ' · auto-stops after 60 min idle'
  assert_contains "$OUT" '  idle      last check '
  assert_contains "$OUT" ': busy (an ssh session, provisioning or a keep)'
  # A host pushed with a 120-min window, read by a Mac whose env says 60.
  guest_status_reply verified unchanged armed | sed -E 's/^(idle-run .* reset 0) 12$/\1 24/' | ssh_reply ssh-host-status
  run_status
  assert_contains "$(sed -n 1p <<< "$OUT")" ' · auto-stops after 120 min idle'
}

test_status_names_the_stop_that_is_armed_when_it_is_not_the_idle_timer() {
  export TZ=UTC
  world_status unarmed
  run_status
  assert_line 1 "! the idle timer is not armed (inactive): the dead-man timer stops the host by about $DEADMAN_UTC; helios-lab up arms the idle timer"
  assert_contains "$(sed -n 2p <<< "$OUT")" " · stops itself by about $DEADMAN_UTC (dead-man timer)"
  assert_contains "$OUT" '  idle      no check yet this boot (one runs every 5 min)'
  guest_status_reply verified unchanged bare | ssh_reply ssh-host-status
  run_status
  assert_line 1 '! no stop is armed (idle timer inactive, dead-man timer inactive): the host bills until helios-lab stop; helios-lab up arms the idle timer'
  assert_contains "$(sed -n 2p <<< "$OUT")" ' · no stop armed'
  guest_status_reply verified unchanged both | ssh_reply ssh-host-status
  run_status
  assert_line 1 "! the dead-man timer is still armed: it stops the host by about $DEADMAN_UTC even while in use; helios-lab up disarms it"
  assert_contains "$(sed -n 2p <<< "$OUT")" ' · auto-stops after 60 min idle'
}

test_status_falls_back_to_the_configured_window_for_a_helper_older_than_u4() {
  world_status legacy
  export HELIOS_LAB_IDLE_MINUTES=45
  run_status
  assert_rc 0
  assert_contains "$(sed -n 1p <<< "$OUT")" ' · auto-stops after 45 min idle'
  assert_contains "$OUT" "  idle      not reported: the host's helper predates the idle check; helios-lab up pushes the current one"
  assert_not_contains "$OUT" '!'
}

test_idle_reply_parsers() {
  load_cli
  local now=1792839100 reply
  assert_eq 44 "$(idle_minutes_left "$now" $(( now - 60 )) 3 12)"
  assert_eq 5 "$(idle_minutes_left "$now" "$now" 11 12)" 'the next check powers off'
  assert_eq 1 "$(idle_minutes_left "$now" $(( now - 900 )) 11 12)" 'a late check: at least a minute'
  assert_eq 5 "$(idle_minutes_left "$now" "$now" 14 12)" 'past the window (a failed poweroff): the next check'
  reply=$'idle active success\nidle-run 1792839040 poweroff 12 12\ninhibit none\ndeadman inactive'
  assert_eq 'stopping itself (idle)' "$(idle_field "$reply" "$now" 60)"
  assert_contains "$(idle_detail "$reply")" ': idle for all 12 checks: powering off'
  reply=$'idle active success\nidle-run garbage\ninhibit invalid\ndeadman inactive'
  assert_eq 'auto-stops after 60 min idle' "$(idle_field "$reply" "$now" 60)" 'an unreadable record: the window'
  assert_eq none "$(inhibit_of "$reply")" 'an invalid keep holds nothing'
  assert_eq '' "$(idle_problem_of "$reply")"
  assert_eq deadman "$(stops_armed $'idle failed exit-code\ndeadman active')"
  assert_eq idle "$(stops_armed 'idle active success')" 'no dead-man line: not armed'
  assert_eq none "$(stops_armed $'idle activating success\ndeadman inactive')" 'only active is armed'
  if stops_armed 'verified no' >/dev/null; then fail 'idle facts in a reply without them'; fi
}

# --- Mac: up's ready screen and billing notice -------------------------------
test_up_ends_with_the_keep_deadline_when_one_is_in_force() {
  world_running
  export TZ=UTC
  guest_status_reply first-boot 'done' inhibited | ssh_reply ssh-host-status
  run_cli up
  assert_rc 0
  assert_eq "  auto-stop inhibited until $(hhmm_utc "$(replied inhibit)"), then it stops after 60 min idle · helios-lab keep off clears it · helios-lab stop when done" \
    "$(tail -2 <<< "$OUT" | head -1)"
  [[ ! -e $HELIOS_LAB_STATE_DIR/lock ]] || fail 'the lock outlived up'
  if compgen -G "$HELIOS_LAB_STATE_DIR/notice.*" > /dev/null; then fail 'the notice file outlived up'; fi
}

test_a_failure_after_the_push_says_the_idle_timer_is_the_stop() {
  world_running
  progress_reply guard-failed | ssh_reply ssh-host-progress
  ssh_reply ssh-host-journal < /dev/null
  run_cli up
  assert_rc 1
  assert_contains "$ERR" 'provision failed at stage guard'
  assert_contains "$ERR" "host $LAB_ID is running and billing"
  assert_contains "$ERR" '  it stops itself after 60 min idle (idle timer)'
  assert_not_contains "$ERR" 'dead-man'   # the push disarmed it
}

test_ctrl_c_after_the_push_names_the_idle_timer_and_leaves_nothing_behind() {
  load_cli
  run_fn pushed_then_interrupted
  assert_rc 130
  assert_not_contains "$OUT" 'not interrupted'
  assert_contains "$ERR" "host $LAB_ID is running and billing (≈\$0.27/hr)"
  assert_contains "$ERR" '  it stops itself after 60 min idle (idle timer)'
  assert_not_contains "$ERR" 'dead-man'   # the push disarmed it
  assert_eq '' "$(cd "$HELIOS_LAB_STATE_DIR" && ls)" 'no notice file, no lock'
}

# pushed_then_interrupted — as up after a fresh launch: the lock, and the
# notice set for the dead-man timer; then the push's notice from a subshell,
# as up_connect sets it; then a later notice that knows only "either", as a
# start after a followed stop sets it, which must not take the idle timer
# back; then SIGINT to this very shell (bash 3.2 has no $BASHPID: an exec'd
# sh's parent is this shell), mid-provisioning
pushed_then_interrupted() {
  lock_acquire
  notice_set "$LAB_ID" m8i.xlarge 1792839039 deadman
  ( notice_set "$LAB_ID" m8i.xlarge 1792839039 idle )
  ( notice_set "$LAB_ID" m8i.xlarge 1792839039 either )
  # shellcheck disable=SC2016  # $PPID is the sh's own
  kill -INT "$(exec sh -c 'echo $PPID')"
  echo 'not interrupted'
}

test_a_failure_before_the_push_on_an_existing_host_names_either_stop() {
  world_running
  export TZ=UTC
  ssh_reply_error ssh-host-bash 255 'ubuntu@203.0.113.10: Permission denied (publickey).'
  run_cli up
  assert_rc 1
  assert_contains "$ERR" "  it stops itself after 60 min idle (idle timer), or by about $DEADMAN_UTC if no up has pushed to it yet (dead-man timer)"
}

# The idle service's ExecStopPost fails closed even when the helper itself
# crashes. Run the unit's own line the way systemd would ($$ -> $), with
# SERVICE_RESULT set and systemctl faked: 11 failures keep the host up, a
# success clears the count, 12 consecutive failures power it off.
test_idle_service_fallback_powers_off_after_12_consecutive_failures() {
  local script dir
  script=$(sed -n "s/^ExecStopPost=\/bin\/sh -c '\(.*\)'\$/\1/p" "$HOST_DIR/helios-lab-idle.service" | sed 's/\$\$/$/g')
  [[ -n $script ]] || fail 'helios-lab-idle.service has no ExecStopPost fallback'
  dir=$SANDBOX/crash
  mkdir -p "$dir/bin"
  printf '#!/bin/sh\necho "$*" >> "%s/systemctl.log"\n' "$dir" > "$dir/bin/systemctl"
  chmod +x "$dir/bin/systemctl"
  script=${script//\/run\/helios-lab/$dir/run}
  for _ in 1 2 3 4 5 6 7 8 9 10 11; do SERVICE_RESULT=exit-code PATH="$dir/bin:$PATH" /bin/sh -c "$script"; done
  assert_eq 11 "$(cat "$dir/run/idle-crashes")"
  assert_eq '' "$(cat "$dir/systemctl.log" 2>/dev/null || true)" 'no poweroff before 12'
  SERVICE_RESULT=success PATH="$dir/bin:$PATH" /bin/sh -c "$script"
  [[ ! -e $dir/run/idle-crashes ]] || fail 'a success must clear the crash count'
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do SERVICE_RESULT=signal PATH="$dir/bin:$PATH" /bin/sh -c "$script"; done
  assert_eq poweroff "$(cat "$dir/systemctl.log")"
}

run_tests
