#!/bin/bash
# shellcheck source-path=SCRIPTDIR
#
# lifecycle.test.sh — U1: state -> action, discovery, stop cause, cost, status
# and help. Pure functions are called directly after load_cli; CLI scenarios
# run the real entry against the aws and curl stubs. Replies come from
# fixtures/derived/ (the CLI's text output for real captures) and are varied
# with set_field, never hand-written, except where noted.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly RUNNING=$DERIVED/describe-instances.running.discover.txt
readonly STOPPED_IDLE=$DERIVED/describe-instances.stopped-idle.discover.txt
readonly STOPPED_USER=$DERIVED/describe-instances.stopped-user.discover.txt
readonly INGRESS=$DERIVED/describe-security-group-rules.converged.ingress.txt
readonly LAB_ID=i-0123456789abcdef0
readonly OTHER_ID=i-0fedcba9876543210   # a second synthetic instance, fixture style
readonly LAB_GROUP=sg-0123456789abcdef0
readonly FIXTURE_IP=203.0.113.10       # the instance's IP and the converged /32
readonly STOP_EPOCH=1792839921         # 2026-10-24 11:05:21 GMT, stopped-user's stop

# --- Scenario helpers --------------------------------------------------------
# An empty list prints nothing in text output, so "absent" is an empty reply.
no_instances() { reply ec2-describe-instances < /dev/null; }
no_groups() { reply ec2-describe-security-groups < /dev/null; }
running_for() { set_field "$COL_LAUNCH" "$(iso_ago "$1")" < "$RUNNING" | reply ec2-describe-instances; }
allow_fixture_ip() { reply ec2-describe-security-group-rules "$INGRESS"; caller_ip_is "$FIXTURE_IP"; }
two_instances() { { cat "$RUNNING"; set_field 1 "$OTHER_ID" < "$STOPPED_USER"; } | reply ec2-describe-instances; }
calls() { cat "$STUB_LOG"; }

# --- State -> action ---------------------------------------------------------
test_up_action_covers_every_ec2_state() {
  load_cli
  local pair
  for pair in absent:create pending:none running:none stopping:wait-then-start \
              stopped:start shutting-down:wait-then-create; do
    assert_eq "${pair#*:}" "$(up_action "${pair%%:*}")" "up_action ${pair%%:*}"
  done
}

test_up_action_rejects_states_discovery_never_returns() {
  load_cli
  local state
  for state in terminated bogus ''; do
    if up_action "$state" >/dev/null; then fail "up_action accepted '$state'"; fi
  done
}

# --- Discovery ---------------------------------------------------------------
test_discovery_filters_on_both_tags_and_every_live_state() {
  load_cli
  reply ec2-describe-instances "$RUNNING"
  local row
  row=$(aws_discover_instances)
  assert_contains "$(calls)" 'aws ec2 describe-instances --filters Name=tag:Project,Values=helios-lab Name=tag:ManagedBy,Values=helios-lab-cli Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down'
  # Pinned on purpose: change Q_DISCOVER and this fails until fixtures/derived is re-derived.
  assert_contains "$(calls)" '--query Reservations[].Instances[].[InstanceId,State.Name,InstanceType,Placement.AvailabilityZone,PublicIpAddress,LaunchTime,SecurityGroups[0].GroupId,StateReason.Code,StateTransitionReason] --output text --profile helios-lab --region ap-northeast-1'
  assert_eq "$LAB_ID${US}running${US}m8i.xlarge${US}ap-northeast-1a${US}$FIXTURE_IP${US}2026-10-24T10:50:39+00:00${US}$LAB_GROUP${US}None${US}" "$row"
}

test_every_aws_call_uses_the_configured_profile_and_pinned_region() {
  export HELIOS_LAB_PROFILE=lab-other
  no_instances; no_groups
  run_status
  assert_rc 0
  local line n=0
  while IFS= read -r line; do
    n=$(( n + 1 ))
    assert_contains "$line" '--output text --profile lab-other --region ap-northeast-1'
  done < <(grep '^aws ' "$STUB_LOG")
  assert_eq 2 "$n" 'aws calls for an absent status'
}

test_discover_single_returns_the_one_row_or_nothing() {
  load_cli
  local row
  reply ec2-describe-instances "$RUNNING"
  row=$(discover_single)
  assert_eq "$LAB_ID" "${row%%"$US"*}"
  no_instances
  row=$(discover_single)
  assert_eq '' "$row"
}

test_single_instance_commands_refuse_duplicates_with_exit_4() {
  load_cli
  two_instances
  RC=0
  ERR=$( (discover_single) 2>&1 >/dev/null ) || RC=$?
  assert_eq 4 "$RC" 'exit status'
  assert_contains "$ERR" "2 lab instances exist; at most one should: $LAB_ID (running), $OTHER_ID (stopped)"
}

# --- status: absent and conflicts --------------------------------------------
test_status_absent_says_absent_and_exits_0() {
  no_instances; no_groups
  run_status
  assert_rc 0
  assert_eq 'absent · no lab instance · next: helios-lab up' "$OUT"
}

test_status_flags_an_orphaned_security_group_first() {
  no_instances
  # No describe-security-groups capture exists; Q_GROUP_IDS prints one GroupId per line.
  echo "$LAB_GROUP" | reply ec2-describe-security-groups
  run_status
  assert_rc 0
  assert_line 1 "! security group $LAB_GROUP exists with no instance: up reuses it, destroy --yes deletes it"
  assert_line 2 'absent · no lab instance · next: helios-lab up'
  assert_contains "$(calls)" 'aws ec2 describe-security-groups --filters Name=tag:Project,Values=helios-lab Name=tag:ManagedBy,Values=helios-lab-cli Name=group-name,Values=helios-lab --query SecurityGroups[].[GroupId]'
}

test_status_lists_both_duplicate_instances_and_exits_0() {
  two_instances
  run_status
  assert_rc 0
  assert_line 1 "! 2 lab instances exist; at most one should: $LAB_ID (running), $OTHER_ID (stopped). Terminate the extra one by hand"
  assert_line 2 'conflict · 2 instances · up, stop and ssh refuse until one remains'
}

# --- status: running ---------------------------------------------------------
test_status_running_shows_uptime_cost_autostop_then_details() {
  running_for 7805   # 2h10m05s: still 2h10m and ≈$0.59 after up to 29 s of test lag
  allow_fixture_ip
  run_status
  assert_rc 0
  assert_line 1 "running · up 2h10m (≈\$0.59) · auto-stops after 60 min idle"
  assert_line 2 "  instance  $LAB_ID"
  assert_line 3 '  zone      ap-northeast-1a'
  assert_line 4 '  type      m8i.xlarge'
  assert_line 5 "  ip        $FIXTURE_IP"
  assert_line 6 '  prices    approximate, as of 2026-10-23'
}

test_status_checks_the_caller_ip_over_https_ipv4_against_ingress() {
  running_for 60
  allow_fixture_ip
  run_status
  assert_rc 0
  assert_contains "$(calls)" 'curl -fsS -4 --proto =https --max-time 5 https://checkip.amazonaws.com'
  # Pinned on purpose, like Q_DISCOVER.
  assert_contains "$(calls)" "aws ec2 describe-security-group-rules --filters Name=group-id,Values=$LAB_GROUP --query SecurityGroupRules[?!IsEgress].[IpProtocol,FromPort,ToPort,CidrIpv4]"
  assert_not_contains "$OUT" '!'
}

test_status_flags_this_macs_ip_not_allowed_above_the_state_line() {
  running_for 60
  reply ec2-describe-security-group-rules "$INGRESS"   # admits only 203.0.113.10/32
  caller_ip_is 198.51.100.7
  run_status
  assert_rc 0
  assert_line 1 "! this Mac's IP (198.51.100.7) is not allowed in the security group: helios-lab up updates the rule"
  assert_above "this Mac's IP" 'running · up'
}

test_status_flags_an_unknown_caller_ip_when_checkip_fails_or_lies() {
  running_for 60
  caller_ip_fails
  run_status
  assert_rc 0
  assert_line 1 "! could not check this Mac's IP: checkip.amazonaws.com gave no IPv4 address"
  assert_above 'could not check' 'running · up'
  rm "$STUB_CURL_DIR/curl.exit"
  caller_ip_is '2001:db8::1'
  run_status
  assert_line 1 "! could not check this Mac's IP: checkip.amazonaws.com gave no IPv4 address"
  assert_not_contains "$(calls)" 'describe-security-group-rules'   # nothing to compare against
}

test_running_headline_for_2h10m_on_m8i_xlarge() {
  load_cli
  assert_eq "running · up 2h10m (≈\$0.59) · auto-stops after 60 min idle" \
    "$(status_headline running m8i.xlarge 7800 '' '' "$(autostop_field 60)")"
  # The extension points reproduce the plan's full line once U3/U4 fill them.
  assert_eq "running · guest ready · up 2h10m (≈\$0.59) · auto-stops in ~42 min" \
    "$(status_headline running m8i.xlarge 7800 '' 'guest ready' 'auto-stops in ~42 min')"
  assert_eq "running · uptime unknown · auto-stops after 60 min idle" \
    "$(status_headline running m8i.xlarge '' '' '' "$(autostop_field 60)")"
}

# --- status: stopped and transitional states ---------------------------------
test_stop_cause_for_an_idle_stop_has_no_time() {
  load_cli
  reply ec2-describe-instances "$STOPPED_IDLE"
  local id state type az ip launch group code reason
  IFS=$US read -r id state type az ip launch group code reason <<< "$(aws_discover_instances)"
  assert_eq Client.InstanceInitiatedShutdown "$code"
  assert_eq 'User initiated' "$reason"   # EC2 records no time for this case
  assert_eq 'stopped by idle timer' "$(stop_cause "$code" "$reason")"
}

test_stop_cause_for_a_manual_stop_shows_local_time() {
  load_cli
  reply ec2-describe-instances "$STOPPED_USER"
  local id state type az ip launch group code reason
  IFS=$US read -r id state type az ip launch group code reason <<< "$(aws_discover_instances)"
  assert_eq Client.UserInitiatedShutdown "$code"
  export TZ=Asia/Tokyo
  assert_eq 'stopped by you 20:05' "$(stop_cause "$code" "$reason")"
  export TZ=UTC
  assert_eq 'stopped by you 11:05' "$(stop_cause "$code" "$reason")"
  assert_eq 'stopped by you' "$(stop_cause "$code" 'User initiated')"
  assert_eq 'stopped (Server.InsufficientInstanceCapacity)' "$(stop_cause Server.InsufficientInstanceCapacity '')"
  assert_eq stopped "$(stop_cause None '')"
}

test_status_stopped_by_idle_timer() {
  reply ec2-describe-instances "$STOPPED_IDLE"
  run_status
  assert_rc 0
  assert_line 1 "stopped by idle timer · ≈\$0.32/day"
  assert_not_contains "$OUT" '  ip '
  assert_not_contains "$(calls)" curl   # a stopped host isn't connectable: no IP check
}

test_status_stopped_by_you_shows_the_local_stop_time() {
  export TZ=Asia/Tokyo
  reply ec2-describe-instances "$STOPPED_USER"
  run_status
  assert_rc 0
  assert_line 1 "stopped by you 20:05 · ≈\$0.32/day"
}

test_stopped_headline_matches_the_plan_with_the_guest_field() {
  load_cli
  assert_eq "stopped by idle timer · guest intact · ≈\$0.32/day" \
    "$(status_headline stopped m8i.xlarge '' 'stopped by idle timer' 'guest intact')"
}

test_status_headline_for_transitional_states() {
  local pair
  for pair in 'pending|pending · starting' 'stopping|stopping · disk kept' \
              'shutting-down|shutting-down · terminating'; do
    set_field "$COL_STATE" "${pair%%|*}" < "$RUNNING" | reply ec2-describe-instances
    run_status
    assert_rc 0
    assert_line 1 "${pair#*|}"
  done
}

test_status_flags_a_manual_stop_stuck_in_stopping() {
  set_field "$COL_STATE" stopping < "$STOPPED_USER" \
    | set_field "$COL_REASON" "$(gmt_ago 900)" | reply ec2-describe-instances
  run_status
  assert_rc 0
  assert_line 1 '! stopping for 15m (usually under 2 min): check the instance in the EC2 console'
  assert_line 2 'stopping · disk kept'
}

test_status_does_not_flag_a_fresh_or_untimed_stopping() {
  set_field "$COL_STATE" stopping < "$STOPPED_USER" \
    | set_field "$COL_REASON" "$(gmt_ago 60)" | reply ec2-describe-instances
  run_status
  assert_line 1 'stopping · disk kept'
  set_field "$COL_STATE" stopping < "$STOPPED_IDLE" | reply ec2-describe-instances
  run_status
  assert_line 1 'stopping · disk kept'
}

test_stuck_for_needs_a_timestamp_and_ten_minutes() {
  load_cli
  local reason='User initiated (2026-10-24 11:05:21 GMT)'
  assert_eq 15m "$(stuck_for "$reason" $(( STOP_EPOCH + 900 )))"
  if stuck_for "$reason" $(( STOP_EPOCH + 600 )) >/dev/null; then fail 'flagged at exactly 10 min'; fi
  if stuck_for 'User initiated' $(( STOP_EPOCH + 99999 )) >/dev/null; then fail 'flagged without a time'; fi
}

# --- Validation and usage ----------------------------------------------------
test_bad_instance_type_is_a_usage_error_naming_the_families() {
  export HELIOS_LAB_INSTANCE_TYPE=t3.large
  local cmd
  for cmd in status up; do
    run_cli "$cmd"
    assert_rc 2
    assert_contains "$ERR" 'HELIOS_LAB_INSTANCE_TYPE=t3.large does not support nested virtualization'
    assert_contains "$ERR" 'c8i m8i r8i c8i-flex m8i-flex r8i-flex c7i m7i r7i'
  done
  assert_eq '' "$(calls)" 'validation must precede every AWS call'
}

test_instance_type_validation_table() {
  load_cli
  local t
  for t in m8i.xlarge m8i.2xlarge c8i.2xlarge r8i.large m8i-flex.xlarge c8i-flex.16xlarge \
           c7i.48xlarge m7i.4xlarge r7i.24xlarge c8i.96xlarge; do
    instance_type_ok "$t" || fail "rejected $t"
  done
  # m7i-flex: the plan names -flex only for the 8i families (see the U1 report).
  for t in t3.large m8i.metal-48xl m8i m8i. .xlarge m8g.xlarge c6i.xlarge m8i.xlarge.x \
           'm8i .xlarge' '' m7i-flex.large M8I.XLARGE 'm8i.*'; do
    if instance_type_ok "$t"; then fail "accepted '$t'"; fi
  done
}

test_bad_idle_minutes_is_a_usage_error() {
  local v
  for v in 0 7 abc 725 -5 060 99999999999999999999; do
    export HELIOS_LAB_IDLE_MINUTES=$v
    run_cli status
    assert_rc 2
    assert_contains "$ERR" "HELIOS_LAB_IDLE_MINUTES=$v is not a multiple of 5 between 5 and 720"
  done
  assert_eq '' "$(calls)"
}

test_help_lists_every_command_and_env_var_on_one_screen() {
  run_cli help
  assert_rc 0
  local item
  for item in '  up ' '  stop ' '  status ' '  ssh [guest|host] [cmd]' '  console ' \
              '  keep <duration>|off' '  destroy [--yes]' '  runbook ' '  help ' \
              HELIOS_LAB_PROFILE HELIOS_LAB_INSTANCE_TYPE HELIOS_LAB_IDLE_MINUTES; do
    assert_contains "$OUT" "$item"
  done
  (( $(wc -l <<< "$OUT") <= 24 )) || fail 'help is longer than one screen'
  assert_eq '' "$(calls)"
}

test_help_works_even_with_a_bad_knob() {
  export HELIOS_LAB_INSTANCE_TYPE=t3.large
  run_cli --help
  assert_rc 0
  assert_contains "$OUT" 'commands:'
}

test_no_command_prints_help_to_stderr_and_exits_2() {
  run_cli
  assert_rc 2
  assert_eq '' "$OUT"
  assert_contains "$ERR" 'usage: helios-lab <command>'
}

test_unknown_command_and_status_arguments_are_usage_errors() {
  run_cli frobnicate
  assert_rc 2
  assert_contains "$ERR" 'unknown command: frobnicate'
  run_cli status --verbose
  assert_rc 2
  assert_contains "$ERR" 'status takes no arguments'
  assert_eq '' "$(calls)"
}

test_unimplemented_commands_exit_1_naming_their_unit() {
  local pair
  for pair in up:U6 stop:U6 destroy:U6 ssh:U3 console:U3 keep:U4 runbook:U5; do
    run_cli "${pair%%:*}"
    assert_rc 1
    assert_contains "$ERR" "${pair%%:*}: not implemented yet (${pair#*:})"
  done
  assert_eq '' "$(calls)"
}

test_aws_errors_map_to_typed_exit_codes_with_a_hint() {
  local spec rc text hint
  for spec in \
    "3|The config profile (helios-lab) could not be found|aws configure --profile helios-lab" \
    "3|Unable to locate credentials. You can configure credentials by running \"aws configure\".|aws configure --profile helios-lab" \
    "3|Error when retrieving token from sso: Token has expired and refresh failed|aws sso login --profile helios-lab" \
    "3|An error occurred (UnauthorizedOperation) when calling the DescribeInstances operation: You are not authorized to perform this operation.|iam-policy.json" \
    "8|Could not connect to the endpoint URL: \"https://ec2.ap-northeast-1.amazonaws.com/\"|check this Mac's network" \
    "1|An error occurred (InternalError) when calling the DescribeInstances operation (reached max retries: 2): An internal error has occurred|ec2 describe-instances failed"; do
    IFS='|' read -r rc text hint <<< "$spec"
    reply_error ec2-describe-instances 254 $'\n'"aws: [ERROR]: $text"
    run_cli status
    assert_rc "$rc"
    assert_contains "$ERR" "$hint"
    assert_contains "$ERR" "aws said: aws: [ERROR]: $text"
  done
}

# --- Pure helpers ------------------------------------------------------------
test_fmt_duration_table() {
  load_cli
  local pair
  for pair in 0:0m 59:0m 2520:42m 7500:2h05m 7800:2h10m 86399:23h59m 90000:1d01h; do
    assert_eq "${pair#*:}" "$(fmt_duration "${pair%%:*}")" "fmt_duration ${pair%%:*}"
  done
}

test_cost_rounds_to_the_cent_and_storage_is_32_cents_a_day() {
  load_cli
  assert_eq "≈\$0.59" "$(running_cost m8i.xlarge 7800)"
  assert_eq "≈\$0.27" "$(running_cost m8i.xlarge 3600)"
  assert_eq "≈\$0.55" "$(running_cost m8i.2xlarge 3600)"
  assert_eq "≈\$0.47" "$(running_cost c8i.2xlarge 3600)"
  assert_eq 'no price for r8i.large' "$(running_cost r8i.large 3600)"
  assert_eq 32 "$(storage_day_cents)"
  assert_eq "\$9.60" "$(fmt_cents 960)"
  assert_eq "\$0.05" "$(fmt_cents 5)"
}

test_timestamps_parse_as_utc() {
  load_cli
  assert_eq 0 "$(utc_epoch 1970 01 01 00 00 00)"
  assert_eq 951868800 "$(utc_epoch 2000 03 01 00 00 00)"
  assert_eq 1709208000 "$(utc_epoch 2024 02 29 12 00 00)"
  assert_eq 1792839039 "$(iso_epoch 2026-10-24T10:50:39+00:00)"   # running's LaunchTime
  assert_eq 1792839039 "$(iso_epoch 2026-10-24T10:50:39.000Z)"    # cli_timestamp_format=wire
  if iso_epoch 2026-10-24T10:50:39+09:00 >/dev/null; then fail 'accepted a non-UTC offset'; fi
  assert_eq "$STOP_EPOCH" "$(reason_epoch 'User initiated (2026-10-24 11:05:21 GMT)')"
  if reason_epoch 'User initiated' >/dev/null; then fail 'found a time in a bare reason'; fi
  assert_eq '' "$(uptime_s garbage 100)"
  assert_eq 0 "$(uptime_s 2026-10-24T10:50:39+00:00 1792839000)"   # clock skew clamps
}

test_is_ipv4_is_strict() {
  load_cli
  local ip
  for ip in 203.0.113.10 198.51.100.7 0.0.0.0 255.255.255.255; do
    is_ipv4 "$ip" || fail "rejected $ip"
  done
  for ip in 256.1.1.1 1.2.3 1.2.3.4.5 01.2.3.4 '1.2.3.4 ' ' 1.2.3.4' 2001:db8::1 \
            '<html>' '' 1.2.3.4/32 1..3.4 $'1.2.3.4\r'; do
    if is_ipv4 "$ip"; then fail "accepted '$ip'"; fi
  done
}

test_ingress_allows_only_the_exact_caller_32_on_tcp_22() {
  load_cli
  reply ec2-describe-security-group-rules "$INGRESS"
  local rules
  rules=$(aws_ingress_rules "$LAB_GROUP")
  ingress_allows "$FIXTURE_IP" "$rules" || fail 'rejected the converged /32'
  if ingress_allows 203.0.113.1 "$rules"; then fail 'prefix of the /32 accepted'; fi
  if ingress_allows 198.51.100.7 "$rules"; then fail 'another IP accepted'; fi
  if ingress_allows "$FIXTURE_IP" ''; then fail 'no rules accepted'; fi
  rules_with 4 0.0.0.0/0
  if ingress_allows "$FIXTURE_IP" "$RULES"; then fail 'a non-/32 rule counted as this Mac'; fi
  rules_with 2 80 3 80
  if ingress_allows "$FIXTURE_IP" "$RULES"; then fail 'tcp/80 counted as ssh'; fi
  rules_with 2 0 3 65535
  ingress_allows "$FIXTURE_IP" "$RULES" || fail 'tcp 0-65535 should admit 22'
  rules_with 1 -1 2 -1 3 -1   # all traffic, shaped like after-create's rule
  ingress_allows "$FIXTURE_IP" "$RULES" || fail 'an all-traffic rule should admit 22'
  rules_with 2 None 3 None
  if ingress_allows "$FIXTURE_IP" "$RULES"; then fail 'tcp with no ports accepted'; fi
}

# rules_with <col> <value> [<col> <value>...] — the converged ingress rule with
# those columns changed, read back through the real boundary; sets RULES
rules_with() {
  local f=$SANDBOX/rules.txt
  cp "$INGRESS" "$f"
  while (( $# >= 2 )); do
    set_field "$1" "$2" < "$f" > "$f.new"
    mv "$f.new" "$f"
    shift 2
  done
  reply ec2-describe-security-group-rules "$f"
  RULES=$(aws_ingress_rules "$LAB_GROUP")
}

# --- The harness itself ------------------------------------------------------
test_stub_enforces_the_call_contract() {
  local rc
  rc=0; aws ec2 describe-instances --output text --profile p 2>/dev/null || rc=$?
  assert_eq 98 "$rc" 'missing --region'
  rc=0; aws ec2 describe-instances --output text --region ap-northeast-1 2>/dev/null || rc=$?
  assert_eq 98 "$rc" 'missing --profile'
  rc=0; aws ec2 describe-instances --profile p --region ap-northeast-1 2>/dev/null || rc=$?
  assert_eq 98 "$rc" 'missing --output text'
  rc=0; aws --profile p ec2 describe-instances --output text --region ap-northeast-1 2>/dev/null || rc=$?
  assert_eq 98 "$rc" 'global option before the service'
  rc=0; aws ec2 describe-vpcs --output text --profile p --region ap-northeast-1 2>/dev/null || rc=$?
  assert_eq 97 "$rc" 'a call with no reply'
}

test_stub_replays_call_sequences_then_falls_back() {
  echo first > "$STUB_AWS_DIR/ec2-describe-instances.1"
  echo 5 > "$STUB_AWS_DIR/ec2-describe-instances.2.exit"
  echo boom > "$STUB_AWS_DIR/ec2-describe-instances.2.stderr"
  echo rest > "$STUB_AWS_DIR/ec2-describe-instances"
  local args=(ec2 describe-instances --output text --profile p --region ap-northeast-1) rc out
  assert_eq first "$(aws "${args[@]}")"
  rc=0; out=$(aws "${args[@]}" 2>&1) || rc=$?
  assert_eq '5 boom' "$rc $out"
  assert_eq rest "$(aws "${args[@]}")"
  assert_eq rest "$(aws "${args[@]}")"
  assert_eq 4 "$(grep -c '^aws ec2 describe-instances' "$STUB_LOG")"
}

test_read_only_check_catches_a_mutating_call() {
  echo "aws ec2 stop-instances --instance-ids $LAB_ID --output text" >> "$STUB_LOG"
  if (assert_read_only) 2>/dev/null; then fail 'assert_read_only missed stop-instances'; fi
}

run_tests
