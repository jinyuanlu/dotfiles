#!/bin/bash
# shellcheck source-path=SCRIPTDIR
#
# guest.test.sh — U3: the Helios guest. Mac side (lib/remote.sh and the
# entry): the smoke check at the end of up, the guest key, the first-boot and
# restart timeouts, a host that stops itself mid-up, `ssh`, `console`, and
# status's host and guest fields. Host side (host/helios-lab-host): the
# engvm, seed and guest stages and their pure decisions, the status reply,
# guest-verified and guest-abandon.
#
# Mac scenarios run the real entry against the aws, curl and ssh stubs. The
# host's replies are hand-written in the grammar the helper writes
# (tests/lib.sh guest_status_reply, progress_reply); the "contract" tests
# prove the helper writes exactly that. The guest's own output (uname -o,
# dtrace, its console transcript) is hand-written from what the spike
# observed: none of it was captured.
#
# The helper is sourced, never executed (host_env): its paths point into the
# sandbox, and every tool it would run on the host (runuser, git, systemctl,
# systemd-run, virsh, install, timeout, getent) is a recording function
# (fake_host_tools), so nothing here clones, downloads or starts anything.
# The helper and the entry are never loaded into the same shell.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --- Fixtures ----------------------------------------------------------------
readonly RUNNING=$DERIVED/describe-instances.running.discover.txt
readonly STOPPED_IDLE=$DERIVED/describe-instances.stopped-idle.discover.txt
readonly STOPPED_USER=$DERIVED/describe-instances.stopped-user.discover.txt
readonly RULES_CONVERGED=$DERIVED/describe-security-group-rules.converged.rules.txt
readonly INGRESS=$DERIVED/describe-security-group-rules.converged.ingress.txt
readonly STARTING=$DERIVED/start-instances.state.txt
readonly KEYSCAN=$FIXTURES/ssh-keyscan.ed25519.txt
readonly HELPER=$HELIOS_LAB_HOME/host/helios-lab-host
readonly LAB_CONF=$HELIOS_LAB_HOME/host/engvm-lab.sh

readonly LAB_ID=i-0123456789abcdef0
readonly OTHER_ID=i-0fedcba9876543210
readonly HOST_IP=203.0.113.10          # the fixtures' (sanitized) public IP
readonly OTHER_IP=198.51.100.7         # another Mac (documentation range)
readonly PIN=$LAB_PIN
readonly OTHER_PIN=0123456789abcdef0123456789abcdef01234567
readonly HELPER_PATH=/usr/local/libexec/helios-lab/helios-lab-host
readonly SMOKE_DTRACE_CMD="pfexec dtrace -n 'BEGIN { exit(0); }'"
readonly SMOKE_CMD="uname -o 2>&1; echo \"helios-lab-smoke uname \$?\"; $SMOKE_DTRACE_CMD 2>&1; echo \"helios-lab-smoke dtrace \$?\""
readonly ONE_LINER="pfexec dtrace -n 'syscall:::entry { @[execname] = count(); }'"
readonly RFD26_TEXT='meanwhile, read RFD 26: https://rfd.shared.oxide.computer/rfd/0026'
readonly NET_DOWN='ssh: connect to host 203.0.113.10 port 22: Operation timed out'

# --- Scenario builders -------------------------------------------------------
# world_running — one running lab instance with the test key, a converged
# group, this Mac at the allowed IP, and a host and guest that come up
# cleanly (tests/lib.sh world_host_ok)
world_running() {
  lab_key
  tagged < "$RUNNING" | reply ec2-describe-instances
  reply ec2-describe-security-group-rules "$RULES_CONVERGED"
  reply ec2-wait < /dev/null
  caller_ip_is "$HOST_IP"
  world_host_ok
}

# world_status — what status finds for a running host this Mac may reach,
# whose key is pinned; the probe's reply is the test's
world_status() {
  reply ec2-describe-instances "$RUNNING"
  reply ec2-describe-security-group-rules "$INGRESS"
  caller_ip_is "$HOST_IP"
  pinned
}

# again — the next command against the same world: AWS replies restart their
# sequence, the log starts empty
again() { rm -rf "$STUB_AWS_DIR/.calls"; : > "$STUB_LOG"; }

# pinned / pinned_guest — the known_hosts entry a first contact leaves for
# the host (its captured key), and one a reached guest leaves
pinned() {
  mkdir -p "$HELIOS_LAB_STATE_DIR"
  echo "$LAB_ID $(awk 'NR == 2 { print $2, $3 }' "$KEYSCAN")" >> "$HELIOS_LAB_STATE_DIR/known_hosts"
}
pinned_guest() {
  mkdir -p "$HELIOS_LAB_STATE_DIR"
  ssh-keygen -q -t ed25519 -N '' -f "$SANDBOX/guestkey"
  echo "$LAB_ID-guest $(cut -d' ' -f1,2 "$SANDBOX/guestkey.pub")" >> "$HELIOS_LAB_STATE_DIR/known_hosts"
}
known_hosts() { echo "$HELIOS_LAB_STATE_DIR/known_hosts"; }
has_pin() { ssh-keygen -F "$1" -f "$(known_hosts)" >/dev/null 2>&1; }

calls() { cat "$STUB_LOG"; }
ssh_calls() { grep '^ssh ' "$STUB_LOG" || true; }
ssh_count() { ssh_calls | grep -cF -- "$1" || true; }
line_no() { grep -nF -- "$1" "$STUB_LOG" | sed -n "${2:-1}p" | cut -d: -f1; }
cfg() { echo "$HELIOS_LAB_STATE_DIR/ssh_config"; }

# assert_log_order <first> <second> — the first call matching <first> comes
# before the first matching <second>
assert_log_order() {
  local a b
  a=$(line_no "$1"); b=$(line_no "$2")
  if [[ -z $a || -z $b ]] || (( a >= b )); then fail "expected '$1' before '$2' in:" "$(calls)"; fi
}

# steady — elapsed times are the wall clock's against the stubs: normalized
steady() { sed -E -e 's/^(guest ready in )[0-9]+s/\1Ns/' -e 's/^((first|guest) boot · )[0-9]+s · /\1Ns · /'; }

# --- Mac: the smoke check and the end of up ----------------------------------
test_up_marks_the_guest_verified_only_after_both_smoke_checks_then_shows_the_ready_screen() {
  world_running
  export TZ=Asia/Tokyo
  run_cli up
  assert_rc 0
  assert_eq 1 "$(ssh_count "host sudo $HELPER_PATH guest-verified")" 'one guest-verified'
  assert_eq 1 "$(ssh_count "$(cfg) guest $SMOKE_CMD")" 'both checks in one connection'
  assert_log_order "$(cfg) guest $SMOKE_CMD" "host sudo $HELPER_PATH guest-verified"
  assert_log_order "host sudo $HELPER_PATH status" "$(cfg) guest uname -o"   # the host is asked first
  assert_eq "guest ready in Ns · illumos · dtrace ok
  in the guest, try: $ONE_LINER  (Ctrl-C prints system calls by process)
  auto-stops after 60 min idle · helios-lab keep 3h to hold it · helios-lab stop when done
next: helios-lab ssh" "$(tail -4 <<< "$OUT" | steady)"
  assert_contains "$OUT" 'guest · verified · its console is free · it starts with the host from now on'
  assert_eq '' "$ERR"
}

test_a_second_up_with_a_verified_guest_reruns_only_the_push_and_the_smoke_check() {
  world_running
  pinned
  progress_reply unchanged | ssh_reply ssh-host-progress
  guest_status_reply verified unchanged | ssh_reply ssh-host-status
  run_cli up
  assert_rc 0
  assert_eq 0 "$(ssh_count guest-verified)" 'a verified guest is not marked again'
  assert_eq 1 "$(ssh_count "guest $SMOKE_CMD")"
  assert_contains "$OUT" "guest boot · waiting for the guest's smoke check"   # the restart budget
  assert_not_contains "$OUT" 'guest key ·'
  assert_eq 'next: helios-lab ssh' "$(tail -1 <<< "$OUT")"
}

test_a_guest_whose_uname_is_not_illumos_fails_naming_what_it_printed_and_is_not_marked() {
  world_running
  smoke_reply GNU/Linux 0 'bash: pfexec: command not found' 127 | ssh_reply ssh-guest-uname
  run_cli up
  assert_rc 1
  assert_contains "$ERR" "the guest is not Helios: uname -o printed 'GNU/Linux', not illumos"
  assert_contains "$ERR" 'helios-lab ssh host getent hosts helios'
  assert_not_contains "$ERR" 'DTrace failed'   # uname's verdict settles it first
  assert_eq 0 "$(ssh_count guest-verified)" 'no marker'
  assert_contains "$ERR" "host $LAB_ID is running and billing"
  assert_not_contains "$OUT" 'guest ready'
}

test_uname_verdict_needs_exactly_illumos_from_uname_o() {
  load_cli
  local spec rc text want
  # uname -a prints SunOS and the build, never "illumos" (U7): it must not pass.
  for spec in '0|illumos|illumos' $'0|illumos\r|illumos' '0| illumos |illumos' '0|GNU/Linux|other' '0|SunOS|other' \
              '0|SunOS helios 5.11 helios-3.0.23976 i86pc i386 i86pc|other' '0||other' '0|illumos-ish|other' \
              '255|Connection closed by UNKNOWN port 65535|wait' \
              '255|channel 0: open failed: connect failed: Name or service not known|wait' \
              '255|ubuntu@helios: Permission denied (publickey).|wait' \
              '255|Host key verification failed.|hostkey' '127|bash: uname: command not found|failed'; do
    IFS='|' read -r rc text want <<< "$spec"
    assert_eq "$want" "$(uname_verdict "$rc" "$text")" "uname_verdict $rc '$text'"
  done
}

test_a_dtrace_probe_that_fails_names_dtrace_and_pfexec_and_writes_no_marker() {
  world_running
  smoke_reply illumos 0 'dtrace: failed to initialize dtrace: DTrace requires additional privileges' 1 \
    | ssh_reply ssh-guest-uname
  run_cli up
  assert_rc 1
  assert_contains "$ERR" "DTrace failed on the guest: $SMOKE_DTRACE_CMD exited 1"
  assert_contains "$ERR" 'which pfexec grants'
  assert_contains "$ERR" 'the guest said: dtrace: failed to initialize dtrace: DTrace requires additional privileges'
  assert_eq 0 "$(ssh_count guest-verified)" 'no marker'
}

test_dtrace_verdict_table() {
  load_cli
  assert_eq ok "$(dtrace_verdict 0 'CPU     ID')"
  assert_eq failed "$(dtrace_verdict 1 'dtrace: failed to initialize dtrace')"
  assert_eq wait "$(dtrace_verdict 255 'Connection closed by UNKNOWN port 65535')"
  assert_eq hostkey "$(dtrace_verdict 255 'Host key verification failed.')"
}

test_the_smoke_probe_is_the_plans_dtrace_one_liner_that_ends_itself() {
  load_cli
  assert_eq 'uname -o' "$SMOKE_UNAME"
  assert_eq "$SMOKE_DTRACE_CMD" "$SMOKE_DTRACE"
  assert_contains "$SMOKE_DTRACE" 'exit(0)'
  assert_eq "$SMOKE_CMD" "$SMOKE_COMMAND" 'both, in one remote command'
}

test_the_smoke_reply_is_read_back_check_by_check() {
  load_cli
  local reply
  reply=$(smoke_reply illumos 0 "$DTRACE_BEGIN_OUT" 0)
  assert_eq "0${US}illumos" "$(smoke_result 0 "$reply" uname)"
  assert_eq "0${US}$DTRACE_BEGIN_OUT" "$(smoke_result 0 "$reply" dtrace)"
  reply=$(smoke_reply illumos 0 'dtrace: failed to initialize dtrace' 1)
  assert_eq "1${US}dtrace: failed to initialize dtrace" "$(smoke_result 0 "$reply" dtrace)"
  reply=$(smoke_reply '' 127)
  assert_eq "127${US}" "$(smoke_result 0 "$reply" uname)" 'nothing printed'
  assert_eq "?${US}$reply" "$(smoke_result 0 "$reply" dtrace)" 'the shell stopped before dtrace: failed'
  assert_eq failed "$(dtrace_verdict '?' '')"
  # ssh's own failure, or the remote shell's, stands for both checks
  assert_eq "255${US}Connection closed by UNKNOWN port 65535" "$(smoke_result 255 'Connection closed by UNKNOWN port 65535' dtrace)"
  if smoke_part "$(smoke_reply illumos 0)" dtrace >/dev/null; then fail 'found a dtrace part without its marker'; fi
}

# --- Mac: the guest key ------------------------------------------------------
test_an_unverified_guests_old_pin_is_dropped_before_the_first_smoke_poll() {
  world_running
  pinned_guest
  run_cli up
  assert_rc 0
  if has_pin "$LAB_ID-guest"; then fail 'the old guest pin survived'; fi
  has_pin "$LAB_ID" || fail 'the host pin went too'
  [[ ! -e $(known_hosts).old ]] || fail "ssh-keygen's backup, holding the old key, was left behind"
  assert_contains "$OUT" "guest key · dropped the pin $LAB_ID-guest"
  assert_above 'guest key · dropped' 'first boot · waiting'
}

test_a_verified_guests_pin_is_kept() {
  world_running
  pinned_guest
  guest_status_reply verified | ssh_reply ssh-host-status
  run_cli up
  assert_rc 0
  has_pin "$LAB_ID-guest" || fail 'the verified guest lost its pin'
  assert_not_contains "$OUT" 'guest key ·'
}

# --- Mac: timeouts -----------------------------------------------------------
test_a_first_boot_gets_30_minutes_and_a_restart_5() {
  load_cli
  assert_eq 180 "$(guest_attempts no)"
  assert_eq 30 "$(guest_attempts yes)"
  assert_eq 30m "$(fmt_duration $(( $(guest_attempts no) * 10 )))" 'at the default 10 s apart'
  assert_eq 5m "$(fmt_duration $(( $(guest_attempts yes) * 10 )))"
  assert_eq 'first boot' "$(guest_wait_label no)"
  assert_eq 'guest boot' "$(guest_wait_label yes)"
}

test_a_first_boot_that_never_answers_times_out_abandons_it_and_says_up_recreates_it() {
  world_running
  guest_status_reply booting | ssh_reply ssh-host-status
  ssh_reply ssh-host-guest-abandon < /dev/null
  run_cli up
  assert_rc 1
  assert_eq 180 "$(ssh_count "host sudo $HELPER_PATH status")" 'polls: the long budget'
  assert_eq 0 "$(ssh_count "$(cfg) guest ")" 'a guest the host never sees on tcp/22 is never tried'
  assert_eq 1 "$(ssh_count "host sudo $HELPER_PATH guest-abandon")"
  assert_eq 0 "$(ssh_count guest-verified)"
  assert_contains "$ERR" "the guest's first boot did not pass the smoke check within"
  assert_contains "$ERR" $'last lines of its console transcript (/var/log/helios-lab/console.log on the host):\n    Loading smf(7) service descriptions: 112/112'
  assert_contains "$ERR" 'the next helios-lab up recreates the guest; the downloaded seed is kept'
  assert_contains "$ERR" "host $LAB_ID is running and billing"
  assert_eq 1 "$(grep -c 'Loading smf' <<< "$OUT")" 'an unchanged line is shown once'
}

test_a_verified_guest_that_never_answers_times_out_at_the_short_budget_and_is_kept() {
  world_running
  guest_status_reply verified-booting | ssh_reply ssh-host-status
  run_cli up
  assert_rc 1
  assert_eq 30 "$(ssh_count "host sudo $HELPER_PATH status")" 'polls: the restart budget'
  assert_eq 0 "$(ssh_count guest-abandon)" 'a verified guest is never abandoned'
  assert_contains "$ERR" 'the verified guest did not pass the smoke check within'
  assert_contains "$ERR" 'last seen: domain running, no DHCP lease yet'
  assert_contains "$ERR" 'a verified guest is never recreated'
  assert_contains "$OUT" 'guest boot · 0s · domain running, no DHCP lease yet'
}

test_while_waiting_up_shows_each_new_console_line_once() {
  world_running
  guest_status_reply booting | ssh_reply_seq ssh-host-status 1
  guest_status_reply booting | sed 's/^console .*/console helios console login:/' | ssh_reply_seq ssh-host-status 2
  guest_status_reply booting | sed 's/^console .*/console helios console login:/' | ssh_reply_seq ssh-host-status 3
  run_cli up
  assert_rc 0
  assert_eq 'first boot · Ns · Loading smf(7) service descriptions: 112/112
first boot · Ns · helios console login:' "$(grep '^first boot · [0-9]' <<< "$OUT" | steady)"
  assert_eq 4 "$(ssh_count "host sudo $HELPER_PATH status")" 'three waits, then the default (ready) reply'
}

test_a_guest_that_refuses_the_key_while_booting_is_retried_until_it_lets_us_in() {
  world_running
  ssh_reply_error ssh-guest-uname.1 255 'ubuntu@helios: Permission denied (publickey).'
  run_cli up
  assert_rc 0
  assert_eq 2 "$(ssh_count 'guest uname -o')"
  assert_contains "$OUT" "the guest's ssh does not answer yet (ubuntu@helios: Permission denied (publickey).)"
}

# --- Mac: a host that stops itself mid-up ------------------------------------
test_a_host_that_stopped_itself_mid_up_is_named_and_up_follows_the_state_machine() {
  world_running
  set_field "$COL_STATE" stopping < "$STOPPED_IDLE" | tagged | reply ec2-describe-instances.2   # asked again after the ssh failure
  reply ec2-start-instances "$STARTING"
  ssh_reply_error ssh-host-bash.1 255 "$NET_DOWN"
  run_cli up
  assert_rc 0
  assert_contains "$ERR" 'cannot reach the host over ssh'   # the failure, as it happened
  assert_contains "$OUT" "host $LAB_ID stopped itself (idle) while up was connecting · up follows it"
  assert_contains "$OUT" "waiting for $LAB_ID to finish stopping"
  assert_log_order "aws ec2 wait instance-stopped --instance-ids $LAB_ID" 'aws ec2 start-instances'
  assert_eq 2 "$(ssh_count 'host sudo bash -c')" 'the push, again'
  (( $(line_no 'aws ec2 start-instances') < $(line_no 'host sudo bash -c' 2) )) || fail 'the second push came before the start'
  assert_eq 'next: helios-lab ssh' "$(tail -1 <<< "$OUT")"
  assert_not_contains "$ERR" 'running and billing'
}

test_a_host_found_stopped_during_the_guest_poll_is_started_again() {
  world_running
  tagged < "$STOPPED_IDLE" | reply_seq ec2-describe-instances 2
  reply ec2-start-instances "$STARTING"
  local n
  for n in 1 2 3; do ssh_reply_error "ssh-host-status.$n" 255 'Connection closed by 203.0.113.10 port 22'; done
  run_cli up
  assert_rc 0
  assert_contains "$OUT" "host $LAB_ID stopped itself (idle) while up was connecting · up follows it"
  assert_not_contains "$(calls)" 'wait instance-stopped'   # already stopped: start at once
  assert_eq 1 "$(grep -c 'aws ec2 start-instances' "$STUB_LOG")"
  assert_eq 1 "$(ssh_count guest-verified)"
}

test_a_host_still_running_after_an_ssh_failure_keeps_the_failure() {
  world_running
  ssh_reply_error ssh-host-bash 255 "$NET_DOWN"
  run_cli up
  assert_rc 8
  assert_contains "$ERR" 'cannot reach the host over ssh'
  assert_contains "$ERR" "host $LAB_ID is running and billing"
  assert_eq 0 "$(grep -c 'start-instances' "$STUB_LOG" || true)"
  assert_eq 2 "$(grep -c '^aws ec2 describe-instances' "$STUB_LOG")" 'discover (a running host is not looked up again), then EC2 asked again'
}

test_a_second_stop_while_following_is_not_followed_again() {
  world_running
  tagged < "$STOPPED_IDLE" | reply_seq ec2-describe-instances 2
  reply ec2-start-instances "$STARTING"
  ssh_reply_error ssh-host-bash 255 "$NET_DOWN"
  run_cli up
  assert_rc 8
  assert_eq 1 "$(grep -c 'aws ec2 start-instances' "$STUB_LOG")" 'followed once'
  assert_eq 1 "$(grep -c 'up follows it' <<< "$OUT")"
}

test_stop_messages_name_the_cause() {
  load_cli
  export TZ=Asia/Tokyo
  assert_eq "host $LAB_ID stopped itself (idle) while up was connecting" \
    "$(stopped_while_connecting "$LAB_ID" Client.InstanceInitiatedShutdown 'User initiated')"
  assert_eq "host $LAB_ID was stopped by you 20:05 while up was connecting" \
    "$(stopped_while_connecting "$LAB_ID" Client.UserInitiatedShutdown 'User initiated (2026-10-24 11:05:21 GMT)')"
}

# --- Mac: ssh and console ----------------------------------------------------
test_ssh_and_console_refuse_a_host_that_stopped_itself_without_a_time_and_never_ssh() {
  lab_key
  reply ec2-describe-instances "$STOPPED_IDLE"
  local cmd
  for cmd in ssh console; do
    again
    run_cli "$cmd"
    assert_rc 1
    assert_contains "$ERR" "$LAB_ID stopped itself (idle) — run helios-lab up"
    assert_contains "$ERR" 'never start the host themselves: it bills while it runs'
    if [[ $ERR =~ [0-9][0-9]:[0-9][0-9] ]]; then fail "an idle stop has no time, yet: $ERR"; fi
    assert_eq '' "$(grep -E '^(ssh|ssh-keyscan) ' "$STUB_LOG" || true)" "$cmd: no ssh at all"
    assert_eq describe-instances "$(aws_ops)" "$cmd: discovery only, no ingress refresh"
  done
}

test_ssh_refuses_a_manual_stop_with_its_time_and_other_states_too() {
  lab_key
  export TZ=Asia/Tokyo
  reply ec2-describe-instances "$STOPPED_USER"
  run_cli ssh host uptime
  assert_rc 1
  assert_contains "$ERR" "$LAB_ID is stopped by you 20:05 — run helios-lab up"
  assert_eq '' "$(ssh_calls)"
  again
  reply ec2-describe-instances < /dev/null
  run_cli console
  assert_rc 1
  assert_contains "$ERR" 'no lab instance — run helios-lab up'
}

test_not_running_message_table() {
  load_cli
  local id=$LAB_ID
  assert_eq "$id is stopping — run helios-lab up (it waits, then starts it again)" "$(not_running_message stopping "$id" '' '')"
  assert_eq "$id is starting — run helios-lab up (it waits until it runs)" "$(not_running_message pending "$id" '' '')"
  assert_eq "$id is being terminated — run helios-lab up for a new lab" "$(not_running_message shutting-down "$id" '' '')"
  assert_eq "$id is stopped — run helios-lab up" "$(not_running_message stopped "$id" None '')"
  assert_eq "$id stopped itself (idle) — run helios-lab up" "$(not_running_message stopped "$id" Client.InstanceInitiatedShutdown 'User initiated')"
}

test_ssh_refuses_duplicates() {
  lab_key
  { cat "$RUNNING"; set_field 1 "$OTHER_ID" < "$STOPPED_USER"; } | reply ec2-describe-instances
  run_cli ssh
  assert_rc 4
  assert_contains "$ERR" '2 lab instances exist'
  assert_eq '' "$(ssh_calls)"
}

test_ssh_goes_to_the_guest_by_default_through_the_fragment_after_the_ingress_refresh() {
  world_running
  pinned
  ssh_reply ssh-guest-login < /dev/null
  run_cli ssh
  assert_rc 0
  assert_eq "ssh -F $(cfg) guest" "$(ssh_calls)" 'an interactive login on the guest alias'
  assert_contains "$(<"$(cfg)")" $'Host guest\n  HostName helios\n  ProxyJump host'
  assert_log_order 'aws ec2 describe-security-group-rules' "ssh -F $(cfg) guest"
  assert_log_order "Tags[?Key=='KeyFingerprint']" "ssh -F $(cfg) guest"   # the lab key is checked first
  again
  run_cli ssh guest
  assert_eq "ssh -F $(cfg) guest" "$(ssh_calls)"
}

test_ssh_host_uptime_runs_uptime_on_the_host_and_passes_its_output_and_status_through() {
  world_running
  pinned
  echo ' 11:02:41 up 3 min,  1 user,  load average: 0.08, 0.02, 0.01' | ssh_reply ssh-host-uptime
  run_cli ssh host uptime
  assert_rc 0
  assert_eq "ssh -F $(cfg) host uptime" "$(ssh_calls)"
  assert_eq ' 11:02:41 up 3 min,  1 user,  load average: 0.08, 0.02, 0.01' "$OUT" 'only the command'"'"'s output'
  again
  ssh_reply_error ssh-host-false 3 ''
  run_cli ssh host false
  assert_rc 3
}

test_ssh_joins_extra_words_as_ssh_itself_does() {
  world_running
  pinned
  ssh_reply ssh-guest-uname < /dev/null
  ssh_reply ssh-guest-dtrace < /dev/null
  run_cli ssh uname -a
  assert_eq "ssh -F $(cfg) guest uname -a" "$(ssh_calls)" 'no alias word: the guest'
  again
  run_cli ssh guest pfexec dtrace -l -n 'syscall::read:entry'
  assert_eq "ssh -F $(cfg) guest pfexec dtrace -l -n syscall::read:entry" "$(ssh_calls)"
  load_cli
  assert_eq guest "$(ssh_alias)"
  assert_eq '' "$(ssh_command)"
  assert_eq host "$(ssh_alias host uptime)"
  assert_eq uptime "$(ssh_command host uptime)"
  assert_eq 'hostname -f' "$(ssh_command hostname -f)"
  assert_eq guest "$(ssh_alias hostname -f)"
}

test_ssh_notices_go_to_stderr_so_only_the_command_reaches_stdout() {
  world_running   # not pinned: ssh verifies the host key first
  echo helios | ssh_reply ssh-guest-hostname
  run_cli ssh hostname
  assert_rc 0
  assert_eq helios "$OUT"
  assert_contains "$ERR" "host key · ED25519 SHA256:e3nmpQY3OllEnw+YTnIxOK1vZttbrX0xpEMwqyQdKTQ matches the console"
}

test_console_allocates_a_tty_for_virsh_console_and_says_what_it_takes_over() {
  world_running
  pinned
  ssh_reply ssh-host-virsh < /dev/null
  run_cli console
  assert_rc 0
  assert_eq "ssh -F $(cfg) -t host virsh -c qemu:///system console --force helios" "$(ssh_calls)"
  assert_contains "$ERR" 'Ctrl-] detaches'
  assert_contains "$ERR" 'it takes the console from the first-boot transcript logger'
  again
  run_cli console now
  assert_rc 2
  assert_contains "$ERR" 'console takes no arguments'
  assert_eq '' "$(calls)"
}

test_a_state_dir_proxyjump_cannot_carry_is_refused_before_anything_bills() {
  export HELIOS_LAB_STATE_DIR="$SANDBOX/state dir"
  local args
  for args in up ssh 'ssh guest uname'; do
    again
    # shellcheck disable=SC2086  # split the arguments
    run_cli $args
    assert_rc 2
    assert_contains "$ERR" "has characters ssh's ProxyJump can't pass on to reach the guest"
    assert_contains "$ERR" 'set HELIOS_LAB_STATE_DIR'
    assert_eq '' "$(calls)" "$args: no call at all"
  done
  again
  run_cli ssh host uptime   # the host alias has no ProxyJump: not refused for that
  assert_not_contains "$ERR" 'ProxyJump'
  load_cli
  jump_safe_path /Users/someone/.local/state/helios-lab/ssh_config || fail 'refused a plain path'
  jump_safe_path /var/folders/x_y/T/helios-lab-tests.Ab12/t.x/state/ssh_config || fail 'refused a temp path'
  local p
  # shellcheck disable=SC2016  # the literal $ is the point
  for p in '/a b/ssh_config' 'relative/ssh_config' '/a$b' '/a;b' "/a'b" '/a~b' ''; do
    if jump_safe_path "$p"; then fail "accepted '$p'"; fi
  done
}

test_the_stub_ssh_allows_only_the_options_the_contract_names() {
  mkdir -p "$HELIOS_LAB_STATE_DIR"
  local f=$HELIOS_LAB_STATE_DIR/ssh_config rc
  : > "$f"
  ssh_reply ssh-host-uptime < /dev/null
  ssh_reply ssh-guest-login < /dev/null
  ssh -F "$f" -t host uptime < /dev/null || fail '-t refused'
  ssh -F "$f" -o ConnectTimeout=3 -o BatchMode=yes host uptime < /dev/null || fail 'the probe options refused'
  ssh -F "$f" guest < /dev/null || fail 'a login refused'
  rc=0; ssh -F "$f" -o StrictHostKeyChecking=no host uptime < /dev/null 2>/dev/null || rc=$?
  assert_eq 98 "$rc" 'an option that loosens the fragment'
  rc=0; ssh -F "$f" -A host uptime < /dev/null 2>/dev/null || rc=$?
  assert_eq 98 "$rc" 'agent forwarding'
  rc=0; ssh -F "$f" host uptime extra < /dev/null 2>/dev/null || rc=$?
  assert_eq 98 "$rc" 'two command words'
  rc=0; ssh -t -F "$f" host uptime < /dev/null 2>/dev/null || rc=$?
  assert_eq 98 "$rc" '-F not first'
}

# --- Mac: status -------------------------------------------------------------
test_status_shows_a_ready_guest_from_one_read_only_3_second_probe() {
  world_status
  guest_status_reply verified unchanged | ssh_reply ssh-host-status
  run_status
  assert_rc 0
  assert_contains "$(sed -n 1p <<< "$OUT")" 'running · guest ready · up '
  assert_contains "$OUT" '  provision done'
  assert_contains "$OUT" "  guest     helios running · verified · engvm @8ef18ef · $LAB_SIZING"
  assert_eq "ssh -F $(cfg) $STATUS_PROBE_CALL" "$(ssh_calls)"
  assert_not_contains "$(calls)" 'SecurityGroupRuleId'   # the ingress check's query, not the refresh's
  assert_not_contains "$OUT" '!'
}

test_status_shows_a_first_boot_with_its_latest_console_line() {
  world_status
  guest_status_reply first-boot | ssh_reply ssh-host-status
  run_status
  assert_rc 0
  assert_contains "$(sed -n 1p <<< "$OUT")" 'running · guest first boot · up '
  assert_contains "$OUT" '  guest     helios running · first boot under way'
  assert_contains "$OUT" '  console   Hostname: helios'
}

test_status_flags_a_failed_provision_stage_above_the_state_line() {
  world_status
  guest_status_reply not-built seed-timeout | ssh_reply ssh-host-status
  run_status
  assert_rc 0
  assert_line 1 "! provision failed at stage seed: $SEED_TIMEOUT_REASON; helios-lab up runs it again"
  assert_contains "$(sed -n 2p <<< "$OUT")" 'running · guest not built · up '
  assert_contains "$OUT" "  provision failed at seed: $SEED_TIMEOUT_REASON"
  assert_contains "$OUT" '  guest     not built yet: helios-lab up builds it'
}

test_status_shows_a_sizing_mismatch_anomaly_for_a_verified_guest() {
  world_status
  guest_status_reply other-sizing | ssh_reply ssh-host-status
  run_status
  assert_rc 0
  assert_line 1 "! the guest was built from engvm @8ef18ef, $LAB_SIZING; the pushed config says @8ef18ef, 4 vCPU, 8 GiB, 60G. A verified guest is kept as it is; to rebuild it (its disk is lost): helios-lab ssh host sudo rm /var/lib/helios-lab/guest-verified, then helios-lab up"
  assert_above 'the guest was built from' 'running · guest ready'
}

test_up_warns_of_the_same_mismatch_and_keeps_the_guest() {
  world_running
  guest_status_reply other-sizing | ssh_reply ssh-host-status
  run_cli up
  assert_rc 0
  assert_contains "$ERR" 'helios-lab: the guest was built from engvm @8ef18ef, 3 vCPU, 8 GiB, 60G; the pushed config says @8ef18ef, 4 vCPU, 8 GiB, 60G.'
  assert_eq 0 "$(ssh_count guest-verified)"
  assert_eq 0 "$(ssh_count guest-abandon)"
}

test_status_flags_a_host_that_does_not_answer_ssh() {
  world_status
  ssh_reply_error ssh-host-status 255 "$NET_DOWN"
  run_status
  assert_rc 0
  assert_line 1 "! the host did not answer ssh within 3s ($NET_DOWN): it may be stopping itself; helios-lab up reconnects"
  assert_contains "$(sed -n 2p <<< "$OUT")" 'running · up '
  assert_not_contains "$(sed -n 2p <<< "$OUT")" 'guest'
  assert_contains "$OUT" '  host      no answer over ssh within 3s'
}

test_status_flags_a_failed_probe() {
  world_status
  ssh_reply_error ssh-host-status 1 'helios-lab-host: usage: helios-lab-host install <dir> | provision'
  run_status
  assert_rc 0
  assert_line 1 "! the host's status probe failed (exit 1: helios-lab-host: usage: helios-lab-host install <dir> | provision): helios-lab up pushes the current helper"
}

test_status_never_probes_a_host_whose_key_is_not_pinned_or_that_this_mac_cannot_reach() {
  reply ec2-describe-instances "$RUNNING"
  reply ec2-describe-security-group-rules "$INGRESS"
  caller_ip_is "$HOST_IP"
  run_status
  assert_rc 0
  assert_eq '' "$(ssh_calls)$(grep '^ssh-keyscan' "$STUB_LOG" || true)" 'no ssh, no key scan'
  assert_contains "$OUT" '  host      its key is not pinned on this Mac yet: helios-lab up verifies it against the console'
  assert_eq 0 "$(grep -c 'get-console-output' "$STUB_LOG" || true)"
  again
  pinned
  caller_ip_is "$OTHER_IP"
  run_status
  assert_line 1 "! this Mac's IP ($OTHER_IP) is not allowed in the security group: helios-lab up updates the rule"
  assert_eq '' "$(ssh_calls)"
  assert_contains "$OUT" "  host      not probed: this Mac's IP ($OTHER_IP) is not allowed in the security group"
}

test_status_says_guest_intact_for_a_stopped_host_whose_guest_this_mac_reached() {
  reply ec2-describe-instances "$STOPPED_IDLE"
  run_status
  assert_line 1 "stopped by idle timer · ≈\$0.32/day"
  again
  pinned_guest
  run_status
  assert_rc 0
  assert_line 1 "stopped by idle timer · guest intact · ≈\$0.32/day"
  assert_eq '' "$(ssh_calls)" 'a stopped host is not probed'
}

test_guest_fields_and_details_for_each_kind_of_reply() {
  load_cli
  local spec kind field
  for spec in 'first-boot|guest first boot' 'booting|guest first boot' 'verified|guest ready' \
              'other-sizing|guest ready' 'not-built|guest not built' 'shut-off|guest not verified'; do
    IFS='|' read -r kind field <<< "$spec"
    assert_eq "$field" "$(guest_field "$(guest_status_reply "$kind")")" "$kind"
  done
  assert_eq 'guest shut off' "$(guest_field "$(guest_status_reply verified | sed 's/^domain .*/domain shut off/')")"
  assert_eq 'helios shut off · not verified: the next helios-lab up recreates it' "$(guest_detail "$(guest_status_reply shut-off)")"
  assert_eq yes "$(guest_verified_of "$(guest_status_reply verified)")"
  assert_eq no "$(guest_verified_of "$(guest_status_reply first-boot)")"
  assert_eq no "$(guest_verified_of 'unit inactive success')" 'an old helper says nothing: unverified'
  guest_ssh_ready "$(guest_status_reply first-boot)" || fail 'first-boot is ready'
  if guest_ssh_ready "$(guest_status_reply booting)"; then fail 'no lease is not ready'; fi
  if guest_ssh_ready "$(guest_status_reply first-boot | sed 's/^sshd .*/sshd closed/')"; then fail 'a closed sshd is not ready'; fi
  if guest_ssh_ready "$(guest_status_reply first-boot | sed 's/^domain .*/domain paused/')"; then fail 'a paused domain is not ready'; fi
  assert_eq "lease $GUEST_IP, sshd not listening yet" "$(guest_wait_phrase "$(guest_status_reply first-boot | sed 's/^sshd .*/sshd closed/')")"
  assert_eq 'domain absent' "$(guest_wait_phrase "$(guest_status_reply not-built)")"
  assert_eq 'Hostname: helios' "$(guest_wait_line "$(guest_status_reply first-boot)")"
  assert_eq 'domain running, no DHCP lease yet' "$(guest_wait_line "$(guest_status_reply verified-booting)")"
}

test_guest_mismatch_only_for_a_verified_guest_built_from_other_settings() {
  load_cli
  local verified pushed
  assert_eq '' "$(guest_mismatch "$(guest_status_reply verified)")" 'the same settings'
  assert_eq '' "$(guest_mismatch "$(guest_status_reply first-boot)")" 'not verified'
  assert_eq '' "$(guest_mismatch "$(guest_status_reply verified | sed 's/^pushed .*/pushed unknown/')")" 'push unknown'
  pushed="pushed $OTHER_PIN $LAB_SIZING"
  assert_contains "$(guest_mismatch "$(guest_status_reply verified | sed "s/^pushed .*/$pushed/")")" \
    'built from engvm @8ef18ef, 3 vCPU, 8 GiB, 60G; the pushed config says @0123456, 3 vCPU, 8 GiB, 60G'
  verified="verified $PIN 3 vCPU, 8 GiB, 30G"
  assert_contains "$(guest_mismatch "$(guest_status_reply verified | sed "s/^verified .*/$verified/")")" 'built from engvm @8ef18ef, 3 vCPU, 8 GiB, 30G'
}

test_provision_state_reads_the_last_run() {
  load_cli
  assert_eq 'done' "$(provision_state "$(progress_reply 'done')")"
  assert_eq "running${US}seed" "$(provision_state "$( { progress_until engvm "$RUN_EPOCH"; echo "$RUN_EPOCH seed start"; echo 'unit active running'; } )")"
  assert_eq "failed${US}seed${US}$SEED_TIMEOUT_REASON" "$(provision_state "$(progress_reply seed-timeout)")"
  assert_eq none "$(provision_state 'unit inactive dead')" 'never ran'
  assert_eq "running$US" "$(provision_state 'unit activating start-pre')" 'just started'
  assert_eq 'running: seed' "$(provision_detail "running${US}seed")"
  assert_eq 'has not run yet: helios-lab up starts it' "$(provision_detail none)"
}

# --- Mac: the seed's RFD 26 line ---------------------------------------------
test_the_rfd_26_line_prints_once_as_soon_as_the_seed_stage_starts() {
  world_running
  { progress_until engvm "$RUN_EPOCH"; echo "$(( RUN_EPOCH + 53 )) seed start"; echo 'unit active running'; } \
    | ssh_reply_seq ssh-host-progress 1
  run_cli up
  assert_rc 0
  assert_eq 1 "$(grep -cF "$RFD26_TEXT" <<< "$OUT")" 'printed once over two polls'
  assert_above 'engvm · done' "$RFD26_TEXT"
  assert_above "$RFD26_TEXT" 'seed · done'
}

test_a_seed_download_timeout_fails_up_naming_the_seed_stage() {
  world_running
  progress_reply seed-timeout | ssh_reply ssh-host-progress
  ssh_reply ssh-host-journal < /dev/null
  run_cli up
  assert_rc 1
  assert_contains "$ERR" "provision failed at stage seed: $SEED_TIMEOUT_REASON"
  assert_contains "$OUT" "seed · failed · 20m00s · $SEED_TIMEOUT_REASON"
  assert_above "$RFD26_TEXT" 'seed · failed'
  assert_eq 0 "$(ssh_count "$(cfg) guest ")" 'no smoke check after a failed provision'
  assert_eq 0 "$(ssh_count "helios-lab-host status")"
}

test_the_ready_screen() {
  load_cli
  export TZ=UTC
  # U4: the push armed the idle timer, so that is the stop the screen names.
  assert_eq "guest ready in 9m48s · illumos · dtrace ok
  in the guest, try: $ONE_LINER  (Ctrl-C prints system calls by process)
  auto-stops after 60 min idle · helios-lab keep 3h to hold it · helios-lab stop when done
next: helios-lab ssh" "$(ready_screen 588 60 none)"
  assert_eq '  auto-stop inhibited until 13:50, then it stops after 90 min idle · helios-lab keep off clears it · helios-lab stop when done' \
    "$(ready_screen 588 90 1792849839 | sed -n 3p)" 'a keep in force'
  assert_eq 'guest ready · illumos · dtrace ok' "$(ready_screen '' 60 none | head -1)" 'no elapsed outside up'
}

# --- Mac and host agree ------------------------------------------------------
test_the_mac_and_the_helper_name_the_same_marker_vm_and_sizing() {
  local mac host
  local -a m h
  mac=$( load_cli; printf '%s|%s|%s|%s' "$GUEST_MARKER" "$GUEST_NAME" "$GUEST_VCPUS vCPU, $GUEST_MEM_GIB GiB" "$GUEST_CONSOLE_COMMAND" )
  host=$( host_env; printf '%s|%s|%s|' "${GUEST_VERIFIED#"$SANDBOX/root"}" "$GUEST_VM" "$(lab_sizing "$(<"$LAB_CONF")")" )
  IFS='|' read -r -a m <<< "$mac"
  IFS='|' read -r -a h <<< "$host"
  assert_eq "${h[0]}" "${m[0]}" 'the guest-verified path'
  assert_eq "${h[1]}" "${m[1]}" 'the VM name'
  assert_eq "${m[2]}, 60G" "${h[2]}" "the shipped sizing is the one state.sh's guest_fits assumes"
  assert_contains "${m[3]}" "qemu:///system console --force ${h[1]}"
}

# --- Host: pure --------------------------------------------------------------
# host_env — the helper, sourced, with its root in the sandbox
host_env() {
  export HELIOS_LAB_HOST_ROOT=$SANDBOX/root
  # shellcheck source=../host/helios-lab-host
  source "$HELPER"
  require_root() { :; }
}

test_lab_sizing_reads_only_the_shipped_forms() {
  host_env
  assert_eq "$LAB_SIZING" "$(lab_sizing "$(<"$LAB_CONF")")" 'the shipped file'
  assert_eq '4 vCPU, 12 GiB, 100G' "$(lab_sizing $'VCPU=4\nMEM=$(( 12 * 1024 * 1024 ))\nSIZE=100G')"
  local bad
  for bad in '' $'VCPU=3\nMEM=$(( 8 * 1024 * 1024 ))' $'VCPU=3\nSIZE=60G' \
             $'VCPU=3\nMEM=8388608\nSIZE=60G' $'VCPU=0\nMEM=$(( 8 * 1024 * 1024 ))\nSIZE=60G' \
             $'VCPU=3\nMEM=$(( 8 * 1024 * 1024 ))\nSIZE=60' $'VCPU=3\nMEM=$(( 8 * 1024 * 1024 ))\nSIZE=60G\nrm -rf /' \
             $'VCPU=3\nMEM=$(( 8 * 1024 * 1024 ))\nSIZE=60G\nVM=other' $'VCPU=3; id\nMEM=$(( 8 * 1024 * 1024 ))\nSIZE=60G'; do
    if lab_sizing "$bad" >/dev/null; then fail "accepted: $bad"; fi
  done
}

test_guest_action_follows_the_single_marker_protocol() {
  host_env
  local spec verified domain create want
  for spec in 'yes|running|inactive|keep' 'yes|running|active|keep' 'yes|shut off|inactive|start' \
              'yes|crashed|inactive|start' 'yes|absent|inactive|lost' 'yes|paused|inactive|odd' \
              'yes|unknown|inactive|odd' 'yes|absent|active|lost' \
              'no|running|active|wait' 'no|absent|active|wait' 'no|absent|activating|wait' \
              'no|running|inactive|create' 'no|shut off|failed|create' 'no|absent|inactive|create' \
              'no|unknown|unknown|create'; do
    IFS='|' read -r verified domain create want <<< "$spec"
    assert_eq "$want" "$(guest_action "$verified" "$domain" "$create")" "$spec"
  done
  # Invariant: with the marker, never create.
  for domain in running 'shut off' crashed absent paused unknown 'in shutdown'; do
    for create in active inactive failed; do
      [[ $(guest_action yes "$domain" "$create") != create ]] || fail "a verified guest would be recreated ($domain, $create)"
    done
  done
  if guest_action maybe running active >/dev/null; then fail 'accepted a verified value outside yes|no'; fi
}

test_kept_note_says_what_a_verified_guest_was_built_from() {
  host_env
  local record
  record=$(guest_record "$PIN" "$LAB_SIZING")
  assert_eq "ENGVM_PIN=$PIN"$'\n'"SIZING=$LAB_SIZING" "$record"
  assert_eq "$PIN" "$(record_field "$record" ENGVM_PIN)"
  assert_eq '?' "$(record_field '' SIZING)"
  assert_eq '' "$(kept_note "$record" "$PIN" "$LAB_SIZING")"
  assert_eq "built from engvm @8ef18ef, $LAB_SIZING, not the pushed @8ef18ef, 4 vCPU, 8 GiB, 60G: kept, only a re-create applies it" \
    "$(kept_note "$record" "$PIN" '4 vCPU, 8 GiB, 60G')"
  assert_contains "$(kept_note "$record" "$OTHER_PIN" "$LAB_SIZING")" 'not the pushed @0123456'
}

test_seed_verdict_and_domstate_tables() {
  host_env
  assert_eq ok "$(seed_verdict 0)"
  assert_eq timeout "$(seed_verdict 124)"
  assert_eq failed "$(seed_verdict 1)"
  assert_eq failed "$(seed_verdict 137)"
  # Hand-written: virsh domstate's output shapes (a state, then a blank line).
  assert_eq running "$(domstate_of 0 $'running\n')"
  assert_eq 'shut off' "$(domstate_of 0 $'shut off\n\n')"
  assert_eq absent "$(domstate_of 1 "error: failed to get domain 'helios'")"
  assert_eq absent "$(domstate_of 1 $'error: failed to get domain \'helios\'\nerror: Domain not found: no domain with matching name \'helios\'')"
  assert_eq unknown "$(domstate_of 1 'error: failed to connect to the hypervisor')"
  assert_eq unknown "$(domstate_of 127 'virsh: command not found')"
  assert_eq unknown "$(domstate_of 0 '')"
}

test_console_clean_keeps_what_the_terminal_last_showed() {
  host_env
  local raw
  # Hand-written in the shape the spike's transcript had: progress redrawn
  # after a CR, CRLF line ends, escape sequences, a bell, no final newline.
  raw=$'\e[2J\e[HLoading smf(7) service descriptions:   1/112\rLoading smf(7) service descriptions:  57/112'
  raw+=$'\rLoading smf(7) service descriptions: 112/112\r\n\r\n'
  raw+=$'\e[1;32mINFO\e[0m ok, run complete\r\n\a  Hostname: helios  \r\n\r\nhelios console login: '
  assert_eq 'Loading smf(7) service descriptions: 112/112
INFO ok, run complete
Hostname: helios
helios console login:' "$(console_clean "$raw")"
  assert_eq '' "$(console_clean $'\r\n\r\n\e[0m\r\n')"
}

test_engvm_and_seed_inputs_follow_the_pin_and_only_engvm_follows_the_sizing() {
  host_env
  local conf other lab lab4 engvm seed
  conf=$'IDLE_MINUTES=60\nENGVM_PIN='"$PIN"
  other=$'IDLE_MINUTES=60\nENGVM_PIN='"$OTHER_PIN"
  lab=$(<"$LAB_CONF")
  lab4=${lab/VCPU=3/VCPU=4}
  engvm=$(stage_input engvm "$conf" "$lab")
  seed=$(stage_input seed "$conf" "$lab")
  [[ $engvm =~ ^sha256:[0-9a-f]{64}$ && $seed =~ ^sha256:[0-9a-f]{64}$ && $engvm != "$seed" ]] || fail "inputs: $engvm $seed"
  assert_eq skip "$(stage_decision "$engvm" "$(stage_input engvm "$conf" "$lab")")" 'same pin and sizing'
  assert_eq run "$(stage_decision "$engvm" "$(stage_input engvm "$other" "$lab")")" 'a new pin re-runs engvm'
  assert_eq run "$(stage_decision "$engvm" "$(stage_input engvm "$conf" "$lab4")")" 'new sizing reinstalls config/lab.sh'
  assert_eq run "$(stage_decision "$seed" "$(stage_input seed "$other" "$lab")")" 'a new pin re-runs seed'
  assert_eq "$seed" "$(stage_input seed "$conf" "$lab4")" 'the sizing is not the seed'"'"'s input'
  assert_eq "$(stage_input packages)" "$(stage_input packages "$conf" "$lab")" "U2's stages keep their inputs"
  assert_contains "$(stage_spec engvm "$conf" "$lab")" "engvm r1: https://github.com/oxidecomputer/helios-engvm.git @ $PIN in /home/ubuntu/helios-engvm as ubuntu"
  # shellcheck disable=SC2016  # the sizing file's own text, unexpanded
  assert_contains "$(stage_spec engvm "$conf" "$lab")" 'MEM=$(( 8 * 1024 * 1024 ))'
  if stage_input guest "$conf" "$lab" >/dev/null; then fail 'the guest stage has an input (it must never be skipped)'; fi
  if stage_input engvm 'IDLE_MINUTES=60' "$lab" >/dev/null; then fail 'an engvm input without a pin'; fi
}

test_the_lease_is_the_first_ipv4_getent_prints() {
  host_env
  # shellcheck disable=SC2329  # called by guest_lease
  getent() { printf '%s\n' 'fd00::10        helios' "$GUEST_IP  helios"; }
  assert_eq "$GUEST_IP" "$(guest_lease)"
  # shellcheck disable=SC2329  # called by guest_lease
  getent() { return 2; }   # not found: no lease yet
  assert_eq '' "$(guest_lease)"
}

test_the_guest_sizing_installs_beside_host_conf() {
  host_env
  assert_eq "$SANDBOX/root/etc/helios-lab/engvm-lab.sh 0644" "$(install_dest engvm-lab.sh)"
}

test_a_bad_guest_sizing_fails_provision_before_any_stage() {
  host_env
  mkdir -p "$SANDBOX/root/etc/helios-lab"
  printf 'IDLE_MINUTES=60\nENGVM_PIN=%s\n' "$PIN" > "$SANDBOX/root/etc/helios-lab/host.conf"
  printf 'VCPU=3\nMEM=8G\nSIZE=60G\n' > "$SANDBOX/root/etc/helios-lab/engvm-lab.sh"
  RC=0; provision_run > /dev/null || RC=$?
  assert_eq 1 "$RC"
  assert_eq "provision fail bad guest sizing $SANDBOX/root/etc/helios-lab/engvm-lab.sh: not the VCPU, MEM and SIZE lines engvm-lab.sh ships; run helios-lab up" \
    "$(cut -d' ' -f2- "$SANDBOX/root/var/lib/helios-lab/progress" | sed -n 2p)"
  assert_eq 2 "$(grep -c . "$SANDBOX/root/var/lib/helios-lab/progress")" 'no stage started'
}

# --- Host: stages against faked tools ----------------------------------------
# host_files — what a push leaves: host.conf and the shipped sizing; sets CONF
host_files() {
  mkdir -p "$SANDBOX/root/etc/helios-lab"
  printf '# rendered\nIDLE_MINUTES=60\nENGVM_PIN=%s\n' "$PIN" > "$SANDBOX/root/etc/helios-lab/host.conf"
  cp "$LAB_CONF" "$SANDBOX/root/etc/helios-lab/engvm-lab.sh"
  CONF=$(<"$SANDBOX/root/etc/helios-lab/host.conf")
}

# stage_call <stage function> [args] — runs it as apply_stage does; sets RC
# and SUMMARY (its last fd-3 line); its stdout and stderr go to stage.out
stage_call() {
  local fn=$1
  shift
  RC=0
  SUMMARY=$("$fn" "$@" 3>&1 1>>"$SANDBOX/stage.out" 2>&1) || RC=$?
  SUMMARY=${SUMMARY##*$'\n'}
}

tools_log() { cat "$SANDBOX/tools.log" 2>/dev/null || true; }
# actions — the faked calls that would change something (state reads dropped)
actions() { tools_log | grep -vE '^(systemctl show |virsh -c qemu:///system domstate |getent |port22 )' || true; }

# next_of <name> <values, |-separated> — each call answers the next value;
# the last one repeats (call counts live in files: stages run in subshells)
next_of() {
  local counter=$SANDBOX/next.$1 n i=0 v last='' IFS='|'
  n=$(cat "$counter" 2>/dev/null || echo 0)
  echo $(( n + 1 )) > "$counter"
  for v in $2; do
    last=$v
    if (( i == n )); then echo "$v"; return 0; fi
    i=$(( i + 1 ))
  done
  echo "$last"
}

# fake_host_tools — after host_env: every tool the guest stages run, as a
# function that records its arguments and answers from FAKE_* settings. git
# itself only ever fails: a stage must reach it through runuser, as ubuntu.
# shellcheck disable=SC2329  # the fakes are called by the stages
fake_host_tools() {
  tool() { echo "$*" >> "$SANDBOX/tools.log"; }
  runuser() {
    tool runuser "$@"
    case $* in
      *' rev-parse HEAD')  echo "${FAKE_HEAD:-$PIN}" ;;
      *' cat-file -e '*)   [[ ${FAKE_HAS_PIN:-yes} == yes ]] ;;
      *' clone '*)         mkdir -p "$ENGVM_DIR/.git" "$ENGVM_DIR/config" ;;
    esac
  }
  git() { tool git "$@"; return 1; }
  timeout() { tool timeout "$@"; return "${FAKE_TIMEOUT_RC:-0}"; }
  install() { tool install "$@"; }
  systemd-run() { tool systemd-run "$@"; }
  sleep() { tool sleep "$@"; }
  systemctl() {
    tool systemctl "$@"
    [[ $1 == show ]] || return 0
    [[ $4 != -p ]] || { fake_show_blocks "${@:6}"; return 0; }
    case $5:$3 in   # show -p <property> --value <unit>
      "$CREATE_UNIT":*) next_of create "${FAKE_CREATE:-inactive}" ;;
      *:ActiveState)    echo inactive ;;
      *)                echo success ;;
    esac
  }
  # show -p ActiveState -p Result <unit>...: one block per unit, Result first
  # (as systemctl prints a service's own properties before its unit's)
  fake_show_blocks() {
    local unit sep='' state
    for unit in "$@"; do
      state=inactive
      [[ $unit != "$CREATE_UNIT" ]] || state=$(next_of create "${FAKE_CREATE:-inactive}")
      printf '%sResult=success\nActiveState=%s\n' "$sep" "$state"
      sep=$'\n'
    done
  }
  virsh() {
    tool virsh "$@"
    [[ $3 == domstate ]] || return 0
    local state
    state=$(next_of domstate "${FAKE_DOMSTATES:-absent}")
    if [[ $state == absent ]]; then echo "error: failed to get domain 'helios'" >&2; return 1; fi
    printf '%s\n\n' "$state"
  }
  getent() { tool getent "$@"; [[ -n ${FAKE_LEASE:-} ]] || return 2; printf '%s       helios\n' "$FAKE_LEASE"; }
  port22_open() { tool port22 "$1"; [[ ${FAKE_SSHD:-open} == open ]]; }
}

test_the_engvm_stage_clones_and_checks_out_the_pin_as_ubuntu_then_installs_the_sizing() {
  host_env
  fake_host_tools
  host_files
  stage_call stage_engvm "$CONF"
  assert_eq 0 "$RC" "the stage failed: $(cat "$SANDBOX/stage.out")"
  assert_eq "@8ef18ef · lab: $LAB_SIZING" "$SUMMARY" "progress_reply's engvm summary"
  local as="runuser -u ubuntu --" dir=$SANDBOX/root/home/ubuntu/helios-engvm
  assert_eq "$as git clone --quiet https://github.com/oxidecomputer/helios-engvm.git $dir
$as git -C $dir cat-file -e $PIN^{commit}
$as git -C $dir checkout --quiet --force --detach $PIN
$as git -C $dir rev-parse HEAD
install -o ubuntu -g ubuntu -m 0644 $SANDBOX/root/etc/helios-lab/engvm-lab.sh $dir/config/lab.sh" "$(tools_log)"
  assert_eq 0 "$(tools_log | grep -c '^git ' || true)" 'git only ever as ubuntu'
  : > "$SANDBOX/tools.log"
  FAKE_HAS_PIN=no stage_call stage_engvm "$CONF"   # an existing checkout without the pin: fetch, no clone
  assert_eq 0 "$RC"
  assert_eq "$as git -C $dir cat-file -e $PIN^{commit}
$as git -C $dir fetch --quiet origin
$as git -C $dir checkout --quiet --force --detach $PIN" "$(tools_log | sed -n 1,3p)"
  assert_not_contains "$(tools_log)" 'clone'
}

test_the_engvm_stage_fails_when_head_is_not_the_pin_or_the_directory_is_no_checkout() {
  host_env
  fake_host_tools
  host_files
  FAKE_HEAD=$OTHER_PIN stage_call stage_engvm "$CONF"
  assert_eq 1 "$RC"
  assert_eq "the checkout's HEAD is $OTHER_PIN, not the pin $PIN" "$SUMMARY"
  assert_not_contains "$(tools_log)" 'install '
  rm -rf "$ENGVM_DIR"
  mkdir -p "$ENGVM_DIR/input"
  : > "$SANDBOX/tools.log"
  stage_call stage_engvm "$CONF"
  assert_eq 1 "$RC"
  assert_contains "$SUMMARY" '/home/ubuntu/helios-engvm is not a git checkout: remove it'
  assert_eq '' "$(tools_log)" 'nothing cloned over it, nothing removed'
  [[ -d $ENGVM_DIR/input ]] || fail 'the directory, which may hold the seed, was removed'
}

test_the_seed_stage_runs_download_sh_as_ubuntu_under_its_timeout_and_names_one() {
  host_env
  fake_host_tools
  mkdir -p "$ENGVM_DIR/input"
  printf '#!/bin/sh\n' > "$ENGVM_DIR/download.sh"
  chmod +x "$ENGVM_DIR/download.sh"
  FAKE_TIMEOUT_RC=124 stage_call stage_seed
  assert_eq 1 "$RC"
  assert_eq "$SEED_TIMEOUT_REASON" "$SUMMARY" "progress_reply's seed-timeout reason"
  assert_contains "$SUMMARY" 'seed download timed out'
  assert_eq "timeout 1200 runuser -u ubuntu -- $ENGVM_DIR/download.sh" "$(tools_log)"
  FAKE_TIMEOUT_RC=1 stage_call stage_seed
  assert_eq 'download.sh failed (exit 1): see the journal' "$SUMMARY"
  stage_call stage_seed
  assert_eq 1 "$RC"
  assert_eq "download.sh finished, but /home/ubuntu/helios-engvm/input/helios-qemu-ttya-full.raw is missing" "$SUMMARY"
  : > "$ENGVM_DIR/input/helios-qemu-ttya-20260509.raw"
  ln -s helios-qemu-ttya-20260509.raw "$ENGVM_DIR/input/helios-qemu-ttya-full.raw"
  stage_call stage_seed
  assert_eq 0 "$RC"
  assert_eq "verified against engvm's pinned checksums" "$SUMMARY" "progress_reply's seed summary"
  check_seed || fail 'the live check misses the seed'
  rm "$ENGVM_DIR/download.sh"
  stage_call stage_seed
  assert_contains "$SUMMARY" 'download.sh is missing: the engvm stage has not run'
}

test_the_guest_stage_creates_an_unverified_guest_in_a_transient_unit_as_ubuntu() {
  host_env
  fake_host_tools
  host_files
  FAKE_DOMSTATES='absent|absent|running' FAKE_CREATE='inactive|active' stage_call stage_guest "$CONF"
  assert_eq 0 "$RC" "the stage failed: $(cat "$SANDBOX/stage.out")"
  assert_eq 'created · first boot under way' "$SUMMARY" "progress_reply's guest summary"
  local dir=$SANDBOX/root/home/ubuntu/helios-engvm log=$SANDBOX/root/var/log/helios-lab
  assert_eq "install -d -o ubuntu -g ubuntu -m 0755 $log
runuser -u ubuntu -- env LIBVIRT_DEFAULT_URI=qemu:///system $dir/destroy.sh lab
systemctl reset-failed helios-lab-create.service
systemd-run --quiet --uid=ubuntu --collect --unit=helios-lab-create -E LIBVIRT_DEFAULT_URI=qemu:///system -p WorkingDirectory=$dir /usr/bin/script -qfec ./create.sh lab $log/console.log
sleep 5" "$(actions)"
  assert_eq "$(guest_record "$PIN" "$LAB_SIZING")" "$(<"$SANDBOX/root/var/lib/helios-lab/guest.built")" 'what the guest is built from'
  [[ ! -e $SANDBOX/root/var/lib/helios-lab/guest-verified ]] || fail 'the host wrote guest-verified itself'
}

test_the_guest_stage_leaves_a_first_boot_under_its_create_unit_alone() {
  host_env
  fake_host_tools
  host_files
  FAKE_DOMSTATES='running' FAKE_CREATE='active' stage_call stage_guest "$CONF"
  assert_eq 0 "$RC"
  assert_eq 'first boot under way (its create unit is still running)' "$SUMMARY"
  assert_eq '' "$(actions)" 'no destroy, no create'
}

test_the_guest_stage_keeps_or_starts_a_verified_guest_and_never_recreates_it() {
  host_env
  fake_host_tools
  host_files
  mkdir -p "$SANDBOX/root/var/lib/helios-lab"
  guest_record "$PIN" "$LAB_SIZING" > "$SANDBOX/root/var/lib/helios-lab/guest-verified"
  FAKE_DOMSTATES=running stage_call stage_guest "$CONF"
  assert_eq 0 "$RC"
  assert_eq 'verified guest running' "$SUMMARY"
  assert_eq 'virsh -c qemu:///system autostart helios' "$(actions)"
  : > "$SANDBOX/tools.log"; rm -f "$SANDBOX"/next.*
  FAKE_DOMSTATES='shut off' stage_call stage_guest "$CONF"
  assert_eq 'verified guest started' "$SUMMARY"
  assert_eq $'virsh -c qemu:///system autostart helios\nvirsh -c qemu:///system start helios' "$(actions)"
  : > "$SANDBOX/tools.log"; rm -f "$SANDBOX"/next.*
  FAKE_DOMSTATES=absent stage_call stage_guest "$CONF"
  assert_eq 1 "$RC"
  assert_contains "$SUMMARY" 'guest-verified exists, but libvirt has no domain helios: to build a new guest, helios-lab ssh host sudo rm /var/lib/helios-lab/guest-verified'
  assert_eq '' "$(actions)" 'a lost verified guest is reported, never recreated'
}

test_a_pushed_sizing_or_pin_change_never_recreates_a_verified_guest() {
  host_env
  fake_host_tools
  host_files
  mkdir -p "$SANDBOX/root/var/lib/helios-lab"
  guest_record "$PIN" "$LAB_SIZING" > "$SANDBOX/root/var/lib/helios-lab/guest-verified"
  sed 's/^VCPU=3$/VCPU=4/' "$LAB_CONF" > "$SANDBOX/root/etc/helios-lab/engvm-lab.sh"
  FAKE_DOMSTATES=running stage_call stage_guest "$CONF"
  assert_eq 0 "$RC"
  assert_eq "verified guest running · built from engvm @8ef18ef, $LAB_SIZING, not the pushed @8ef18ef, 4 vCPU, 8 GiB, 60G: kept, only a re-create applies it" "$SUMMARY"
  assert_eq 'virsh -c qemu:///system autostart helios' "$(actions)" 'no destroy.sh, no create'
  assert_eq "$(guest_record "$PIN" "$LAB_SIZING")" "$(<"$SANDBOX/root/var/lib/helios-lab/guest-verified")" 'the marker is untouched'
  : > "$SANDBOX/tools.log"; rm -f "$SANDBOX"/next.*
  FAKE_DOMSTATES=running stage_call stage_guest "IDLE_MINUTES=60"$'\n'"ENGVM_PIN=$OTHER_PIN"
  assert_contains "$SUMMARY" 'not the pushed @0123456'
  assert_eq 'virsh -c qemu:///system autostart helios' "$(actions)"
}

test_a_create_that_ends_before_the_guest_runs_fails_with_the_transcripts_last_line() {
  host_env
  fake_host_tools
  host_files
  mkdir -p "$SANDBOX/root/var/log/helios-lab"
  printf '+ virsh desc helios\r\n\r\nVM helios exists already; run ./destroy.sh if you want to recreate\r\n' \
    > "$SANDBOX/root/var/log/helios-lab/console.log"
  FAKE_DOMSTATES=absent FAKE_CREATE='inactive|inactive' stage_call stage_guest "$CONF"
  assert_eq 1 "$RC"
  assert_eq 'create.sh ended before the guest ran: VM helios exists already; run ./destroy.sh if you want to recreate (transcript: /var/log/helios-lab/console.log)' "$SUMMARY"
}

test_guest_verified_promotes_the_create_record_frees_the_console_and_autostarts() {
  host_env
  fake_host_tools
  local lib=$SANDBOX/root/var/lib/helios-lab
  RC=0; ERR=$( (cmd_guest_verified) 2>&1 ) || RC=$?
  assert_eq 1 "$RC"
  assert_contains "$ERR" 'no guest create is recorded'
  [[ ! -e $lib/guest-verified ]] || fail 'marked a guest nobody created'
  mkdir -p "$lib"
  guest_record "$PIN" "$LAB_SIZING" > "$lib/guest.built"
  FAKE_CREATE=active cmd_guest_verified
  assert_eq "$(<"$lib/guest.built")" "$(<"$lib/guest-verified")"
  assert_eq $'systemctl stop helios-lab-create.service\nvirsh -c qemu:///system autostart helios' "$(actions)"
  : > "$SANDBOX/tools.log"; rm -f "$SANDBOX"/next.*
  FAKE_CREATE=inactive cmd_guest_verified   # its unit already gone
  assert_eq 'virsh -c qemu:///system autostart helios' "$(actions)"
}

test_guest_abandon_stops_only_an_unverified_first_boot() {
  host_env
  fake_host_tools
  FAKE_CREATE=active cmd_guest_abandon
  assert_eq 'systemctl stop helios-lab-create.service' "$(actions)"
  : > "$SANDBOX/tools.log"; rm -f "$SANDBOX"/next.*
  mkdir -p "$SANDBOX/root/var/lib/helios-lab"
  guest_record "$PIN" "$LAB_SIZING" > "$SANDBOX/root/var/lib/helios-lab/guest-verified"
  RC=0; ERR=$( (FAKE_CREATE=active cmd_guest_abandon) 2>&1 ) || RC=$?
  assert_eq 1 "$RC"
  assert_contains "$ERR" 'a verified guest is never abandoned'
  assert_eq '' "$(actions)"
}

# --- Host: the status reply --------------------------------------------------
test_the_helpers_status_reply_is_exactly_what_the_mac_parses() {
  local first verified
  # A first boot: its transcript as `script` records it (CRLF, escapes, a bell).
  first=$( host_env; fake_host_tools; host_files
           mkdir -p "$SANDBOX/root/var/log/helios-lab"
           printf '\e[1;1H\e[0mINFO ok, run complete\r\n\r\n\aHostname: helios\r\n' > "$SANDBOX/root/var/log/helios-lab/console.log"
           FAKE_DOMSTATES=running FAKE_CREATE=active FAKE_LEASE=$GUEST_IP FAKE_SSHD=open cmd_status )
  rm -rf "$SANDBOX/root" "$SANDBOX"/next.* "$SANDBOX/tools.log"
  verified=$( host_env; fake_host_tools; host_files
              mkdir -p "$SANDBOX/root/var/lib/helios-lab"
              guest_record "$PIN" "$LAB_SIZING" > "$SANDBOX/root/var/lib/helios-lab/guest-verified"
              FAKE_DOMSTATES=running FAKE_CREATE=inactive FAKE_LEASE=$GUEST_IP FAKE_SSHD=open cmd_status )
  guest_lines() { sed -n '/^verified /,$p'; }
  assert_eq "$(guest_status_reply first-boot | guest_lines)" "$(guest_lines <<< "$first")" 'first boot'
  assert_eq "$(guest_status_reply verified | guest_lines)" "$(guest_lines <<< "$verified")" 'verified'
  assert_eq 'unit inactive success' "$(sed -n 1p <<< "$first")" 'the progress part comes first'
  load_cli
  guest_ssh_ready "$first" || fail 'the Mac does not see the guest ready'
  assert_eq 'guest first boot' "$(guest_field "$first")"
  assert_eq 'Hostname: helios' "$(guest_wait_line "$first")"
  assert_eq yes "$(guest_verified_of "$verified")"
  assert_eq '' "$(guest_mismatch "$verified")"
}

test_the_helpers_status_only_reads() {
  local log
  log=$( host_env; fake_host_tools; host_files
         FAKE_DOMSTATES=running FAKE_CREATE=active FAKE_LEASE=$GUEST_IP cmd_status > /dev/null
         tools_log )
  assert_eq "systemctl show -p ActiveState -p Result helios-lab-provision.service helios-lab-idle.timer helios-lab-idle.service helios-lab-deadman.timer helios-lab-create.service
virsh -c qemu:///system domstate helios
getent hosts helios
port22 $GUEST_IP" "$log" 'one systemctl show for every unit fact'
}

test_one_systemctl_show_is_read_back_unit_by_unit() {
  host_env
  # Hand-written in the shape `systemctl show -p ActiveState -p Result a b`
  # prints: a block per unit, in the order asked, one blank line apart.
  local show=$'Result=success\nActiveState=active\n\nResult=exit-code\nActiveState=failed\n'
  assert_eq active "$(show_value "$show" 1 ActiveState)"
  assert_eq exit-code "$(show_value "$show" 2 Result)"
  assert_eq unknown "$(show_value "$show" 3 ActiveState)" 'no such block'
  assert_eq unknown "$(show_value '' 1 Result)" 'systemctl said nothing'
  assert_eq unknown "$(show_value $'ActiveState=\nResult=success' 1 ActiveState)" 'an empty value'
  assert_eq 1 "$(unit_place helios-lab-provision.service)"
  assert_eq 5 "$(unit_place helios-lab-create.service)"
  assert_eq 0 "$(unit_place sshd.service)"
}

test_the_status_reply_of_a_host_without_lease_or_domain() {
  local reply
  reply=$( host_env; fake_host_tools; host_files
           FAKE_DOMSTATES=absent FAKE_CREATE=inactive cmd_status )
  assert_eq "verified no
pushed $PIN $LAB_SIZING
domain absent
create inactive
lease none
sshd closed" "$(sed -n '/^verified /,$p' <<< "$reply")"
  assert_eq "$(guest_status_reply not-built | sed -n '/^verified /,$p')" "$(sed -n '/^verified /,$p' <<< "$reply")"
}

run_tests
