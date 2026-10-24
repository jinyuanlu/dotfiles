#!/bin/bash
# shellcheck source-path=SCRIPTDIR
#
# policy.test.sh — U5: the shipped least-privilege IAM policy, iam-policy.json
# (R9, R12). Its shape is checked statement by statement against the plan, and
# both ways against the ledger of aws calls the whole suite made: every call
# is granted, and every grant is exercised or says why no call shows it.
#
# tests/run runs this file last, after every other *.test.sh has filled the
# ledger (STUB_AWS_LEDGER, tests/stubs/aws). Only an unfiltered run fills it
# completely, so only then is the grant-to-call direction checked.
#
# The policy is read with ruby, stock on macOS with json in its standard
# library. Only these tests parse JSON; the command itself never does.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly POLICY=$HELIOS_LAB_HOME/iam-policy.json
readonly ARN=arn:aws:ec2:ap-northeast-1
readonly UBUNTU_PARAMETERS='arn:aws:ssm:ap-northeast-1::parameter/aws/service/canonical/ubuntu/server/24.04/*'
export LC_ALL=C   # one sort order for every comparison

# --- Reading the policy ------------------------------------------------------
# policy_view <view> -> tab-separated rows, one per item:
#   top         the document's keys (comma-joined), then its Version
#   shape       sid, then the statement's keys (sorted, comma-joined)
#   grants      sid effect action resource  (one row per action x resource)
#   conditions  sid operator key value      (one row per value)
readonly POLICY_VIEW_RB='
doc = JSON.parse(File.read(ARGV[1]))
statements = doc.fetch("Statement")
rows = case ARGV[0]
  when "top" then [doc.keys.sort.join(","), doc["Version"]]
  when "shape" then statements.map { |s| [s["Sid"], s.keys.sort.join(",")].join("\t") }
  when "grants" then statements.flat_map { |s|
    Array(s["Action"]).product(Array(s["Resource"])).map { |a, r| [s["Sid"], s["Effect"], a, r].join("\t") } }
  when "conditions" then statements.flat_map { |s|
    (s["Condition"] || {}).flat_map { |op, kv| kv.flat_map { |k, v| Array(v).map { |x| [s["Sid"], op, k, x].join("\t") } } } }
  else abort "unknown view #{ARGV[0]}"
end
puts rows'
policy_view() {
  command -v ruby >/dev/null 2>&1 \
    || fail 'ruby not found: these checks parse the policy with it (stock macOS ships /usr/bin/ruby)'
  ruby -rjson -e "$POLICY_VIEW_RB" "$1" "$POLICY" || fail "$POLICY does not parse as a policy document"
}

# policy_actions -> every action the policy grants, one per line, sorted
policy_actions() { policy_view grants | cut -f3 | sort -u; }

# grants_of <action> -> "sid resource" for each resource the action is granted on
grants_of() { policy_view grants | awk -F'\t' -v a="$1" '$3 == a { print $1, $4 }' | sort; }

# conditions_of <sid> -> "operator key value" for each condition value of the statement
conditions_of() { policy_view conditions | awk -F'\t' -v s="$1" '$1 == s { print $2, $3, $4 }' | sort; }

# lines <line>... -> the lines, sorted (an expected value for grants_of and conditions_of)
lines() { printf '%s\n' "$@" | sort; }

readonly IN_REGION='StringEquals aws:RequestedRegion ap-northeast-1'
readonly REQUEST_TAG='StringEquals aws:RequestTag/Project helios-lab'
readonly RESOURCE_TAG='StringEquals ec2:ResourceTag/Project helios-lab'

# policy_admits_type <instance-type> — the RunInstances instance statement's
# type conditions, evaluated as IAM would: StringLike and StringNotLike use
# * and ? the way a shell pattern does, and these patterns use nothing else
policy_admits_type() {
  local op key pattern like=no
  while read -r op key pattern; do
    [[ $key == ec2:InstanceType ]] || continue
    # shellcheck disable=SC2053  # the pattern is meant to match as a pattern
    case $op in
      StringLike)    [[ $1 != $pattern ]] || like=yes ;;
      StringNotLike) [[ $1 != $pattern ]] || return 1 ;;
    esac
  done <<< "$(conditions_of LaunchTaggedNestedVirtInstance)"
  [[ $like == yes ]]
}

# --- Calls to actions --------------------------------------------------------
# iam_action <service> <operation> [waiter] -> the IAM action a CLI call is
# authorized as, or nothing for a call that needs no permission. Fails for a
# waiter or service it doesn't know, so a new kind of call can't slip past.
iam_action() {
  case $1:$2 in
    sts:get-caller-identity) return 0 ;;   # needs no permission: it answers even when all else is denied
    ec2:wait)                waiter_action "${3:-}" ;;
    ec2:*|ssm:*)             echo "$1:$(pascal_case "$2")" ;;
    *)                       return 1 ;;
  esac
}

# waiter_action <waiter> -> the describe call the CLI's waiter polls
waiter_action() {
  case $1 in
    instance-running|instance-stopped|instance-terminated) echo ec2:DescribeInstances ;;
    volume-deleted)                                        echo ec2:DescribeVolumes ;;
    *)                                                     return 1 ;;
  esac
}

# pascal_case <kebab-case> -> PascalCase: describe-vpcs -> DescribeVpcs
pascal_case() {
  awk -F- '{ for (i = 1; i <= NF; i++) printf "%s%s", toupper(substr($i, 1, 1)), substr($i, 2); print "" }' <<< "$1"
}

# ledger_actions -> the IAM action of every call in the suite's ledger, sorted
ledger_actions() {
  local service op waiter
  while read -r service op waiter; do
    iam_action "$service" "$op" "$waiter" || fail "no IAM action known for: aws $service $op $waiter"
  done < <(sort -u "${STUB_AWS_LEDGER:?tests/run sets STUB_AWS_LEDGER}") | sort -u
}

# unseen_reason <action> -> why the policy grants an action that no aws call
# in the suite shows; fails for any other action. The reverse check's allowlist.
unseen_reason() {
  case $1 in
    ssm:GetParameters) echo "run-instances names its image as resolve:ssm:..., which EC2 resolves server side with the caller's ssm:GetParameters" ;;
    ec2:CreateTags)    echo 'run-instances and create-security-group tag what they create in the same call (--tag-specifications), which IAM authorizes as ec2:CreateTags' ;;
    *)                 return 1 ;;
  esac
}

# --- Document shape ----------------------------------------------------------
test_policy_parses_as_a_2012_10_17_document() {
  assert_eq $'Statement,Version\n2012-10-17' "$(policy_view top)"
}

# No NotAction, NotResource or Principal: each would widen what a grant means.
test_every_statement_allows_actions_on_resources_under_conditions() {
  local shape sid keys
  shape=$(policy_view shape)
  while IFS=$'\t' read -r sid keys; do
    assert_eq Action,Condition,Effect,Resource,Sid "$keys" "keys of statement $sid"
  done <<< "$shape"
  assert_eq '' "$(cut -f1 <<< "$shape" | sort | uniq -d)" 'duplicate Sids'
  assert_eq Allow "$(policy_view grants | cut -f2 | sort -u)"
}

test_every_statement_is_pinned_to_ap_northeast_1() {
  local conditions
  conditions=$(policy_view conditions)
  assert_eq "$(policy_view shape | cut -f1 | sort)" \
    "$(awk -F'\t' '$2 == "StringEquals" && $3 == "aws:RequestedRegion" { print $1 }' <<< "$conditions" | sort)"
  assert_eq ap-northeast-1 "$(awk -F'\t' '$3 == "aws:RequestedRegion" { print $4 }' <<< "$conditions" | sort -u)"
  assert_eq '' "$(policy_view grants | cut -f4 | grep -v -e '^\*$' -e '^arn:aws:[a-z0-9]*:ap-northeast-1:' || true)" \
    'resources outside ap-northeast-1'
}

# Public repo: no account ID. An ARN's account field is * (or empty, as AWS
# writes it for public images and public parameters).
test_the_policy_names_no_account() {
  local text resource account
  text=$(<"$POLICY")
  if [[ $text =~ [0-9]{12} ]]; then fail "a 12-digit number in the policy: ${BASH_REMATCH[0]}"; fi
  while IFS= read -r resource; do
    [[ $resource != '*' ]] || continue
    account=$(cut -d: -f5 <<< "$resource")
    [[ $account == '*' || -z $account ]] || fail "account field '$account' in $resource"
  done < <(policy_view grants | cut -f4 | sort -u)
}

# --- What is granted ---------------------------------------------------------
# iam:PassRole: the host never has an instance profile. ModifyInstanceAttribute
# could change a stopped instance's type, user-data or shutdown behaviour (the
# last would let a stop terminate); resize stays deferred until it is designed.
test_no_wildcard_action_and_the_withheld_ones_are_absent() {
  local actions
  actions=$(policy_actions)
  assert_not_contains "$actions" '*'
  assert_eq '' "$(grep -v -e '^ec2:' -e '^ssm:' <<< "$actions" || true)" 'actions outside ec2 and ssm'
  if grep -qx -e iam:PassRole -e ec2:ModifyInstanceAttribute <<< "$actions"; then
    fail 'the policy grants iam:PassRole or ec2:ModifyInstanceAttribute'
  fi
}

test_only_describe_calls_reach_every_resource() {
  assert_eq '' "$(policy_view grants | awk -F'\t' '$4 == "*" && $3 !~ /^ec2:Describe[A-Za-z]+$/ { print $3 }')"
  assert_eq "$IN_REGION" "$(conditions_of ReadLabState)"
}

# IAM evaluates RunInstances against every resource the launch touches, and a
# request-tag or type condition exists only on the resource it describes. The
# unconditioned security-group grant lets the preflight dry-run (default group)
# and the real launch (lab group) authorize alike.
test_run_instances_is_granted_per_resource_type() {
  assert_eq "$(lines "LaunchTaggedNestedVirtInstance $ARN:*:instance/*" \
      "LaunchTaggedRootVolume $ARN:*:volume/*" \
      "LaunchUsingImageSubnetGroupAndInterface $ARN::image/*" \
      "LaunchUsingImageSubnetGroupAndInterface $ARN:*:subnet/*" \
      "LaunchUsingImageSubnetGroupAndInterface $ARN:*:security-group/*" \
      "LaunchUsingImageSubnetGroupAndInterface $ARN:*:network-interface/*")" \
    "$(grants_of ec2:RunInstances)"
  assert_eq "$(lines "$IN_REGION" "$REQUEST_TAG")" "$(conditions_of LaunchTaggedRootVolume)"
  assert_eq "$IN_REGION" "$(conditions_of LaunchUsingImageSubnetGroupAndInterface)"
  assert_eq "$(lines "$IN_REGION" "$REQUEST_TAG")" \
    "$(conditions_of LaunchTaggedNestedVirtInstance | grep -v ec2:InstanceType)"
}

test_the_instance_type_condition_names_exactly_the_nested_virt_families() {
  load_cli
  local family want=('StringNotLike ec2:InstanceType *.metal*')
  for family in $NESTED_VIRT_FAMILIES; do want+=("StringLike ec2:InstanceType $family.*"); done
  assert_eq "$(lines "${want[@]}")" "$(conditions_of LaunchTaggedNestedVirtInstance | grep ec2:InstanceType)"
}

# The policy is coarser than instance_type_ok (it doesn't spell out sizes),
# never narrower: every type the command accepts launches, and metal never does.
test_the_policy_admits_every_type_the_command_accepts() {
  load_cli
  local t
  for t in m8i.xlarge m8i.2xlarge c8i.2xlarge r8i.large m8i-flex.xlarge c8i-flex.16xlarge \
           c7i.48xlarge m7i.4xlarge r7i.24xlarge; do
    instance_type_ok "$t" || fail "the command rejects $t"
    policy_admits_type "$t" || fail "the policy refuses $t, which the command accepts"
  done
  for t in m8i.metal-48xl c7i.metal-24xl r8i.metal-96xl t3.large m8g.xlarge m7i-flex.large c6i.xlarge; do
    if policy_admits_type "$t"; then fail "the policy admits $t"; fi
    if instance_type_ok "$t"; then fail "the command accepts $t"; fi
  done
}

test_create_security_group_is_tagged_on_the_group_only() {
  assert_eq "$(lines "CreateTaggedSecurityGroup $ARN:*:security-group/*" \
      "CreateSecurityGroupInVpc $ARN:*:vpc/*")" \
    "$(grants_of ec2:CreateSecurityGroup)"
  assert_eq "$(lines "$IN_REGION" "$REQUEST_TAG")" "$(conditions_of CreateTaggedSecurityGroup)"
  assert_eq "$IN_REGION" "$(conditions_of CreateSecurityGroupInVpc)"
}

# Tags arrive only inside the calls that create the resource: an existing
# resource can't be tagged into the lab, so the tag-scoped grants below can't
# be stretched to it.
test_create_tags_only_within_the_creating_calls() {
  assert_eq "$(lines "TagOnlyInTheCreatingCall $ARN:*:instance/*" \
      "TagOnlyInTheCreatingCall $ARN:*:volume/*" \
      "TagOnlyInTheCreatingCall $ARN:*:security-group/*")" \
    "$(grants_of ec2:CreateTags)"
  assert_eq "$(lines "$IN_REGION" 'StringEquals ec2:CreateAction RunInstances' \
      'StringEquals ec2:CreateAction CreateSecurityGroup')" \
    "$(conditions_of TagOnlyInTheCreatingCall)"
}

test_instance_operations_need_the_project_tag() {
  local action
  for action in ec2:StartInstances ec2:StopInstances ec2:TerminateInstances ec2:GetConsoleOutput; do
    assert_eq "OperateLabInstance $ARN:*:instance/*" "$(grants_of "$action")" "$action"
  done
  assert_eq "$(lines "$IN_REGION" "$RESOURCE_TAG")" "$(conditions_of OperateLabInstance)"
}

test_security_group_operations_need_the_project_tag() {
  local action
  for action in ec2:AuthorizeSecurityGroupIngress ec2:RevokeSecurityGroupIngress \
                ec2:AuthorizeSecurityGroupEgress ec2:RevokeSecurityGroupEgress ec2:DeleteSecurityGroup; do
    assert_eq "OperateLabSecurityGroup $ARN:*:security-group/*" "$(grants_of "$action")" "$action"
  done
  assert_eq "$(lines "$IN_REGION" "$RESOURCE_TAG")" "$(conditions_of OperateLabSecurityGroup)"
}

test_ssm_reads_only_the_ubuntu_24_04_parameters() {
  load_cli
  assert_eq "ResolveUbuntuImage $UBUNTU_PARAMETERS" "$(grants_of ssm:GetParameters)"
  assert_eq ssm:GetParameters "$(policy_actions | grep '^ssm:')"
  assert_eq "$IN_REGION" "$(conditions_of ResolveUbuntuImage)"
  # the parameter the launch resolves (lib/aws.sh) lies under that path
  # shellcheck disable=SC2053  # the resource is meant to match as a pattern
  [[ arn:aws:ssm:ap-northeast-1::parameter/${AMI_SSM#resolve:ssm:/} == $UBUNTU_PARAMETERS ]] \
    || fail "$AMI_SSM is not under $UBUNTU_PARAMETERS"
}

# --- The ledger and the cross-check ------------------------------------------
test_cli_calls_map_to_their_iam_actions() {
  local spec call
  for spec in 'ec2 describe-instances|ec2:DescribeInstances' 'ec2 describe-vpcs|ec2:DescribeVpcs' \
              'ec2 describe-security-group-rules|ec2:DescribeSecurityGroupRules' \
              'ec2 describe-instance-type-offerings|ec2:DescribeInstanceTypeOfferings' \
              'ec2 get-console-output|ec2:GetConsoleOutput' 'ec2 run-instances|ec2:RunInstances' \
              'ssm get-parameters|ssm:GetParameters' 'ec2 wait instance-running|ec2:DescribeInstances' \
              'ec2 wait instance-stopped|ec2:DescribeInstances' 'ec2 wait instance-terminated|ec2:DescribeInstances' \
              'ec2 wait volume-deleted|ec2:DescribeVolumes' 'sts get-caller-identity|'; do
    read -r -a call <<< "${spec%|*}"
    assert_eq "${spec#*|}" "$(iam_action "${call[@]}")" "${spec%|*}"
  done
  if iam_action ec2 wait instance-status-ok >/dev/null; then fail 'mapped an unknown waiter'; fi
  if iam_action s3 list-buckets >/dev/null; then fail 'mapped a service the policy does not cover'; fi
}

test_the_aws_stub_records_each_accepted_call_in_the_ledger() {
  export STUB_AWS_LEDGER=$SANDBOX/ledger   # this test's own, not the suite's
  : > "$STUB_AWS_LEDGER"
  local ok=(--output text --profile p --region ap-northeast-1)
  aws ec2 describe-vpcs "${ok[@]}" >/dev/null 2>&1 || true   # no reply (exit 97): still a call made
  aws ec2 wait instance-running --instance-ids i-0123456789abcdef0 "${ok[@]}" >/dev/null 2>&1 || true
  aws ec2 describe-instances --output text --profile p >/dev/null 2>&1 || true   # breaks the contract
  aws --version >/dev/null 2>&1 || true
  assert_eq $'ec2 describe-vpcs\nec2 wait instance-running' "$(<"$STUB_AWS_LEDGER")"
}

# Both lists are captured first, not read from a process substitution, whose
# failure (a call with no known IAM action) bash would drop.
test_every_aws_call_the_suite_made_is_granted() {
  local granted called action missing=''
  granted=$(policy_actions)
  called=$(ledger_actions)
  while IFS= read -r action; do
    [[ -z $action ]] || grep -qxF "$action" <<< "$granted" || missing+=" $action"
  done <<< "$called"
  [[ -z $missing ]] || fail "aws calls the policy does not grant:$missing"
}

if [[ ${STUB_AWS_LEDGER_COMPLETE:-no} == yes ]]; then
  test_every_granted_action_is_exercised_or_explained() {
    local exercised granted action
    exercised=$(ledger_actions)
    granted=$(policy_actions)
    [[ -n $exercised ]] || fail 'the ledger is empty: the aws stub recorded no call'
    while IFS= read -r action; do
      if grep -qxF "$action" <<< "$exercised"; then
        if unseen_reason "$action" >/dev/null; then fail "$action is exercised now: drop it from unseen_reason"; fi
      else
        unseen_reason "$action" >/dev/null \
          || fail "the policy grants $action, which no aws call in the suite makes: drop it, or say why in unseen_reason"
      fi
    done <<< "$granted"
  }
else
  echo '  skip  every_granted_action_is_exercised_or_explained (a filtered run records only part of the suite)'
fi

run_tests
