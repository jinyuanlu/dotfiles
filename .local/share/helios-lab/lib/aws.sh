# shellcheck shell=bash
#
# helios-lab aws.sh — the only module that talks to AWS (and to checkip).
# U1: read-only discovery. U6: preflight, the security group, launch, start,
# stop, terminate and the waits. U2: the console read that host-key
# verification compares against (remote.sh). Decisions stay pure in state.sh and
# render.sh; this file only turns them into calls.
#
# Call contract (tests/stubs/aws enforces it, exit 98 otherwise):
#   aws <service> <operation> [args...] --output text --profile P --region ap-northeast-1
# - Service and operation come first, so the stub names its reply without
#   parsing global options.
# - --output text always: the user's profile may default to json, yaml or
#   table, and every parser here expects text. Output is shaped with
#   --query (JMESPath), never jq.
# - --region is pinned on every call: a second region would break "at most
#   one lab instance". --profile is always the configured one.
# The one exception is `aws --version`, which reads no profile or region.
#
# Requires from the entry: PROFILE, HELIOS_LAB_HOME, die, attempt, EX_*.

readonly REGION=ap-northeast-1
readonly TAG_PROJECT=helios-lab
readonly TAG_MANAGED_BY=helios-lab-cli
readonly TAG_NAME=helios-lab
readonly SG_NAME=helios-lab
readonly SG_DESCRIPTION='helios-lab: ssh in from one /32, http and https out'
readonly CHECKIP_URL=https://checkip.amazonaws.com
# Nested virtualization's launch parameter needs this CLI (plan: External
# References). Only the create path checks it; start and stop work on older.
readonly MIN_CLI_VERSION=2.33.21
# Ubuntu 24.04 amd64 on gp3, resolved by EC2 at launch (needs ssm:GetParameters)
readonly AMI_SSM=resolve:ssm:/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id

# The preflight dry-run runs before the lab key may exist, so it carries
# placeholder key material of the real shape: an all-zero ed25519 public key
# and that key's fingerprint as the KeyFingerprint tag value.
readonly PLACEHOLDER_PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
readonly PLACEHOLDER_FP=SHA256:kmYcvdi2GkPeWxB6XLjrZB8JHsy2Hm8luHMFp9GMvqk

# Every EC2 state except terminated: a terminated instance is gone for good.
readonly LIVE_STATES=pending,running,stopping,stopped,shutting-down
readonly F_PROJECT="Name=tag:Project,Values=$TAG_PROJECT"
readonly F_MANAGED="Name=tag:ManagedBy,Values=$TAG_MANAGED_BY"

# Queries. The test stub replays their text output, derived from the captured
# fixtures by tests/derive-text (fixtures/derived/). Change one, re-derive.
# Field order is the row contract documented in state.sh.
readonly Q_DISCOVER="Reservations[].Instances[].[InstanceId,State.Name,InstanceType,Placement.AvailabilityZone,PublicIpAddress,LaunchTime,SecurityGroups[0].GroupId,StateReason.Code,StateTransitionReason,Tags[?Key=='KeyFingerprint'].Value | [0]]"
readonly Q_GROUP_IDS='SecurityGroups[].[GroupId]'
readonly Q_INGRESS='SecurityGroupRules[?!IsEgress].[IpProtocol,FromPort,ToPort,CidrIpv4]'
# U6. Each has a derived reply in fixtures/derived/ (README table).
readonly Q_ROOT_VOLUMES='Reservations[].Instances[].BlockDeviceMappings[].Ebs.[VolumeId,DeleteOnTermination]'
readonly Q_VOLUME_IDS='Volumes[].[VolumeId]'
readonly Q_CALLER='[Account,Arn]'
readonly Q_VPC='Vpcs[].[VpcId]'
readonly Q_OFFERED_AZS='InstanceTypeOfferings[].[Location]'
readonly Q_SUBNETS='Subnets[].[SubnetId,AvailabilityZone]'
readonly Q_GROUP_ID='GroupId'
readonly Q_RULES='SecurityGroupRules[].[SecurityGroupRuleId,IsEgress,IpProtocol,FromPort,ToPort,CidrIpv4]'
readonly Q_RETURN='Return'
readonly Q_LAUNCHED='Instances[0].[InstanceId,LaunchTime]'
readonly Q_STARTING='StartingInstances[].[InstanceId,CurrentState.Name]'
readonly Q_STOPPING='StoppingInstances[].[InstanceId,CurrentState.Name]'
readonly Q_TERMINATING='TerminatingInstances[].[InstanceId,CurrentState.Name]'
# U2. The CLI decodes the console's base64 itself; the spike captured exactly
# this query's text output (fixtures/get-console-output.*), so no derivation.
readonly Q_CONSOLE='Output'

# Text output separates fields with tabs, and tab is IFS whitespace: `read`
# would merge an empty field (StateTransitionReason is "" while running) into
# its neighbour. US (unit separator) is not whitespace, so empty fields survive.
readonly US=$'\037'

# --- Calls -------------------------------------------------------------------
# Bash 3.2 runs $(...) without errexit, so a function whose output is
# captured passes failures on explicitly (`|| return`, or die), never by
# relying on set -e.

# require_aws_cli — fail fast with the install hint
# shellcheck disable=SC2154  # PROFILE and EX_* are defined by the entry
require_aws_cli() {
  command -v aws >/dev/null 2>&1 \
    || die "$EX_FAIL" 'aws CLI not found: brew install awscli (it is in ~/.Brewfile)'
}

# aws_attempt <service> <operation> [args...] -> the entry's attempt, for one
# call in the contract's shape
aws_attempt() { attempt aws "$@" --output text --profile "$PROFILE" --region "$REGION"; }

# aws_expect <codes> <service> <operation> [args...] -> the call's answer:
# 0 with the CLI's stdout; or, when it fails with one of <codes> (EC2 error
# codes, space-separated: an answer the caller handles, such as capacity or
# DependencyViolation), the CLI's exit status with "<code><US><the CLI's
# first line>". Any other failure dies with a typed code and a fix-it hint
# (aws_fail). The one place the CLI is checked for, outside the capture, so
# a missing one dies once, with the install hint.
aws_expect() {
  local codes=$1 out rc=0 code
  shift
  require_aws_cli
  out=$(aws_attempt "$@") || rc=$?
  (( rc != 0 )) || { printf '%s' "$out"; return 0; }
  code=$(aws_error_code "$out") || code=''
  [[ -n $code && " $codes " == *" $code "* ]] || aws_fail "$(call_label "$@")" "$out"
  printf '%s%s%s' "$code" "$US" "$(first_line "$out")"
  return "$rc"
}

# aws_call <service> <operation> [args...] -> the CLI's stdout: aws_expect,
# with no failure an answer
aws_call() { aws_expect '' "$@"; }

# aws_query <service> <operation> <query> [args...] -> the query's text output,
# one row per line, fields US-delimited
aws_query() {
  local service=$1 op=$2 query=$3 out
  shift 3
  out=$(aws_call "$service" "$op" "$@" --query "$query") || return
  printf '%s' "${out//$'\t'/$US}"
}

# --- Errors ------------------------------------------------------------------
# aws_error_class <stderr> -> profile | sso | denied | network | other  (pure)
aws_error_class() {
  case $1 in
    *'aws sso login'*|*'Error loading SSO Token'*|*'Token has expired'*) echo sso ;;
    *'could not be found'*|*'Unable to locate credentials'*|*InvalidClientTokenId*|\
    *AuthFailure*|*ExpiredToken*|*RequestExpired*|*SignatureDoesNotMatch*) echo profile ;;
    *UnauthorizedOperation*|*AccessDenied*) echo denied ;;
    *'Could not connect to the endpoint URL'*|*'Connect timeout'*|*'Read timeout'*|\
    *EndpointConnectionError*) echo network ;;
    *) echo other ;;
  esac
}

# aws_error_code <stderr> -> the service's error code, from
# "An error occurred (Code) when calling ..."; fails when there is none (pure)
aws_error_code() {
  local re='An error occurred \(([A-Za-z0-9.]+)\)'
  [[ $1 =~ $re ]] || return 1
  echo "${BASH_REMATCH[1]}"
}

# dry_run_outcome <exit-status> <stderr> -> pass | denied | fail  (pure)
# A dry-run that would succeed is an error by design: exit 254 with
# DryRunOperation (fixtures/run-instances.dry-run-ok.*). Exit 0 is impossible
# for a real dry-run, so it fails too.
dry_run_outcome() {
  local code
  code=$(aws_error_code "$2") || code=''
  case $1:$code in
    254:DryRunOperation)     echo pass ;;
    *:UnauthorizedOperation) echo denied ;;
    *)                       echo fail ;;
  esac
}

# call_label <service> <operation> [args...] -> how a failure names the call:
# "ec2 run-instances", or "ec2 run-instances --dry-run" for the dry-run  (pure)
call_label() {
  local arg label="$1 $2"
  for arg in "$@"; do [[ $arg != --dry-run ]] || label="$label --dry-run"; done
  echo "$label"
}

# first_line <text> -> its first non-blank line (AWS errors start with a blank one)
first_line() {
  local line
  while IFS= read -r line; do
    [[ -z ${line// /} ]] || { printf '%s\n' "$line"; return 0; }
  done <<< "$1"
}

# aws_fail <"service operation"> <stderr> -> dies: auth 3, network 8, other 1.
# The hint says what to do; the CLI's own first line follows for context.
# shellcheck disable=SC2154  # PROFILE and EX_* are defined by the entry
aws_fail() {
  local said
  said=$(first_line "$2")
  said="aws said: ${said:-nothing}"
  case $(aws_error_class "$2") in
    sso)     die "$EX_AUTH" "the SSO session for profile '$PROFILE' has expired ($1)" \
               "run: aws sso login --profile $PROFILE" "$said" ;;
    profile) die "$EX_AUTH" "AWS credentials for profile '$PROFILE' are missing or invalid ($1)" \
               "set them up once: aws configure --profile $PROFILE (README: Helios Lab)" "$said" ;;
    denied)  die "$EX_AUTH" "profile '$PROFILE' may not call $1" \
               "attach the shipped least-privilege policy (iam-policy.json)" "$said" ;;
    network) die "$EX_NET" "cannot reach AWS ($1): check this Mac's network" "$said" ;;
    *)       die "$EX_FAIL" "$1 failed" "$said" ;;
  esac
}

# --- Discovery ---------------------------------------------------------------
# aws_discover_instances -> one row per live lab instance (state.sh row contract).
# Filtered on BOTH lab tags, so a resource that only shares a name never counts.
aws_discover_instances() {
  aws_query ec2 describe-instances "$Q_DISCOVER" \
    --filters "$F_PROJECT" "$F_MANAGED" "Name=instance-state-name,Values=$LIVE_STATES"
}

# aws_discover_groups -> one lab security-group ID per line, found by tag AND name
aws_discover_groups() {
  aws_query ec2 describe-security-groups "$Q_GROUP_IDS" \
    --filters "$F_PROJECT" "$F_MANAGED" "Name=group-name,Values=$SG_NAME"
}

# aws_ingress_rules <group-id> -> one US-delimited "proto from to cidr" row per ingress rule
aws_ingress_rules() {
  aws_query ec2 describe-security-group-rules "$Q_INGRESS" --filters "Name=group-id,Values=$1"
}

# caller_ip -> this Mac's public IPv4, strictly validated; fails otherwise.
# HTTPS only (--proto =https also refuses a redirect to http), IPv4 only (-4),
# bounded so status can't hang. Tests replace curl with tests/stubs/curl.
caller_ip() {
  local ip
  ip=$(curl -fsS -4 --proto '=https' --max-time 5 "$CHECKIP_URL" 2>/dev/null) || return 1
  is_ipv4 "$ip" || return 1
  printf '%s\n' "$ip"
}

# aws_root_volumes <instance-id>... -> one "volume-id delete-on-termination" row per volume
aws_root_volumes() { aws_query ec2 describe-instances "$Q_ROOT_VOLUMES" --instance-ids "$@"; }

# aws_discover_volumes -> one lab-tagged volume ID per line, in any state
aws_discover_volumes() { aws_query ec2 describe-volumes "$Q_VOLUME_IDS" --filters "$F_PROJECT" "$F_MANAGED"; }

# aws_console_output <instance-id> -> the serial console's recent text (U2).
# Always --latest: without it EC2 returns a buffered snapshot that was still
# empty on first boot in the spike, while --latest (Nitro) showed both
# fingerprint blocks. aws_call, not aws_query: console text keeps its tabs.
aws_console_output() { aws_call ec2 get-console-output --instance-id "$1" --latest --query "$Q_CONSOLE"; }

# --- Preflight (create path only) --------------------------------------------
# aws_cli_version -> what `aws --version` prints (outside the call contract:
# it reads no profile or region). The create path asks only after discovery,
# whose call checked that the CLI is there.
aws_cli_version() { aws --version 2>&1 || true; }

# aws_caller -> "account<US>arn" of the profile's identity
aws_caller() { aws_query sts get-caller-identity "$Q_CALLER"; }

# aws_default_vpc -> the region's default VPC ID, or nothing
aws_default_vpc() { aws_query ec2 describe-vpcs "$Q_VPC" --filters Name=is-default,Values=true; }

# aws_offered_azs <type> -> each zone that offers the type, one per line
aws_offered_azs() {
  aws_query ec2 describe-instance-type-offerings "$Q_OFFERED_AZS" \
    --location-type availability-zone --filters "Name=instance-type,Values=$1"
}

# aws_default_subnets <vpc-id> -> one "subnet-id<US>az" row per default-for-az subnet
aws_default_subnets() {
  aws_query ec2 describe-subnets "$Q_SUBNETS" \
    --filters "Name=vpc-id,Values=$1" Name=default-for-az,Values=true
}

# preflight_cli -> the CLI's version; dies when it predates nested virtualization
preflight_cli() {
  local text have
  text=$(aws_cli_version) || return
  have=$(cli_version_of "$text") \
    || die "$EX_FAIL" "cannot read the aws CLI version from: $(first_line "$text")" 'brew upgrade awscli'
  version_at_least "$have" "$MIN_CLI_VERSION" || die "$EX_FAIL" \
    "aws-cli $have is too old: launching with nested virtualization needs $MIN_CLI_VERSION or later" \
    'brew upgrade awscli'
  echo "$have"
}

# preflight_account -> the profile's account ID; refuses root credentials (R9)
preflight_account() {
  local caller account arn
  caller=$(aws_caller) || return
  IFS=$US read -r account arn <<< "$caller"
  if is_root_arn "$arn"; then
    die "$EX_AUTH" "profile '$PROFILE' holds the account's root credentials ($arn); helios-lab refuses them" \
      'use a dedicated IAM user or SSO identity with the shipped policy (iam-policy.json)' \
      "then point the profile at it: aws configure --profile $PROFILE"
  fi
  echo "$account"
}

# preflight_vpc -> the default VPC's ID; the lab launches into it
preflight_vpc() {
  local vpc
  vpc=$(aws_default_vpc) || return
  [[ -n $vpc ]] || die "$EX_FAIL" "no default VPC in $REGION: the lab launches into it" \
    "create one: aws ec2 create-default-vpc --profile $PROFILE --region $REGION"
  echo "$vpc"
}

# preflight_placement <vpc-id> <type> -> "subnet-id<US>az": a default subnet
# in a zone that offers the type, so the launch never asks a zone without it
preflight_placement() {
  local azs subnets offered
  azs=$(aws_offered_azs "$2") || return
  subnets=$(aws_default_subnets "$1") || return
  offered=$(row_ids "$azs")
  pick_subnet "$azs" "$subnets" || die "$EX_CAPACITY" \
    "no default subnet of $1 is in a zone that offers $2 (offered in: ${offered:-no zone of $REGION})" \
    'create with another type: HELIOS_LAB_INSTANCE_TYPE=<type> helios-lab up'
}

# aws_dry_run_launch <type> <subnet-id> — dies unless EC2 says the launch
# would succeed. No security group (the group may not exist yet; the VPC's
# default group stands in) and placeholder key material; everything else is
# the real launch's, from the one definition in aws_run_instances. A
# success (exit 0) is impossible for a real dry-run, so it fails too. A
# failure with no answer (neither code) was already reported, typed, by
# aws_expect inside the capture: its status passes on, not reported twice.
aws_dry_run_launch() {
  local out rc=0 user_data said
  user_data=$(render_user_data "$PLACEHOLDER_PUBKEY") || return 1
  out=$(aws_run_instances 'DryRunOperation UnauthorizedOperation' "$1" "$2" "$PLACEHOLDER_FP" "$user_data" \
    --dry-run) || rc=$?
  (( rc == 0 )) || [[ -n $out ]] || return "$rc"
  said=${out#*"$US"}
  case $(dry_run_outcome "$rc" "$said") in
    pass)   return 0 ;;
    denied) die "$EX_AUTH" "profile '$PROFILE' may not launch the lab instance: the RunInstances dry-run was refused" \
              "attach the shipped least-privilege policy: $HELIOS_LAB_HOME/iam-policy.json" "aws said: $said" ;;
    *)      aws_fail 'ec2 run-instances --dry-run' "$said" ;;
  esac
}

# --- Launch, start, stop, terminate ------------------------------------------
# aws_run_instances <expected codes> <type> <subnet-id> <key-fingerprint>
# <user-data> [args...] -> aws_expect's answer. The single definition of the
# lab instance, shared by the preflight dry-run and the launch, so the
# dry-run authorizes exactly what the launch asks for:
# - nested virtualization; IMDSv2 required with hop limit 1; no instance
#   profile, ever (none is passed, and the policy withholds iam:PassRole)
# - shutdown behaviour stop, so the idle path can stop but never terminate
# - an encrypted 100 GB gp3 root, DeleteOnTermination set explicitly
# - every resource tagged in the call that creates it: the instance and its
#   volume carry both lab tags, Name and the lab key's fingerprint
aws_run_instances() {
  local codes=$1 type=$2 subnet=$3 fp=$4 user_data=$5
  shift 5
  aws_expect "$codes" ec2 run-instances --image-id "$AMI_SSM" --instance-type "$type" --subnet-id "$subnet" \
    --cpu-options NestedVirtualization=enabled \
    --metadata-options HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled \
    --instance-initiated-shutdown-behavior stop \
    --block-device-mappings "$(render_root_device "$ROOT_GB")" \
    --tag-specifications "$(lab_tag_spec instance "$fp")" "$(lab_tag_spec volume "$fp")" \
    --user-data "$user_data" "$@"
}

# lab_tag_spec <resource-type> <key-fingerprint> -> its --tag-specifications item
lab_tag_spec() {
  render_tag_spec "$1" "Project=$TAG_PROJECT" "ManagedBy=$TAG_MANAGED_BY" "Name=$TAG_NAME" "KeyFingerprint=$2"
}

# aws_launch <type> <subnet-id> <az> <group-id> <key-fingerprint> <user-data>
# -> "instance-id<US>launch-time". One attempt only: a capacity error exits 5
# naming the type and the override; there is no retry loop.
aws_launch() {
  local out rc=0
  out=$(aws_run_instances InsufficientInstanceCapacity "$1" "$2" "$5" "$6" --security-group-ids "$4" \
    --query "$Q_LAUNCHED") || rc=$?
  (( rc == 0 )) || die "$EX_CAPACITY" "EC2 has no $1 capacity in $3 right now; nothing was launched" \
    "retry later, or create with another type: HELIOS_LAB_INSTANCE_TYPE=<type> helios-lab up" \
    "types: a non-metal size of $(nested_virt_families), with at least 4 vCPU and 16 GiB" \
    "aws said: ${out#*"$US"}"
  printf '%s' "${out//$'\t'/$US}"
}

# aws_start <instance-id> <type> <az> — a capacity error only says to retry:
# changing a stopped instance's type needs a permission the policy withholds,
# so the type override is no remedy here.
aws_start() {
  local out rc=0
  out=$(aws_expect InsufficientInstanceCapacity ec2 start-instances --instance-ids "$1" --query "$Q_STARTING") \
    || rc=$?
  (( rc == 0 )) || die "$EX_CAPACITY" "EC2 has no $2 capacity in $3 right now; $1 is stopped and intact" \
    'retry in a few minutes: helios-lab up' "aws said: ${out#*"$US"}"
}

aws_stop() { aws_call ec2 stop-instances --instance-ids "$1" --query "$Q_STOPPING" >/dev/null; }
aws_terminate() { aws_call ec2 terminate-instances --instance-ids "$@" --query "$Q_TERMINATING" >/dev/null; }

# aws_wait <waiter> <id-option> <id>... — the CLI's own waiter (it polls for
# up to 10 minutes and fails on a terminal state)
aws_wait() { aws_call ec2 wait "$@" >/dev/null; }

# --- Security group ----------------------------------------------------------
# aws_create_group <vpc-id> -> the new group's ID. Tagged in the same call
# (both lab tags and Name), so it is never untagged, not even briefly.
aws_create_group() {
  aws_query ec2 create-security-group "$Q_GROUP_ID" --group-name "$SG_NAME" \
    --description "$SG_DESCRIPTION" --vpc-id "$1" \
    --tag-specifications "$(render_tag_spec security-group "Project=$TAG_PROJECT" \
      "ManagedBy=$TAG_MANAGED_BY" "Name=$TAG_NAME")"
}

# aws_group_rules <group-id> -> every rule of the group as Q_RULES rows
aws_group_rules() { aws_query ec2 describe-security-group-rules "$Q_RULES" --filters "Name=group-id,Values=$1"; }

# aws_sg_apply <group-id> <egress|ingress> <plan> — the calls a plan lists
# (state.sh egress_plan / ingress_plan). Revokes go first: a failure in
# between leaves the group narrower, never wider. Rules are not tagged
# themselves; that would need CreateTags beyond the create actions.
aws_sg_apply() {
  local group=$1 dir=$2 arg
  local -a ids=() perms=()
  read -r -a ids <<< "$(plan_args revoke "$3")"
  for arg in $(plan_args authorize "$3"); do perms+=("$(sg_perm "$dir" "$arg")"); done
  (( ${#ids[@]} == 0 )) || aws_call ec2 "revoke-security-group-$dir" --group-id "$group" \
    --security-group-rule-ids "${ids[@]}" --query "$Q_RETURN" >/dev/null
  (( ${#perms[@]} == 0 )) || aws_call ec2 "authorize-security-group-$dir" --group-id "$group" \
    --ip-permissions "${perms[@]}" --query "$Q_RETURN" >/dev/null
}

# sg_perm <egress|ingress> <port|cidr> -> the --ip-permissions item for a plan's authorize
sg_perm() {
  case $1 in
    egress)  render_tcp_perm "$2" 0.0.0.0/0 ;;
    ingress) render_tcp_perm 22 "$2" ;;
  esac
}

# aws_delete_group <group-id> <attempts> <delay-s> — retries while EC2 still
# reports a dependent object: an ENI of a just-terminated instance lingers
# for a while. A group that is already gone counts as deleted. Any other
# failure (permission, network) is no dependency: aws_expect has already
# reported it inside the capture, so its typed status passes on at once,
# without a retry.
aws_delete_group() {
  local n out rc
  for (( n = 1; n <= $2; n++ )); do
    rc=0
    out=$(aws_expect 'InvalidGroup.NotFound DependencyViolation' ec2 delete-security-group --group-id "$1" \
      --query "$Q_RETURN") || rc=$?
    (( rc != 0 )) || return 0
    case ${out%%"$US"*} in
      InvalidGroup.NotFound) return 0 ;;
      DependencyViolation)   (( n == $2 )) || { echo "security group $1 still in use; retrying in $3s"; sleep "$3"; } ;;
      *)                     return "$rc" ;;
    esac
  done
  die "$EX_FAIL" "security group $1 is still in use after $2 attempts (DependencyViolation)" \
    'run helios-lab destroy --yes again in a few minutes' "aws said: ${out#*"$US"}"
}
