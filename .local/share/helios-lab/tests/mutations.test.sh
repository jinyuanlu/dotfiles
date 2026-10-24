#!/bin/bash
# shellcheck source-path=SCRIPTDIR
#
# mutations.test.sh — U6: up (create, start, wait paths), stop and destroy,
# with preflight, the lock, the lab key, security-group convergence, the
# user-data and the billing notice. CLI scenarios run the real entry against
# the aws and curl stubs; pure decisions are called directly after load_cli.
#
# Replies come from fixtures/derived/ (the CLI's text output for real U7
# captures, made by tests/derive-text) and are varied with set_field. The few
# hand-written replies are marked where they are built: errors no capture
# could provoke, `aws --version`, and one-ID-per-line lists.
#
# HOME is the sandbox's (tests/lib.sh), so the fixed lab-key path lives in it.
# Tests that need a key make one with an empty passphrase (lab_key below);
# none ever reaches ssh-keygen's passphrase prompt: stdin is /dev/null.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --- Fixtures ----------------------------------------------------------------
readonly RUNNING=$DERIVED/describe-instances.running.discover.txt
readonly STOPPED_IDLE=$DERIVED/describe-instances.stopped-idle.discover.txt
readonly STOPPED_USER=$DERIVED/describe-instances.stopped-user.discover.txt
readonly KEY_TAG=$DERIVED/describe-instances.running.key-tag.txt
readonly ROOT_VOLUMES=$DERIVED/describe-instances.running.root-volumes.txt
readonly CALLER=$DERIVED/sts-get-caller-identity.caller.txt
readonly VPC=$DERIVED/describe-vpcs.default.vpc.txt
readonly OFFERED_AZS=$DERIVED/describe-instance-type-offerings.azs.txt
readonly SUBNETS=$DERIVED/describe-subnets.default.subnets.txt
readonly GROUP_ID=$DERIVED/create-security-group.group-id.txt
readonly RULES_NEW=$DERIVED/describe-security-group-rules.after-create.rules.txt
readonly RULES_CONVERGED=$DERIVED/describe-security-group-rules.converged.rules.txt
readonly LAUNCHED=$DERIVED/run-instances.launched.txt
readonly STARTING=$DERIVED/start-instances.state.txt
readonly STOPPING=$DERIVED/stop-instances.state.txt
readonly TERMINATING=$DERIVED/terminate-instances.state.txt
readonly DRY_RUN_OK=$FIXTURES/run-instances.dry-run-ok
readonly SPIKE_USER_DATA=$FIXTURES/user-data.spike.yaml

readonly LAB_ID=i-0123456789abcdef0
readonly OTHER_ID=i-0fedcba9876543210   # a second synthetic instance, fixture style
readonly LAB_GROUP=sg-0123456789abcdef0
readonly LAB_VOL=vol-0123456789abcdef0
readonly LAB_SUBNET=subnet-0123456789abcdef0
readonly LAB_VPC=vpc-0123456789abcdef0
readonly FIXTURE_IP=203.0.113.10       # the instance's IP, and the converged /32
readonly OTHER_IP=198.51.100.7         # another Mac (documentation range)
readonly LAUNCH_EPOCH=1792839039       # 2026-10-24T10:50:39Z, the fixtures' LaunchTime
readonly AMI=resolve:ssm:/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id
readonly OTHER_FP=SHA256:kmYcvdi2GkPeWxB6XLjrZB8JHsy2Hm8luHMFp9GMvqk   # never a fresh test key's
readonly COST_LINE="account 123456789012 · m8i.xlarge · ap-northeast-1 · ≈\$0.27/hr running · ≈\$9.60/mo stopped · prices approximate, as of 2026-10-23"

# Hand-written: `aws --version` was not captured. The shape is awscli
# clidriver._cli_version's ("aws-cli/V Python/P System/R source/ARCH"); the
# spike ran 2.38.5.
cli_version_text() { echo "aws-cli/$1 Python/3.15.0 Darwin/25.5.0 source/arm64"; }

# aws_error <Code> <Operation> <message> — hand-written CLI v2 error output,
# for errors the spike could not provoke. The shape is the captured one in
# fixtures/run-instances.dry-run-ok.stderr: a blank line, then
# "aws: [ERROR]: An error occurred (Code) when calling the Op operation: msg".
aws_error() { printf '\naws: [ERROR]: An error occurred (%s) when calling the %s operation: %s' "$1" "$2" "$3"; }
capacity_error() {
  aws_error InsufficientInstanceCapacity "$1" "We currently do not have sufficient m8i.xlarge capacity in the Availability Zone you requested (ap-northeast-1a). Our system will be working on provisioning additional capacity. You can currently get m8i.xlarge capacity by not specifying an Availability Zone in your request or choosing ap-northeast-1c, ap-northeast-1d."
}
unauthorized_error() {
  aws_error UnauthorizedOperation RunInstances "You are not authorized to perform this operation. User: arn:aws:iam::123456789012:user/helios-lab is not authorized to perform: ec2:RunInstances on resource: arn:aws:ec2:ap-northeast-1:123456789012:instance/* because no identity-based policy allows the ec2:RunInstances action. Encoded authorization failure message: EXAMPLE"
}
dependency_error() {
  aws_error DependencyViolation DeleteSecurityGroup "resource $LAB_GROUP has a dependent object"
}

# --- Scenario builders -------------------------------------------------------
lab_key_path() { echo "$HOME/.ssh/helios-lab_ed25519"; }

# lab_key — a test lab key at the fixed path, without a passphrase
lab_key() {
  mkdir -p "$HOME/.ssh"
  ssh-keygen -q -t ed25519 -N '' -C helios-lab-test -f "$(lab_key_path)"
}
lab_fp() { ssh-keygen -lf "$(lab_key_path).pub" | awk '{ print $2 }'; }
lab_pub() { awk '{ print $1 " " $2 }' "$(lab_key_path).pub"; }

# fixture_error <name> <fixture-base> [n] — replay a captured failing call
fixture_error() {
  local name=$1${3:+.$3}
  cp "$2.stderr" "$STUB_AWS_DIR/$name.stderr"
  cp "$2.exit" "$STUB_AWS_DIR/$name.exit"
}

preflight_ok() {
  cli_version_text 2.38.5 | reply version
  reply sts-get-caller-identity "$CALLER"
  reply ec2-describe-vpcs "$VPC"
  reply ec2-describe-instance-type-offerings "$OFFERED_AZS"
  reply ec2-describe-subnets "$SUBNETS"
  fixture_error ec2-run-instances "$DRY_RUN_OK" 1   # call 1 is the dry-run
}

# sg_writes_ok — replies for every group mutation. There is no capture of
# revoke-security-group-ingress; its response has the egress one's shape.
sg_writes_ok() {
  reply ec2-revoke-security-group-egress "$DERIVED/revoke-security-group-egress.return.txt"
  reply ec2-revoke-security-group-ingress "$DERIVED/revoke-security-group-egress.return.txt"
  reply ec2-authorize-security-group-egress "$DERIVED/authorize-security-group-egress.return.txt"
  reply ec2-authorize-security-group-ingress "$DERIVED/authorize-security-group-ingress.return.txt"
}

# world_absent — no lab instance and no group: a full, successful create
world_absent() {
  lab_key
  reply_seq ec2-describe-instances 1 < /dev/null   # discovery: absent
  reply ec2-describe-instances "$RUNNING"           # the post-launch re-lookup
  preflight_ok
  reply ec2-describe-security-groups < /dev/null
  reply ec2-create-security-group "$GROUP_ID"
  reply ec2-describe-security-group-rules "$RULES_NEW"
  sg_writes_ok
  reply ec2-run-instances "$LAUNCHED"               # call 2: the launch
  reply ec2-wait < /dev/null
  caller_ip_is "$FIXTURE_IP"
}

# world_existing <discovery-row-file> — one lab instance whose KeyFingerprint
# tag is the test key's; a converged group; this Mac at the converged IP
world_existing() {
  lab_key
  reply_seq ec2-describe-instances 1 "$1"
  set_field 1 "$(lab_fp)" < "$KEY_TAG" | reply ec2-describe-instances.2
  reply ec2-describe-instances "$RUNNING"           # the re-lookup once running
  reply ec2-describe-security-group-rules "$RULES_CONVERGED"
  sg_writes_ok
  reply ec2-start-instances "$STARTING"
  reply ec2-stop-instances "$STOPPING"
  reply ec2-wait < /dev/null
  caller_ip_is "$FIXTURE_IP"
}

# world_destroy <discovery-row-file|""> <group-ids> — what destroy finds
world_destroy() {
  lab_key
  if [[ -n $1 ]]; then
    reply_seq ec2-describe-instances 1 "$1"
    reply_seq ec2-describe-instances 2 "$ROOT_VOLUMES"
  else
    reply ec2-describe-instances < /dev/null
  fi
  printf '%s' "$2" | reply ec2-describe-security-groups   # one ID per line, as in lifecycle.test.sh
  reply ec2-terminate-instances "$TERMINATING"
  reply ec2-wait < /dev/null
  reply ec2-delete-security-group "$DERIVED/delete-security-group.return.txt"
  reply ec2-describe-volumes < /dev/null
}

# numbered_rules — tab-separated Q_RULES rows on stdin, each given its own rule
# ID (the sanitizer gave every captured rule the same one)
numbered_rules() { awk -F'\t' -v OFS='\t' '{ $1 = sprintf("sgr-0123456789abcde%02d", NR); print }'; }
rule() { sed -n "${1}p" "$RULES_CONVERGED"; }   # 1: egress 80, 2: egress 443, 3: ingress 22 from FIXTURE_IP

# --- Log helpers -------------------------------------------------------------
calls() { cat "$STUB_LOG"; }
calls_of() { grep -E "^aws [a-z0-9-]+ $1( |$)" "$STUB_LOG" || true; }
count_of() { calls_of "$1" | grep -c . || true; }
launch_call() { calls_of run-instances | grep -v -- ' --dry-run ' || true; }
dry_run_call() { calls_of run-instances | grep -- ' --dry-run ' || true; }
line_of() { grep -nF -- "$1" "$STUB_LOG" | head -1 | cut -d: -f1; }

# assert_called_before <first> <second> — log order of two call substrings
assert_called_before() {
  local a b
  a=$(line_of "$1"); b=$(line_of "$2")
  if [[ -z $a || -z $b ]] || (( a >= b )); then fail "expected '$1' before '$2' in:" "$(calls)"; fi
}

# assert_no_mutation — no recorded operation carries a mutating verb (the
# preflight dry-run changes nothing, so it doesn't count)
assert_no_mutation() {
  local op
  while IFS= read -r op; do
    case $op in
      run-*|start-*|stop-*|terminate-*|create-*|authorize-*|revoke-*|modify-*|delete-*)
        fail "unexpected mutating call: $op" ;;
    esac
  done < <(grep -v -- ' --dry-run ' "$STUB_LOG" | awk '$1 == "aws" { print $3 }')
}

assert_no_lock() { [[ ! -e $HELIOS_LAB_STATE_DIR/lock ]] || fail 'the lock outlived the command'; }

# user_data_of <call line> -> the --user-data argument, newlines restored
user_data_of() {
  local rest=${1#* --user-data }
  rest=${rest%% --security-group-ids *}
  rest=${rest%% --dry-run *}
  printf '%s\n' "${rest//\\n/$'\n'}"
}

# --- up: create --------------------------------------------------------------
test_up_absent_creates_a_tagged_group_then_launches_the_lab_instance() {
  world_absent
  export TZ=Asia/Tokyo
  run_cli up
  assert_rc 0
  local fp tags launch
  fp=$(lab_fp)
  # The group: found by both tags and the name first, then created, tagged in the same call.
  assert_contains "$(calls)" 'aws ec2 describe-security-groups --filters Name=tag:Project,Values=helios-lab Name=tag:ManagedBy,Values=helios-lab-cli Name=group-name,Values=helios-lab'
  assert_contains "$(calls_of create-security-group)" "--group-name helios-lab --description helios-lab: ssh in from one /32, http and https out --vpc-id $LAB_VPC --tag-specifications ResourceType=security-group,Tags=[{Key=Project,Value=helios-lab},{Key=ManagedBy,Value=helios-lab-cli},{Key=Name,Value=helios-lab}] --query GroupId"
  assert_called_before 'ec2 create-security-group' "--security-group-ids $LAB_GROUP"
  # The launch, exactly once.
  assert_eq 1 "$(launch_call | grep -c .)" 'launch calls'
  launch=$(launch_call)
  tags="Tags=[{Key=Project,Value=helios-lab},{Key=ManagedBy,Value=helios-lab-cli},{Key=Name,Value=helios-lab},{Key=KeyFingerprint,Value=$fp}]"
  assert_contains "$launch" "aws ec2 run-instances --image-id $AMI --instance-type m8i.xlarge --subnet-id $LAB_SUBNET"
  assert_contains "$launch" ' --cpu-options NestedVirtualization=enabled '
  assert_contains "$launch" ' --metadata-options HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled '
  assert_contains "$launch" ' --instance-initiated-shutdown-behavior stop '
  assert_contains "$launch" ' --block-device-mappings [{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}] '
  assert_contains "$launch" " --tag-specifications ResourceType=instance,$tags ResourceType=volume,$tags "
  assert_contains "$launch" " --security-group-ids $LAB_GROUP --query Instances[0].[InstanceId,LaunchTime] --output text --profile helios-lab --region ap-northeast-1"
  assert_not_contains "$launch" 'iam-instance-profile'
  assert_contains "$(calls)" "aws ec2 wait instance-running --instance-ids $LAB_ID"
  # What the user sees.
  assert_line 1 "$COST_LINE"
  assert_line 2 'preflight ok · aws-cli 2.38.5 · zone ap-northeast-1a · RunInstances dry-run passed'
  assert_line 3 "security group $LAB_GROUP created"
  assert_line 6 "instance $LAB_ID launched in ap-northeast-1a · waiting for running"
  assert_contains "$(sed -n 7p <<< "$OUT")" "instance $LAB_ID running · "
  assert_line 8 "host running · $LAB_ID · $FIXTURE_IP · ≈\$0.27/hr · stops itself by about 21:51 (dead-man timer)"
  assert_line 9 'next: helios-lab stop pauses billing · host bootstrap (U2) and the Helios guest (U3) are not built yet'
  assert_no_lock
}

test_up_create_converges_a_new_groups_egress_to_exactly_tcp_80_and_443() {
  world_absent
  run_cli up
  assert_rc 0
  # after-create holds AWS's default allow-all egress rule: revoked by its ID ...
  assert_contains "$(calls_of revoke-security-group-egress)" "--group-id $LAB_GROUP --security-group-rule-ids sgr-0123456789abcdef0 --query Return"
  # ... and replaced by exactly the two rules, then ingress gets the caller's /32.
  assert_contains "$(calls_of authorize-security-group-egress)" "--group-id $LAB_GROUP --ip-permissions IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}] IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}] --query Return"
  assert_contains "$(calls_of authorize-security-group-ingress)" "--group-id $LAB_GROUP --ip-permissions IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$FIXTURE_IP/32}] --query Return"
  assert_eq 0 "$(count_of revoke-security-group-ingress)" 'nothing to revoke on ingress'
  assert_called_before 'revoke-security-group-egress' 'authorize-security-group-egress'
  assert_line 4 'egress: tcp 80/443 only (removed all-traffic 0.0.0.0/0)'
  assert_line 5 "ssh ingress: $FIXTURE_IP/32 only"
}

test_up_reuses_a_tagged_orphan_group_without_creating_another() {
  world_absent
  echo "$LAB_GROUP" | reply ec2-describe-security-groups   # one ID per line (no capture)
  reply ec2-describe-security-group-rules "$RULES_CONVERGED"
  run_cli up
  assert_rc 0
  assert_eq 0 "$(count_of create-security-group)" 'CreateSecurityGroup calls'
  assert_line 3 "security group $LAB_GROUP reused"
  assert_contains "$(launch_call)" " --security-group-ids $LAB_GROUP "
  # converged and this Mac's IP: no group writes, no group lines
  assert_eq 0 "$(calls | grep -cE '^aws ec2 (authorize|revoke)-' || true)" 'group writes'
  assert_not_contains "$OUT" 'ingress:'
  assert_not_contains "$OUT" 'egress:'
}

test_a_reused_groups_extra_egress_rule_is_revoked() {
  world_absent
  echo "$LAB_GROUP" | reply ec2-describe-security-groups
  { rule 1; rule 2; rule 1 | set_field 4 22 | set_field 5 22; rule 3; } | numbered_rules \
    | reply ec2-describe-security-group-rules   # plus egress tcp/22 to anywhere
  run_cli up
  assert_rc 0
  assert_contains "$(calls_of revoke-security-group-egress)" '--security-group-rule-ids sgr-0123456789abcde03 --query'
  assert_eq 0 "$(count_of authorize-security-group-egress)" 'tcp 80/443 were already there'
  assert_line 4 'egress: tcp 80/443 only (removed tcp/22 0.0.0.0/0)'
}

# shellcheck disable=SC2153  # Q_LAUNCHED comes from lib/aws.sh, through load_cli
test_dry_run_254_passes_and_is_the_launch_minus_group_and_key_material() {
  world_absent
  run_cli up
  assert_rc 0
  local dry launch
  dry=$(dry_run_call)
  launch=$(launch_call)
  assert_eq 1 "$(grep -c . <<< "$dry")" 'dry-run calls'
  assert_called_before ' --dry-run ' 'ec2 create-security-group'
  assert_not_contains "$dry" '--security-group-ids'
  assert_not_contains "$dry" "$(lab_fp)"
  load_cli
  # Swap the placeholder key material for the real key, drop the flag: what
  # remains must be the launch without its group and query.
  local fp pub flag extra
  fp=$(lab_fp)
  pub=$(lab_pub)
  flag=' --dry-run'
  extra=" --security-group-ids $LAB_GROUP --query $Q_LAUNCHED"
  dry=${dry//"$PLACEHOLDER_FP"/$fp}
  dry=${dry//"$PLACEHOLDER_PUBKEY"/$pub}
  dry=${dry/"$flag"/}
  launch=${launch/"$extra"/}
  assert_contains "$launch" "$fp"   # the swap must not be vacuous
  assert_eq "$launch" "$dry" 'dry-run vs launch'
}

test_old_cli_is_refused_before_any_preflight_call() {
  world_absent
  cli_version_text 2.30.0 | reply version
  run_cli up
  assert_rc 1
  assert_contains "$ERR" 'aws-cli 2.30.0 is too old: launching with nested virtualization needs 2.33.21 or later'
  assert_contains "$ERR" 'brew upgrade awscli'
  # Only discovery (to learn it is a create) precedes the version check.
  assert_eq $'aws ec2 describe-instances\naws --version' "$(cut -d' ' -f1-3 "$STUB_LOG")" 'calls'
  assert_eq '' "$OUT"
  assert_no_lock
}

test_root_credentials_are_refused_with_the_dedicated_identity_hint() {
  world_absent
  set_field 2 arn:aws:iam::123456789012:root < "$CALLER" | reply sts-get-caller-identity
  run_cli up
  assert_rc 3
  assert_contains "$ERR" "profile 'helios-lab' holds the account's root credentials (arn:aws:iam::123456789012:root); helios-lab refuses them"
  assert_contains "$ERR" 'use a dedicated IAM user or SSO identity with the shipped policy (iam-policy.json)'
  assert_eq 0 "$(count_of describe-vpcs)" 'no preflight call after the refusal'
  assert_no_mutation
}

test_dry_run_unauthorized_names_run_instances_and_the_policy_with_no_create_call() {
  world_absent
  reply_error_seq ec2-run-instances 1 254 "$(unauthorized_error)"
  run_cli up
  assert_rc 3
  assert_contains "$ERR" "profile 'helios-lab' may not launch the lab instance: the RunInstances dry-run was refused"
  assert_contains "$ERR" "attach the shipped least-privilege policy: $HELIOS_LAB_HOME/iam-policy.json"
  assert_contains "$ERR" 'aws said: aws: [ERROR]: An error occurred (UnauthorizedOperation) when calling the RunInstances operation'
  assert_line 1 "$COST_LINE"   # the cost line comes before the dry-run
  assert_eq 1 "$(count_of run-instances)" 'only the dry-run'
  assert_eq 0 "$(count_of create-security-group)" 'CreateSecurityGroup calls'
}

test_no_default_vpc_is_a_clear_error_with_no_create_call() {
  world_absent
  reply ec2-describe-vpcs < /dev/null   # an empty list prints nothing
  run_cli up
  assert_rc 1
  assert_contains "$ERR" 'no default VPC in ap-northeast-1: the lab launches into it'
  assert_contains "$ERR" 'aws ec2 create-default-vpc --profile helios-lab --region ap-northeast-1'
  assert_eq 0 "$(count_of run-instances)" 'no dry-run or launch'
  assert_no_mutation
}

test_no_default_subnet_in_an_offering_zone_exits_5_before_the_dry_run() {
  world_absent
  set_field 2 ap-northeast-1b < "$SUBNETS" | reply ec2-describe-subnets   # 1b doesn't offer it
  run_cli up
  assert_rc 5
  assert_contains "$ERR" "no default subnet of $LAB_VPC is in a zone that offers m8i.xlarge (offered in: ap-northeast-1d ap-northeast-1a ap-northeast-1c)"
  assert_contains "$(calls)" "aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=m8i.xlarge"
  assert_contains "$(calls)" "aws ec2 describe-subnets --filters Name=vpc-id,Values=$LAB_VPC Name=default-for-az,Values=true"
  assert_eq 0 "$(count_of run-instances)" 'no dry-run'
}

test_capacity_error_on_create_names_the_type_and_override_with_one_launch() {
  world_absent
  reply_error_seq ec2-run-instances 2 254 "$(capacity_error RunInstances)"
  run_cli up
  assert_rc 5
  assert_contains "$ERR" 'EC2 has no m8i.xlarge capacity in ap-northeast-1a right now; nothing was launched'
  assert_contains "$ERR" 'HELIOS_LAB_INSTANCE_TYPE=<type> helios-lab up'
  assert_eq 1 "$(launch_call | grep -c .)" 'a single launch attempt'
  assert_not_contains "$ERR" 'billing'   # EC2 refused: no host, no notice
  assert_not_contains "$ERR" 'in flight'
  assert_no_lock
}

test_a_type_too_small_for_the_guest_is_a_usage_error_at_create() {
  world_absent
  export HELIOS_LAB_INSTANCE_TYPE=m8i.large
  run_cli up
  assert_rc 2
  assert_contains "$ERR" 'HELIOS_LAB_INSTANCE_TYPE=m8i.large is too small: the guest alone takes 3 vCPU and 8 GiB'
  assert_eq 'aws ec2 describe-instances' "$(cut -d' ' -f1-3 "$STUB_LOG")" 'only discovery'
}

test_a_missing_lab_key_without_a_terminal_asks_for_one_and_creates_nothing() {
  world_absent
  rm -f "$(lab_key_path)" "$(lab_key_path).pub"
  run_cli up   # stdin is /dev/null
  assert_rc 2
  assert_contains "$ERR" "the lab key $(lab_key_path) does not exist yet, and creating it asks for a passphrase"
  assert_contains "$ERR" 'run helios-lab up in a terminal'
  [[ ! -e $(lab_key_path) ]] || fail 'a key was generated'
  assert_no_mutation
}

test_up_shutting_down_waits_for_terminated_then_creates() {
  world_absent
  set_field "$COL_STATE" shutting-down < "$RUNNING" | reply ec2-describe-instances.1
  run_cli up
  assert_rc 0
  assert_line 1 "waiting for $LAB_ID to finish terminating"
  assert_called_before "aws ec2 wait instance-terminated --instance-ids $LAB_ID" 'aws --version'
  assert_eq 1 "$(launch_call | grep -c .)" 'launch calls'
}

# --- up: existing instance ---------------------------------------------------
test_up_stopped_starts_only_and_says_billing_resumes() {
  world_existing "$STOPPED_IDLE"
  run_cli up
  assert_rc 0
  assert_contains "$OUT" "starting $LAB_ID · billing resumes at ≈\$0.27/hr"
  assert_eq "aws ec2 start-instances --instance-ids $LAB_ID --query StartingInstances[].[InstanceId,CurrentState.Name] --output text --profile helios-lab --region ap-northeast-1" \
    "$(calls_of start-instances)"
  assert_called_before 'ec2 start-instances' 'ec2 wait instance-running'
  assert_eq 0 "$(count_of run-instances)" 'no launch, no dry-run'
  assert_eq 0 "$(calls | grep -cE '^aws ec2 (create|authorize|revoke|modify|terminate)-' || true)" 'other writes'
  assert_eq 0 "$(grep -c -- '--version' "$STUB_LOG" || true)" 'no preflight off the create path'
  assert_contains "$(calls)" "aws ec2 describe-instances --instance-ids $LAB_ID --query Reservations[].Instances[].[Tags[?Key=='KeyFingerprint'].Value | [0]]"
  assert_no_lock
}

test_up_running_converged_makes_no_write_and_no_group_line() {
  world_existing "$RUNNING"
  export TZ=Asia/Tokyo
  run_cli up
  assert_rc 0
  assert_no_mutation
  assert_contains "$(calls)" "aws ec2 describe-security-group-rules --filters Name=group-id,Values=$LAB_GROUP --query SecurityGroupRules[].[SecurityGroupRuleId,IsEgress,IpProtocol,FromPort,ToPort,CidrIpv4]"
  assert_line 1 "host running · $LAB_ID · $FIXTURE_IP · ≈\$0.27/hr · stops itself by about 21:51 (dead-man timer)"
  assert_line 2 'next: helios-lab stop pauses billing · host bootstrap (U2) and the Helios guest (U3) are not built yet'
  assert_eq '' "$ERR"
}

test_ingress_for_another_ip_and_a_stray_rule_are_revoked_leaving_the_callers_32() {
  world_existing "$RUNNING"
  { rule 1; rule 2; rule 3 | set_field 6 "$OTHER_IP/32"; rule 3 | set_field 4 80 | set_field 5 80 | set_field 6 0.0.0.0/0; } \
    | numbered_rules | reply ec2-describe-security-group-rules
  run_cli up
  assert_rc 0
  assert_eq "aws ec2 revoke-security-group-ingress --group-id $LAB_GROUP --security-group-rule-ids sgr-0123456789abcde03 sgr-0123456789abcde04 --query Return --output text --profile helios-lab --region ap-northeast-1" \
    "$(calls_of revoke-security-group-ingress)"
  assert_contains "$(calls_of authorize-security-group-ingress)" "--ip-permissions IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$FIXTURE_IP/32}]"
  assert_called_before 'revoke-security-group-ingress' 'authorize-security-group-ingress'
  assert_eq 0 "$(calls | grep -cE '^aws ec2 [a-z]+-security-group-egress' || true)" 'egress was converged'
  assert_line 1 "ssh ingress: $FIXTURE_IP/32 only (removed tcp/22 $OTHER_IP/32, tcp/80 0.0.0.0/0)"
}

test_a_new_caller_ip_replaces_the_rule_with_one_line() {
  world_existing "$STOPPED_USER"
  caller_ip_is "$OTHER_IP"
  { rule 1; rule 2; rule 3; } | numbered_rules | reply ec2-describe-security-group-rules
  run_cli up
  assert_rc 0
  assert_contains "$(calls_of revoke-security-group-ingress)" '--security-group-rule-ids sgr-0123456789abcde03 --query'
  assert_contains "$(calls_of authorize-security-group-ingress)" "CidrIp=$OTHER_IP/32"
  assert_eq 1 "$(grep -c 'ingress' <<< "$OUT")" 'one ingress line'
  assert_line 1 "ssh ingress: $OTHER_IP/32 only (removed tcp/22 $FIXTURE_IP/32)"
  assert_called_before 'authorize-security-group-ingress' 'ec2 start-instances'
}

test_up_stopping_waits_for_stopped_then_starts() {
  world_existing "$STOPPED_USER"
  set_field "$COL_STATE" stopping < "$STOPPED_USER" | reply ec2-describe-instances.1
  run_cli up
  assert_rc 0
  assert_contains "$OUT" "waiting for $LAB_ID to finish stopping"
  assert_called_before "aws ec2 wait instance-stopped --instance-ids $LAB_ID" 'ec2 start-instances'
  assert_called_before 'ec2 start-instances' 'ec2 wait instance-running'
}

test_capacity_error_on_start_says_stopped_and_intact_without_a_type_hint() {
  world_existing "$STOPPED_IDLE"
  reply_error_seq ec2-start-instances 1 254 "$(aws_error InsufficientInstanceCapacity StartInstances 'Insufficient capacity.')"
  run_cli up
  assert_rc 5
  assert_contains "$ERR" "EC2 has no m8i.xlarge capacity in ap-northeast-1a right now; $LAB_ID is stopped and intact"
  assert_contains "$ERR" 'retry in a few minutes: helios-lab up'
  assert_not_contains "$ERR" 'HELIOS_LAB_INSTANCE_TYPE'
  assert_not_contains "$ERR" 'billing'
  assert_eq 1 "$(count_of start-instances)" 'one start attempt'
  assert_no_lock
}

test_a_type_override_on_an_existing_instance_warns_once_and_modifies_nothing() {
  world_existing "$STOPPED_IDLE"
  export HELIOS_LAB_INSTANCE_TYPE=m8i.2xlarge
  run_cli up
  assert_rc 0
  assert_eq "helios-lab: HELIOS_LAB_INSTANCE_TYPE=m8i.2xlarge applies only at create; $LAB_ID stays m8i.xlarge" "$ERR"
  assert_eq 0 "$(calls | grep -c '^aws ec2 modify-' || true)" 'modify calls'
  assert_eq 1 "$(count_of start-instances)" 'still starts'
}

test_a_missing_lab_key_with_an_instance_is_a_hard_failure_naming_destroy() {
  world_existing "$STOPPED_IDLE"
  rm -f "$(lab_key_path)" "$(lab_key_path).pub"
  run_cli up
  assert_rc 4
  assert_contains "$ERR" "the lab key $(lab_key_path) is missing, and lab instance $LAB_ID exists"
  assert_contains "$ERR" 'helios-lab destroy'
  assert_contains "$ERR" 'never regenerates it'
  [[ ! -e $(lab_key_path) ]] || fail 'a key was generated'
  assert_no_mutation
}

test_a_lab_key_that_is_not_the_instances_is_the_same_failure() {
  world_existing "$STOPPED_IDLE"
  local before tag
  before=$(lab_fp)
  for tag in "$OTHER_FP" None; do   # None: an instance without the tag (the captures have none)
    set_field 1 "$tag" < "$KEY_TAG" | reply ec2-describe-instances.2
    rm -rf "$STUB_AWS_DIR/.calls"
    run_cli up
    assert_rc 4
    assert_contains "$ERR" "the lab key $(lab_key_path) ($before) is not the key $LAB_ID was created with"
    assert_contains "$ERR" 'helios-lab destroy'
    assert_eq "$before" "$(lab_fp)" 'the key must never be regenerated'
  done
  assert_contains "$ERR" '(no KeyFingerprint tag)'
  assert_no_mutation
}

test_a_lost_public_half_says_how_to_rebuild_it() {
  world_existing "$STOPPED_IDLE"
  rm -f "$(lab_key_path).pub"
  run_cli up
  assert_rc 1
  assert_contains "$ERR" "rebuild it from the private key: ssh-keygen -y -f $(lab_key_path) > $(lab_key_path).pub"
  assert_no_mutation
}

test_an_unknown_caller_ip_stops_up_before_any_write() {
  world_existing "$STOPPED_IDLE"
  caller_ip_fails
  run_cli up
  assert_rc 8
  assert_contains "$ERR" "could not read this Mac's public IPv4 from https://checkip.amazonaws.com"
  assert_no_mutation
}

# --- up: after launch, the billing notice ------------------------------------
test_a_failed_step_after_launch_says_the_host_bills_and_when_it_stops() {
  world_absent
  export TZ=Asia/Tokyo
  load_cli
  # The U2 host-key step stands in here: fail it the way U2 will.
  # shellcheck disable=SC2329  # called by cmd_up
  up_connect() { die "$EX_HOSTKEY" 'host key mismatch: the host offered a key the console never printed'; }
  run_fn cmd_up
  assert_rc 6
  assert_contains "$ERR" "host $LAB_ID is running and billing (≈\$0.27/hr)"
  assert_contains "$ERR" 'it stops itself by about 21:51 (dead-man timer, 2h after boot)'
  assert_contains "$ERR" 'helios-lab up reattaches · helios-lab stop pauses it now'
  assert_no_lock
}

test_a_failed_wait_after_launch_prints_the_billing_notice() {
  world_absent
  export TZ=UTC
  # Hand-written: a waiter timeout (no capture).
  reply_error ec2-wait 255 $'\naws: [ERROR]: Waiter InstanceRunning failed: Max attempts exceeded'
  run_cli up
  assert_rc 1
  assert_contains "$ERR" 'ec2 wait failed'
  assert_contains "$ERR" "host $LAB_ID is running and billing"
  assert_contains "$ERR" 'it stops itself by about 12:51'
}

test_a_duplicate_found_after_launch_exits_4_with_the_notice() {
  world_absent
  { cat "$RUNNING"; set_field 1 "$OTHER_ID" < "$RUNNING"; } | reply ec2-describe-instances
  run_cli up
  assert_rc 4
  assert_contains "$ERR" "2 lab instances exist; at most one should: $LAB_ID (running), $OTHER_ID (running)"
  assert_contains "$ERR" "host $LAB_ID is running and billing"
}

test_ctrl_c_after_launch_prints_the_notice_and_releases_the_lock() {
  export TZ=UTC
  load_cli
  run_fn interrupted_after_launch
  assert_rc 130
  assert_contains "$ERR" "host $LAB_ID is running and billing (≈\$0.27/hr)"
  assert_contains "$ERR" 'it stops itself by about 12:51'
  assert_not_contains "$OUT" 'not interrupted'
  assert_no_lock
}

# interrupted_after_launch — take the lock, arm the notice as up does after a
# launch, then deliver SIGINT to this very subshell (bash 3.2 has no
# $BASHPID: an exec'd sh's parent is this shell)
interrupted_after_launch() {
  lock_acquire
  arm_notice "$LAB_ID" m8i.xlarge "$LAUNCH_EPOCH"
  # shellcheck disable=SC2016  # $PPID is the sh's own
  kill -INT "$(exec sh -c 'echo $PPID')"
  echo 'not interrupted'
}

test_notice_due_table() {
  load_cli
  local spec rc id want got
  for spec in "0|$LAB_ID|no" "1|$LAB_ID|yes" "4|$LAB_ID|yes" "6|$LAB_ID|yes" "130|$LAB_ID|yes" \
              "130||yes" "143||yes" "8||yes" "1||no" "3||no" "5||no" "0||no"; do
    IFS='|' read -r rc id want <<< "$spec"
    if notice_due "$rc" "$id"; then got=yes; else got=no; fi
    assert_eq "$want" "$got" "notice_due $rc '$id'"
  done
}

test_billing_notice_names_the_dead_man_time() {
  load_cli
  export TZ=UTC
  assert_eq "host $LAB_ID is running and billing (≈\$0.27/hr)
  it stops itself by about 12:51 (dead-man timer, 2h after boot)
  helios-lab up reattaches · helios-lab stop pauses it now" "$(billing_notice "$LAB_ID" m8i.xlarge "$LAUNCH_EPOCH")"
  assert_contains "$(billing_notice '' m8i.xlarge '')" 'a launch or start was in flight: helios-lab status shows whether the host is up'
  assert_eq $(( LAUNCH_EPOCH - 39 + 7260 )) "$(deadman_epoch "$LAUNCH_EPOCH")" 'rounded up to the minute'
  assert_eq 1792846200 "$(deadman_epoch 1792839000)" 'a whole minute stays'
  assert_eq "$LAUNCH_EPOCH" "$(launch_epoch 2026-10-24T10:50:39+00:00 0)"
  assert_eq 42 "$(launch_epoch garbage 42)" 'falls back to now'
}

# --- Lock --------------------------------------------------------------------
test_a_live_lock_holder_makes_up_stop_and_destroy_yes_refuse() {
  mkdir -p "$HELIOS_LAB_STATE_DIR"
  echo $$ > "$HELIOS_LAB_STATE_DIR/lock"   # this test process: alive
  local cmd
  for cmd in up stop 'destroy --yes'; do
    # shellcheck disable=SC2086  # split the destroy flag
    run_cli $cmd
    assert_rc 4
    assert_contains "$ERR" "another helios-lab up, stop or destroy is running (pid $$)"
  done
  assert_eq '' "$(calls)" 'refused before any AWS call'
  assert_eq "$$" "$(cat "$HELIOS_LAB_STATE_DIR/lock")" "another process's lock is never removed"
}

test_the_preview_takes_no_lock() {
  world_destroy "$STOPPED_USER" "$LAB_GROUP"
  mkdir -p "$HELIOS_LAB_STATE_DIR"
  echo $$ > "$HELIOS_LAB_STATE_DIR/lock"
  run_cli destroy
  assert_rc 2
  assert_contains "$OUT" 'destroy would delete:'
}

test_a_dead_holders_lock_is_taken_over_and_released() {
  no_lab
  mkdir -p "$HELIOS_LAB_STATE_DIR"
  local dead
  sleep 0 & dead=$!
  wait "$dead"
  echo "$dead" > "$HELIOS_LAB_STATE_DIR/lock"
  sleep 1.1   # shlock won't break a lock written in the current second
  run_cli stop
  assert_rc 0
  assert_eq 'absent · no lab instance · nothing to stop' "$OUT"
  assert_no_lock
}

no_lab() { reply ec2-describe-instances < /dev/null; }

# --- stop --------------------------------------------------------------------
test_stop_running_stops_waits_and_says_storage_continues() {
  world_existing "$RUNNING"
  reply ec2-describe-instances "$RUNNING"
  run_cli stop
  assert_rc 0
  assert_eq "aws ec2 stop-instances --instance-ids $LAB_ID --query StoppingInstances[].[InstanceId,CurrentState.Name] --output text --profile helios-lab --region ap-northeast-1" \
    "$(calls_of stop-instances)"
  assert_called_before 'ec2 stop-instances' "aws ec2 wait instance-stopped --instance-ids $LAB_ID"
  assert_line 1 "stopping $LAB_ID · waiting for stopped"
  assert_line 2 "stopped · disk intact · ≈\$9.60/mo storage continues"
  assert_eq 0 "$(count_of terminate-instances)" 'stop never terminates'
  assert_no_lock
}

test_stop_waits_a_pending_instance_into_running_first() {
  world_existing "$RUNNING"
  set_field "$COL_STATE" pending < "$RUNNING" | reply ec2-describe-instances.1
  run_cli stop
  assert_rc 0
  assert_called_before "aws ec2 wait instance-running --instance-ids $LAB_ID" 'ec2 stop-instances'
}

test_stop_with_nothing_to_stop_makes_no_call_beyond_discovery() {
  local spec file state want
  for spec in "$STOPPED_USER|stopped|already stopped · disk intact · ≈\$9.60/mo storage continues" \
              "$RUNNING|stopping|stopping $LAB_ID · waiting for stopped" \
              "$RUNNING|shutting-down|shutting-down · $LAB_ID is being terminated · nothing to stop" \
              "||absent · no lab instance · nothing to stop"; do
    IFS='|' read -r file state want <<< "$spec"
    rm -rf "${STUB_AWS_DIR:?}"/* "$STUB_AWS_DIR/.calls"
    reply ec2-wait < /dev/null
    if [[ -n $file ]]; then set_field "$COL_STATE" "$state" < "$file" | reply ec2-describe-instances; else no_lab; fi
    run_cli stop
    assert_rc 0
    assert_line 1 "$want"
  done
  assert_no_mutation
}

test_stop_action_covers_every_ec2_state() {
  load_cli
  local pair
  for pair in absent:absent pending:wait-then-stop running:stop stopping:wait stopped:already \
              shutting-down:terminating; do
    assert_eq "${pair#*:}" "$(stop_action "${pair%%:*}")" "stop_action ${pair%%:*}"
  done
  if stop_action terminated >/dev/null; then fail 'stop_action accepted terminated'; fi
}

# --- destroy -----------------------------------------------------------------
test_destroy_without_yes_previews_read_only_and_exits_2() {
  world_destroy "$STOPPED_USER" "$LAB_GROUP"
  run_cli destroy
  assert_rc 2
  assert_line 1 'destroy would delete:'
  assert_line 2 "  instance  $LAB_ID (stopped, m8i.xlarge)"
  assert_line 3 "  volume    $LAB_VOL (root disk, deleted with its instance)"
  assert_line 4 "  group     $LAB_GROUP (security group)"
  assert_line 5 '  guest disk and seed will be lost; rebuild ≈10 min + 2.4 GB download'
  assert_line 6 "kept: the lab key $(lab_key_path)"
  assert_line 7 'to delete exactly this: helios-lab destroy --yes'
  assert_contains "$(calls)" "aws ec2 describe-instances --instance-ids $LAB_ID --query Reservations[].Instances[].BlockDeviceMappings[].Ebs.[VolumeId,DeleteOnTermination]"
  assert_read_only
  assert_no_lock
}

test_destroy_yes_terminates_exactly_the_previewed_instance_then_cleans_up() {
  world_destroy "$STOPPED_USER" "$LAB_GROUP"
  run_cli destroy --yes
  assert_rc 0
  local previewed
  previewed=$(awk '$1 == "instance" { print $2 }' <<< "$OUT")
  assert_eq "$LAB_ID" "$previewed"
  assert_eq "aws ec2 terminate-instances --instance-ids $previewed --query TerminatingInstances[].[InstanceId,CurrentState.Name] --output text --profile helios-lab --region ap-northeast-1" \
    "$(calls_of terminate-instances)"
  assert_called_before 'ec2 terminate-instances' "aws ec2 wait instance-terminated --instance-ids $LAB_ID"
  assert_called_before 'wait instance-terminated' "aws ec2 wait volume-deleted --volume-ids $LAB_VOL"
  assert_called_before 'wait volume-deleted' "aws ec2 delete-security-group --group-id $LAB_GROUP"
  assert_called_before 'ec2 delete-security-group' 'aws ec2 describe-volumes --filters Name=tag:Project,Values=helios-lab Name=tag:ManagedBy,Values=helios-lab-cli --query Volumes[].[VolumeId]'
  assert_line 1 'destroying:'
  assert_contains "$OUT" "security group $LAB_GROUP deleted"
  assert_contains "$OUT" "destroyed · no lab instance, volume or security group remains · kept: the lab key $(lab_key_path)"
  [[ -f $(lab_key_path) && -f $(lab_key_path).pub ]] || fail 'destroy touched the lab key'
  assert_no_lock
}

test_destroy_yes_with_two_instances_terminates_both_as_previewed() {
  world_destroy '' "$LAB_GROUP"
  { cat "$STOPPED_USER"; set_field 1 "$OTHER_ID" < "$RUNNING"; } | reply ec2-describe-instances.1
  reply ec2-describe-instances.2 "$ROOT_VOLUMES"
  run_cli destroy --yes
  assert_rc 0
  assert_eq "$LAB_ID $OTHER_ID" "$(awk '$1 == "instance" { print $2 }' <<< "$OUT" | paste -sd' ' -)"
  assert_contains "$(calls_of terminate-instances)" "--instance-ids $LAB_ID $OTHER_ID --query"
  assert_eq 1 "$(count_of terminate-instances)" 'one terminate call'
}

test_destroy_yes_deletes_an_orphan_group_retrying_a_dependency_violation() {
  world_destroy '' "$LAB_GROUP"
  reply_error_seq ec2-delete-security-group 1 254 "$(dependency_error)"
  run_cli destroy --yes
  assert_rc 0
  assert_line 2 "  group     $LAB_GROUP (security group)"
  assert_not_contains "$OUT" 'guest disk'   # no instance, nothing of the guest to lose
  assert_eq 2 "$(count_of delete-security-group)" 'delete attempts'
  assert_contains "$OUT" "security group $LAB_GROUP still in use; retrying in 0s"
  assert_contains "$OUT" "security group $LAB_GROUP deleted"
  assert_eq 0 "$(count_of terminate-instances)" 'no instance to terminate'
  [[ -f $(lab_key_path) && -f $(lab_key_path).pub ]] || fail 'destroy touched the lab key'
}

test_destroy_gives_up_on_a_group_that_stays_in_use() {
  world_destroy '' "$LAB_GROUP"
  rm "$STUB_AWS_DIR/ec2-delete-security-group"
  reply_error ec2-delete-security-group 254 "$(dependency_error)"
  run_cli destroy --yes
  assert_rc 1
  assert_contains "$ERR" "security group $LAB_GROUP is still in use after 12 attempts (DependencyViolation)"
  assert_eq 12 "$(count_of delete-security-group)" 'bounded retries'
}

test_destroy_treats_an_already_deleted_group_as_deleted() {
  world_destroy '' "$LAB_GROUP"
  reply_error_seq ec2-delete-security-group 1 254 \
    "$(aws_error InvalidGroup.NotFound DeleteSecurityGroup "The security group '$LAB_GROUP' does not exist")"
  run_cli destroy --yes
  assert_rc 0
  assert_eq 1 "$(count_of delete-security-group)" 'no retry'
}

test_destroy_fails_loudly_when_a_tagged_volume_remains() {
  world_destroy "$STOPPED_USER" "$LAB_GROUP"
  echo "$LAB_VOL" | reply ec2-describe-volumes   # one ID per line (no capture)
  run_cli destroy --yes
  assert_rc 1
  assert_contains "$ERR" "lab-tagged volumes remain: $LAB_VOL"
  assert_contains "$ERR" 'EC2 console'
}

test_destroy_keeps_waiting_only_for_volumes_that_go_with_their_instance() {
  world_destroy "$STOPPED_USER" "$LAB_GROUP"
  set_field 2 False < "$ROOT_VOLUMES" | reply ec2-describe-instances.2
  run_cli destroy
  assert_rc 2
  assert_line 3 "  volume    $LAB_VOL (DeleteOnTermination is off: it survives; delete it in the EC2 console)"
  rm -rf "$STUB_AWS_DIR/.calls"
  run_cli destroy --yes
  assert_eq 0 "$(grep -c 'wait volume-deleted' "$STUB_LOG" || true)" 'no wait on a surviving volume'
}

test_destroy_with_nothing_says_so_and_exits_0() {
  world_destroy '' ''
  local args
  for args in '' --yes; do
    # shellcheck disable=SC2086  # '' means no argument
    run_cli destroy $args
    assert_rc 0
    assert_eq 'nothing to destroy · no lab instance or security group' "$OUT"
  done
  assert_no_mutation
}

test_destroy_rejects_any_argument_but_yes() {
  local args
  for args in --force '--yes --yes' -y; do
    # shellcheck disable=SC2086
    run_cli destroy $args
    assert_rc 2
    assert_contains "$ERR" 'destroy takes no argument but --yes'
  done
  run_cli up now
  assert_rc 2
  run_cli stop now
  assert_rc 2
  assert_eq '' "$(calls)"
}

# --- User-data and rendering -------------------------------------------------
test_user_data_is_the_spike_design_with_the_lab_key() {
  load_cli
  # The validated file differs only in its comments and the key (and the key's comment).
  local spike rendered
  spike=$(grep -v '^#' "$SPIKE_USER_DATA" | sed 's/ helios-lab-spike$/ helios-lab/')
  rendered=$(render_user_data "$PLACEHOLDER_PUBKEY whatever-comment" | grep -v '^#')
  assert_eq "$spike" "$rendered" 'user-data vs the spike'
  assert_eq '#cloud-config' "$(render_user_data "$PLACEHOLDER_PUBKEY" | head -1)"
}

test_user_data_carries_the_key_printer_and_dead_man_and_no_secret() {
  world_absent
  export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
    AWS_SESSION_TOKEN=FwoGZXIvYXdzEXAMPLESESSIONTOKEN
  run_cli up
  assert_rc 0
  local ud
  ud=$(user_data_of "$(launch_call)")
  assert_contains "$ud" $'ssh_authorized_keys:\n  - '"$(lab_pub) helios-lab"
  assert_contains "$ud" 'path: /etc/systemd/system/helios-lab-hostkeys.service'
  # shellcheck disable=SC2016  # the unit's own $f, verbatim
  assert_contains "$ud" 'echo "-----BEGIN HELIOS-LAB HOST KEYS-----"; for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$f"; done; echo "-----END HELIOS-LAB HOST KEYS-----"'
  assert_contains "$ud" $'[Timer]\n      OnBootSec=2h\n      Unit=helios-lab-deadman.service'
  assert_contains "$ud" 'ExecStart=/usr/bin/systemctl poweroff'
  assert_contains "$ud" '  - [systemctl, enable, --now, helios-lab-deadman.timer]'
  assert_contains "$ud" '  - [systemctl, enable, --now, helios-lab-hostkeys.service]'
  assert_not_contains "$ud" 'PRIVATE KEY'
  assert_not_contains "$ud" "$HOME"
  assert_not_contains "$ud" '/.ssh/'
  assert_not_contains "$ud" 'helios-lab-test'   # the key's own comment stays home
  [[ ! $ud =~ (AKIA|ASIA)[A-Z0-9]{16} ]] || fail 'an AWS access key ID reached the user-data'
  local secret
  for secret in "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$AWS_SESSION_TOKEN"; do
    assert_not_contains "$(calls)" "$secret"
  done
  (( $(printf '%s' "$ud" | wc -c) < 16384 )) || fail 'user-data is over its 16 KB limit'
}

test_render_user_data_accepts_only_an_ed25519_public_key() {
  load_cli
  local bad
  for bad in '' 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ test' "$(head -1 "$SPIKE_USER_DATA")" \
             '-----BEGIN OPENSSH PRIVATE KEY-----' "$PLACEHOLDER_PUBKEY"$'\nsecond line' \
             "${PLACEHOLDER_PUBKEY}A"; do
    if render_user_data "$bad" >/dev/null; then fail "rendered user-data for: $bad"; fi
  done
  assert_eq "$PLACEHOLDER_PUBKEY" "$(pubkey_material "$PLACEHOLDER_PUBKEY AKIAIOSFODNN7EXAMPLE")" 'the comment is dropped'
}

test_cli_arguments_render_as_the_spike_ran_them() {
  load_cli
  assert_eq 'ResourceType=volume,Tags=[{Key=Project,Value=helios-lab},{Key=KeyFingerprint,Value=SHA256:ab+/c}]' \
    "$(render_tag_spec volume Project=helios-lab KeyFingerprint=SHA256:ab+/c)"
  assert_eq "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$FIXTURE_IP/32}]" "$(render_tcp_perm 22 "$FIXTURE_IP/32")"
  assert_eq '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
    "$(render_root_device 100)"
}

# --- Security-group plans (pure) ---------------------------------------------
# apply_plan <egress|ingress> <plan> <rules> -> the rules after the plan's
# calls: a model of EC2 (revoke drops a rule by ID, authorize adds one)
apply_plan() {
  local dir=$1 plan=$2 verb arg rest id eg proto from to cidr
  while IFS=$US read -r id eg proto from to cidr; do
    [[ -n $id ]] || continue
    grep -q "^revoke $id " <<< "$plan" || printf '%s\n' "$id$US$eg$US$proto$US$from$US$to$US$cidr"
  done <<< "$3"
  while read -r verb arg rest; do
    [[ $verb == authorize ]] || continue
    case $dir in
      egress)  printf 'sgr-new-%s%sTrue%stcp%s%s%s%s%s0.0.0.0/0\n' "$arg" "$US" "$US" "$US" "$arg" "$US" "$arg" "$US" ;;
      ingress) printf 'sgr-new%sFalse%stcp%s22%s22%s%s\n' "$US" "$US" "$US" "$US" "$US" "$arg" ;;
    esac
  done <<< "$plan"
}

# rule_set <egress True|False> <rules> -> "proto from to cidr" per rule of that direction, sorted
rule_set() { awk -F"$US" -v e="$1" '$2 == e { print $3, $4, $5, $6 }' <<< "$2" | sort; }

test_sg_plans_reach_the_target_from_any_start_and_are_empty_there() {
  load_cli
  local start rules egress ingress after
  for start in after-create converged other-ip strays ipv6 empty all-traffic-in; do
    rules=$(sg_start "$start" | numbered_rules | tr '\t' "$US")
    egress=$(egress_plan "$rules")
    ingress=$(ingress_plan "$FIXTURE_IP" "$rules")
    after=$(apply_plan egress "$egress" "$rules")
    after=$(apply_plan ingress "$ingress" "$after")
    assert_eq $'tcp 443 443 0.0.0.0/0\ntcp 80 80 0.0.0.0/0' "$(rule_set True "$after")" "egress from $start"
    assert_eq "tcp 22 22 $FIXTURE_IP/32" "$(rule_set False "$after")" "ingress from $start"
    assert_eq '' "$(egress_plan "$after")$(ingress_plan "$FIXTURE_IP" "$after")" "a second plan from $start"
  done
  rules=$(sg_start converged | numbered_rules | tr '\t' "$US")
  assert_eq '' "$(egress_plan "$rules")$(ingress_plan "$FIXTURE_IP" "$rules")" 'converged is a fixed point'
}

# sg_start <name> — tab-separated Q_RULES rows for a starting group
sg_start() {
  case $1 in
    after-create)   cat "$RULES_NEW" ;;
    converged)      cat "$RULES_CONVERGED" ;;
    other-ip)       rule 1; rule 2; rule 3 | set_field 6 "$OTHER_IP/32" ;;
    strays)         cat "$RULES_NEW" "$RULES_CONVERGED"; rule 3 | set_field 4 0 | set_field 5 65535 ;;
    ipv6)           rule 1; rule 3 | set_field 6 None ;;
    empty)          : ;;
    all-traffic-in) set_field 2 False < "$RULES_NEW" ;;
  esac
}

test_sg_notes_say_what_changed_and_nothing_when_converged() {
  load_cli
  assert_eq '' "$(sg_note egress 'tcp 80/443 only' '')"
  assert_eq 'egress: tcp 80/443 only (removed all-traffic 0.0.0.0/0)' \
    "$(sg_note egress 'tcp 80/443 only' $'revoke sgr-1 all-traffic 0.0.0.0/0\nauthorize 80\nauthorize 443')"
  assert_eq "ssh ingress: $FIXTURE_IP/32 only" "$(sg_note 'ssh ingress' "$FIXTURE_IP/32 only" "authorize $FIXTURE_IP/32")"
  assert_eq 'tcp/8000-8080 a non-IPv4 source' "$(rule_text tcp 8000 8080 None)"
  assert_eq 'sgr-1 sgr-2' "$(plan_args revoke $'revoke sgr-1 x\nauthorize 80\nrevoke sgr-2 y')"
}

# --- Preflight and key verdicts (pure) ---------------------------------------
test_cli_version_parse_and_compare() {
  load_cli
  assert_eq 2.38.5 "$(cli_version_of "$(cli_version_text 2.38.5)")"
  assert_eq 2.33.21 "$(cli_version_of 'aws-cli/2.33.21 Python/3.13.1 Linux/6.8 exe/x86_64.ubuntu.24')"
  local bad v
  for bad in '' 'aws-cli/2.38' 'aws-cli/1.2.3.4 Python/3' 'command not found' 'Aws-cli/2.38.5'; do
    if cli_version_of "$bad" >/dev/null; then fail "parsed a version from '$bad'"; fi
  done
  for v in 2.33.21 2.33.22 2.34.0 2.38.5 2.100.0 3.0.0; do
    version_at_least "$v" 2.33.21 || fail "$v rejected"
  done
  for v in 2.33.20 2.30.0 2.9.99 1.99.99 2.3.210; do
    if version_at_least "$v" 2.33.21; then fail "$v accepted"; fi
  done
}

test_root_arn_detection() {
  load_cli
  is_root_arn arn:aws:iam::123456789012:root || fail 'missed root'
  is_root_arn arn:aws-cn:iam::123456789012:root || fail 'missed a China-partition root'
  local arn
  for arn in arn:aws:iam::123456789012:user/helios-lab arn:aws:iam::123456789012:user/root \
             arn:aws:sts::123456789012:assumed-role/lab/root arn:aws:iam::123456789012:rootx ''; do
    if is_root_arn "$arn"; then fail "flagged $arn as root"; fi
  done
  assert_eq "123456789012${US}arn:aws:iam::123456789012:user/helios-lab" "$(reply sts-get-caller-identity "$CALLER"; aws_caller)"
}

test_guest_sizing_table() {
  load_cli
  local t
  for t in m8i.xlarge c8i.2xlarge r8i.xlarge m8i-flex.xlarge c7i.48xlarge m7i.2xlarge; do
    guest_fits "$t" || fail "rejected $t"
  done
  for t in m8i.large c8i.xlarge r8i.large c8i-flex.large m7i.large c7i.xlarge; do
    if guest_fits "$t"; then fail "accepted $t"; fi
  done
  assert_eq 192 "$(type_vcpus m8i.48xlarge)"
  assert_eq 16 "$(type_mem_gib c8i.2xlarge)"
  assert_eq 16 "$(type_mem_gib r8i.large)"
  assert_eq 64 "$(type_mem_gib m8i.4xlarge)"
}

test_pick_subnet_prefers_the_first_offering_zone() {
  load_cli
  local azs subnet
  azs=$(reply ec2-describe-instance-type-offerings "$OFFERED_AZS"; aws_offered_azs m8i.xlarge)
  subnet=$(reply ec2-describe-subnets "$SUBNETS"; aws_default_subnets "$LAB_VPC")
  assert_eq "$LAB_SUBNET${US}ap-northeast-1a" "$(pick_subnet "$azs" "$subnet")"
  local mixed="subnet-b${US}ap-northeast-1b"$'\n'"subnet-d${US}ap-northeast-1d"$'\n'"subnet-c${US}ap-northeast-1c"
  assert_eq "subnet-c${US}ap-northeast-1c" "$(pick_subnet "$azs" "$mixed")"
  if pick_subnet "$azs" "subnet-b${US}ap-northeast-1b" >/dev/null; then fail 'picked a zone without the type'; fi
  if pick_subnet '' "$subnet" >/dev/null; then fail 'picked with no offering'; fi
  if pick_subnet "$azs" '' >/dev/null; then fail 'picked with no subnet'; fi
  if pick_subnet 'ap-northeast-1' "$subnet" >/dev/null; then fail 'a zone prefix matched'; fi
}

test_lab_key_fingerprint_and_verdict() {
  load_cli
  lab_key
  local fp
  fp=$(fingerprint_of "$(ssh-keygen -lf "$(lab_key_path).pub")")
  assert_eq "$(lab_fp)" "$fp"
  assert_eq "$fp" "$(lab_key_fingerprint)"
  if fingerprint_of 'garbage' >/dev/null; then fail 'parsed garbage'; fi
  if fingerprint_of '256 MD5:aa:bb helios-lab (ED25519)' >/dev/null; then fail 'parsed an MD5 fingerprint'; fi
  assert_eq ok "$(lab_key_verdict "$fp" "$fp")"
  assert_eq mismatch "$(lab_key_verdict "$fp" "$OTHER_FP")"
  assert_eq mismatch "$(lab_key_verdict "$fp" None)"
  assert_eq missing "$(lab_key_verdict '' "$fp")"
  assert_eq missing "$(lab_key_verdict '' None)"
  rm "$(lab_key_path)"
  assert_eq '' "$(lab_key_fingerprint)" 'half a key is no key'
}

test_aws_error_code_and_dry_run_outcome() {
  load_cli
  local captured
  captured=$(<"$DRY_RUN_OK.stderr")
  assert_eq DryRunOperation "$(aws_error_code "$captured")"
  assert_eq pass "$(dry_run_outcome "$(<"$DRY_RUN_OK.exit")" "$captured")"
  assert_eq denied "$(dry_run_outcome 254 "$(unauthorized_error)")"
  assert_eq fail "$(dry_run_outcome 0 '')"
  assert_eq fail "$(dry_run_outcome 255 "$captured")"
  assert_eq fail "$(dry_run_outcome 254 "$(aws_error InvalidParameterValue RunInstances 'bad')")"
  assert_eq InvalidGroup.NotFound "$(aws_error_code "$(aws_error InvalidGroup.NotFound DeleteSecurityGroup x)")"
  if aws_error_code 'Waiter InstanceRunning failed' >/dev/null; then fail 'found a code in a waiter error'; fi
}

test_costs_and_lifecycle_lines() {
  load_cli
  assert_eq "≈\$0.27/hr" "$(hourly_cost m8i.xlarge)"
  assert_eq "≈\$0.55/hr" "$(hourly_cost m8i.2xlarge)"
  assert_eq "≈\$0.47/hr" "$(hourly_cost c8i.2xlarge)"
  assert_eq 'no price for r8i.xlarge' "$(hourly_cost r8i.xlarge)"
  assert_eq "≈\$9.60/mo" "$(storage_month)"
  assert_eq "$COST_LINE" "$(cost_line 123456789012 m8i.xlarge ap-northeast-1)"
  assert_eq "stopped · disk intact · ≈\$9.60/mo storage continues" "$(stopped_line)"
  assert_eq '' "$(type_override_note '' m8i.xlarge "$LAB_ID")"
  assert_eq '' "$(type_override_note m8i.xlarge m8i.xlarge "$LAB_ID")"
  assert_eq 41s "$(fmt_elapsed 41)"
  assert_eq 2m05s "$(fmt_elapsed 125)"
}

# Pinned on purpose: change a query and this fails until its fixtures/derived
# reply is re-derived (fixtures/README.md lists which).
# shellcheck disable=SC2153  # Q_* come from lib/aws.sh, through load_cli
test_queries_are_pinned() {
  load_cli
  assert_eq "Reservations[].Instances[].[Tags[?Key=='KeyFingerprint'].Value | [0]]" "$Q_KEY_TAG"
  assert_eq 'Reservations[].Instances[].BlockDeviceMappings[].Ebs.[VolumeId,DeleteOnTermination]' "$Q_ROOT_VOLUMES"
  assert_eq 'Volumes[].[VolumeId]' "$Q_VOLUME_IDS"
  assert_eq '[Account,Arn]' "$Q_CALLER"
  assert_eq 'Vpcs[].[VpcId]' "$Q_VPC"
  assert_eq 'InstanceTypeOfferings[].[Location]' "$Q_OFFERED_AZS"
  assert_eq 'Subnets[].[SubnetId,AvailabilityZone]' "$Q_SUBNETS"
  assert_eq GroupId "$Q_GROUP_ID"
  assert_eq 'SecurityGroupRules[].[SecurityGroupRuleId,IsEgress,IpProtocol,FromPort,ToPort,CidrIpv4]' "$Q_RULES"
  assert_eq Return "$Q_RETURN"
  assert_eq 'Instances[0].[InstanceId,LaunchTime]' "$Q_LAUNCHED"
  assert_eq 'StartingInstances[].[InstanceId,CurrentState.Name]' "$Q_STARTING"
  assert_eq 'StoppingInstances[].[InstanceId,CurrentState.Name]' "$Q_STOPPING"
  assert_eq 'TerminatingInstances[].[InstanceId,CurrentState.Name]' "$Q_TERMINATING"
}

run_tests
