# shellcheck shell=bash
#
# helios-lab aws.sh — the only module that talks to AWS (and to checkip).
# U1: read-only discovery. U6 adds mutations and preflight here.
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
#
# Requires from the entry: PROFILE, die, EX_*.

readonly REGION=ap-northeast-1
readonly TAG_PROJECT=helios-lab
readonly TAG_MANAGED_BY=helios-lab-cli
readonly SG_NAME=helios-lab
readonly CHECKIP_URL=https://checkip.amazonaws.com

# Every EC2 state except terminated: a terminated instance is gone for good.
readonly LIVE_STATES=pending,running,stopping,stopped,shutting-down
readonly F_PROJECT="Name=tag:Project,Values=$TAG_PROJECT"
readonly F_MANAGED="Name=tag:ManagedBy,Values=$TAG_MANAGED_BY"

# Queries. The test stub replays their text output, derived from the captured
# fixtures by tests/derive-text (fixtures/derived/). Change one, re-derive.
# Field order is the row contract documented in state.sh.
readonly Q_DISCOVER='Reservations[].Instances[].[InstanceId,State.Name,InstanceType,Placement.AvailabilityZone,PublicIpAddress,LaunchTime,SecurityGroups[0].GroupId,StateReason.Code,StateTransitionReason]'
readonly Q_GROUP_IDS='SecurityGroups[].[GroupId]'
readonly Q_INGRESS='SecurityGroupRules[?!IsEgress].[IpProtocol,FromPort,ToPort,CidrIpv4]'

# Text output separates fields with tabs, and tab is IFS whitespace: `read`
# would merge an empty field (StateTransitionReason is "" while running) into
# its neighbour. US (unit separator) is not whitespace, so empty fields survive.
readonly US=$'\037'

# --- Calls -------------------------------------------------------------------
# aws_call <service> <operation> [args...] -> the CLI's stdout. On failure it
# dies with a typed code and a fix-it hint (see aws_fail).
# shellcheck disable=SC2154  # PROFILE and EX_* are defined by the entry
aws_call() {
  command -v aws >/dev/null 2>&1 \
    || die "$EX_FAIL" 'aws CLI not found: brew install awscli (it is in ~/.Brewfile)'
  local errf out err rc=0
  errf=$(mktemp "${TMPDIR:-/tmp}/helios-lab.XXXXXX")
  out=$(aws "$@" --output text --profile "$PROFILE" --region "$REGION" 2>"$errf") || rc=$?
  err=$(<"$errf")
  rm -f "$errf"
  (( rc == 0 )) || aws_fail "$1 $2" "$err"
  printf '%s' "$out"
}

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
