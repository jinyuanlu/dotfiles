# shellcheck shell=bash
#
# helios-lab state.sh — pure decisions: EC2 state -> up/stop action, stop
# cause, status lines, the cost table, input validation (U1); preflight
# verdicts, guest sizing, security-group convergence plans, the lab-key
# verdict and the lifecycle messages (U6); why ssh and console refuse, the
# host-stopped-itself line and the ready screen (U3).
#
# Pure means the output depends only on the arguments (plus TZ, for the one
# local clock time). Nothing here calls AWS, reads files or asks for `now`:
# callers pass the current time in. That keeps every function table-testable
# (tests/lifecycle.test.sh calls them directly).
#
# Data shape: a discovery "row" is one live instance, its fields separated by
# US ($'\037'), in this order (see Q_DISCOVER in aws.sh):
#   id state type az public-ip launch-time group-id reason-code reason-text
#
# Bash 3.2 (stock macOS /bin/bash): no associative arrays, no mapfile, no
# ${v,,}, no declare -n. A function that can "fail" returns non-zero and
# prints nothing, so callers branch with `if x=$(f ...)`.

# --- Up action ---------------------------------------------------------------
# up_action <ec2-state> -> create | start | wait-then-start | wait-then-create | none
# Total over every state discovery can return. `none` means no lifecycle call:
# up still waits for `running` before connecting, a no-op when already there.
up_action() {
  case $1 in
    absent)          echo create ;;
    pending|running) echo none ;;
    stopping)        echo wait-then-start ;;
    stopped)         echo start ;;
    shutting-down)   echo wait-then-create ;;
    *)               return 1 ;;
  esac
}

# stop_action <ec2-state> -> stop | wait-then-stop | wait | already | absent | terminating
# Total over the same states. A pending instance can't be stopped yet
# (IncorrectInstanceState), so it is waited into running first. Invariant:
# nothing here terminates; stop only ever stops.
stop_action() {
  case $1 in
    absent)        echo absent ;;
    pending)       echo wait-then-stop ;;
    running)       echo stop ;;
    stopping)      echo wait ;;
    stopped)       echo already ;;
    shutting-down) echo terminating ;;
    *)             return 1 ;;
  esac
}

# --- Time --------------------------------------------------------------------
# days_from_civil <y> <m> <d> -> days since 1970-01-01 (proleptic Gregorian).
# Howard Hinnant's algorithm in integer math, so parsing a timestamp never
# depends on BSD vs GNU `date`. 10# guards against "08" being read as octal.
days_from_civil() {
  local m=$((10#$2)) d=$((10#$3))
  local y=$(( 10#$1 - (m <= 2 ? 1 : 0) ))
  local era=$(( (y >= 0 ? y : y - 399) / 400 ))
  local yoe=$(( y - era * 400 ))
  local doy=$(( (153 * ((m + 9) % 12) + 2) / 5 + d - 1 ))
  local doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  echo $(( era * 146097 + doe - 719468 ))
}

# utc_epoch <y> <m> <d> <H> <M> <S> -> seconds since the epoch
utc_epoch() {
  local days
  days=$(days_from_civil "$1" "$2" "$3")
  echo $(( days * 86400 + 10#$4 * 3600 + 10#$5 * 60 + 10#$6 ))
}

# iso_epoch <EC2 timestamp> -> epoch. EC2 timestamps are UTC: the CLI's default
# iso8601 format prints "+00:00", its `wire` format ".000Z". Any other offset
# fails rather than being silently misread.
readonly ISO_UTC_RE='^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?(Z|\+00:00)$'
iso_epoch() {
  [[ $1 =~ $ISO_UTC_RE ]] || return 1
  local r=("${BASH_REMATCH[@]}")
  utc_epoch "${r[1]}" "${r[2]}" "${r[3]}" "${r[4]}" "${r[5]}" "${r[6]}"
}

# reason_epoch <StateTransitionReason> -> epoch of a manual stop, from
# "User initiated (YYYY-MM-DD HH:MM:SS GMT)". Fails on the bare "User initiated"
# an instance-initiated stop leaves (fixtures/describe-instances.stopped-idle.json).
readonly REASON_TS_RE='\(([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) GMT\)'
reason_epoch() {
  [[ $1 =~ $REASON_TS_RE ]] || return 1
  local r=("${BASH_REMATCH[@]}")
  utc_epoch "${r[1]}" "${r[2]}" "${r[3]}" "${r[4]}" "${r[5]}" "${r[6]}"
}

# uptime_s <launch-time> <now> -> seconds since launch (clamped at 0), or
# nothing when the timestamp is unreadable. EC2 resets LaunchTime on every
# start, so this is time since the last start: the billed stretch.
uptime_s() {
  local t
  t=$(iso_epoch "$1") || return 0
  echo $(( $2 > t ? $2 - t : 0 ))
}

# local_hhmm <epoch> -> HH:MM in the viewer's TZ (BSD date, GNU fallback).
# The only TZ-dependent function; tests pin TZ.
local_hhmm() { date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M; }

# fmt_duration <seconds> -> 42m | 2h05m | 1d03h
fmt_duration() {
  local m=$(( $1 / 60 ))
  local h=$(( m / 60 )) d=$(( m / 1440 ))
  if (( d > 0 )); then printf '%dd%02dh\n' "$d" $(( h % 24 ))
  elif (( h > 0 )); then printf '%dh%02dm\n' "$h" $(( m % 60 ))
  else printf '%dm\n' "$m"
  fi
}

# fmt_elapsed <seconds> -> 41s | 2m05s, for stage lines
fmt_elapsed() {
  if (( $1 < 60 )); then printf '%ds\n' "$1"
  else printf '%dm%02ds\n' $(( $1 / 60 )) $(( $1 % 60 ))
  fi
}

# launch_epoch <launch-time> -> epoch, or the fallback <now> when unreadable,
# so a notice can always name a time
launch_epoch() { iso_epoch "$1" || echo "$2"; }

# deadman_epoch <launch-epoch> -> when the user-data dead-man timer has
# stopped the host at the latest: OnBootSec=2h counts from boot, which follows
# the launch by seconds, so round up to the next whole minute.
readonly DEADMAN_S=7200
deadman_epoch() { echo $(( ($1 + DEADMAN_S + 59) / 60 * 60 )); }

# --- Cost --------------------------------------------------------------------
# Approximate on-demand prices for ap-northeast-1 from the AWS price feed on
# PRICE_DATE. Display only, never billing truth: always shown as ≈ and dated.
# Unit "e4" = $0.0001, so all money math is exact integer math (bash has no
# floats). Public IPv4 ($0.005/hr) is left out to match the plan's examples.
readonly PRICE_DATE=2026-10-23
readonly GP3_GB_MONTH_E4=960   # $0.096 per GB-month
readonly ROOT_GB=100           # constant root size (plan: "Few knobs")
readonly HOURS_PER_MONTH=730   # AWS's monthly-hours convention

# price_hourly_e4 <instance-type> -> on-demand $/hr in e4; fails when unpriced
price_hourly_e4() {
  case $1 in
    m8i.xlarge)  echo 2734 ;;
    m8i.2xlarge) echo 5468 ;;
    c8i.2xlarge) echo 4719 ;;
    *)           return 1 ;;
  esac
}

# fmt_cents <cents> -> $0.59
fmt_cents() { printf '$%d.%02d\n' $(( $1 / 100 )) $(( $1 % 100 )); }

# running_cost <instance-type> <seconds> -> ≈$0.59 (rounded half up to the cent)
running_cost() {
  local rate
  rate=$(price_hourly_e4 "$1") || { echo "no price for $1"; return 0; }
  echo "≈$(fmt_cents $(( (rate * $2 + 180000) / 360000 )))"
}

# storage_day_cents -> what the stopped root volume costs per day
storage_day_cents() {
  local e4_per_month=$(( GP3_GB_MONTH_E4 * ROOT_GB ))
  echo $(( (e4_per_month * 24 + HOURS_PER_MONTH * 50) / (HOURS_PER_MONTH * 100) ))
}

# hourly_cost <instance-type> -> ≈$0.27/hr (to the cent), or "no price for X"
hourly_cost() {
  local rate
  rate=$(price_hourly_e4 "$1") || { echo "no price for $1"; return 0; }
  echo "≈$(fmt_cents $(( (rate + 50) / 100 )))/hr"
}

# storage_month -> ≈$9.60/mo, what the root volume costs while stopped
storage_month() { echo "≈$(fmt_cents $(( (GP3_GB_MONTH_E4 * ROOT_GB + 50) / 100 )))/mo"; }

# cost_line <account> <instance-type> <region> -> the one line up prints before
# launching anything (R14): who pays, what, where, and what it costs
cost_line() {
  join_dot "account $1" "$2" "$3" "$(hourly_cost "$2") running" "$(storage_month) stopped" \
    "prices approximate, as of $PRICE_DATE"
}

# --- Stop cause --------------------------------------------------------------
# stop_cause <StateReason.Code> <StateTransitionReason> -> phrase
# EC2 records no time for an instance-initiated stop, so the idle phrase has
# none. That code also covers the dead-man timer and a `poweroff` typed on the
# host: EC2 cannot tell them apart, and all three are the host stopping itself.
stop_cause() {
  local epoch
  case $1 in
    Client.InstanceInitiatedShutdown) echo 'stopped by idle timer' ;;
    Client.UserInitiatedShutdown)
      if epoch=$(reason_epoch "$2"); then echo "stopped by you $(local_hhmm "$epoch")"
      else echo 'stopped by you'
      fi ;;
    None|'') echo stopped ;;
    *)       echo "stopped ($1)" ;;
  esac
}

# stuck_for <StateTransitionReason> <now> -> how long a manual stop has been
# running, when over STUCK_STOPPING_S (EC2 normally stops in under 2 minutes).
# Fails when shorter, or when the reason has no time (instance-initiated).
readonly STUCK_STOPPING_S=600
stuck_for() {
  local since
  since=$(reason_epoch "$1") || return 1
  (( $2 - since > STUCK_STOPPING_S )) || return 1
  fmt_duration $(( $2 - since ))
}

# --- Status lines ------------------------------------------------------------
# join_dot <field>... -> the non-empty fields joined by " · "
join_dot() {
  local out='' f
  for f in "$@"; do
    [[ -z $f ]] || out=${out:+$out · }$f
  done
  printf '%s\n' "$out"
}

# uptime_field <instance-type> <seconds|""> -> "up 2h10m (≈$0.59)"
uptime_field() {
  [[ -n $2 ]] || { echo 'uptime unknown'; return 0; }
  echo "up $(fmt_duration "$2") ($(running_cost "$1" "$2"))"
}

# status_headline <state> [type] [uptime-s] [stop-cause] [guest] [autostop]
# The money-and-time line. [guest] and [autostop] are extension points: U3
# passes the guest field ("guest ready", "guest intact"), U4 replaces the
# autostop field with the host's own countdown. U1 passes "" and the
# configured idle window.
status_headline() {
  local state=$1 type=${2:-} up=${3:-} cause=${4:-} guest=${5:-} autostop=${6:-}
  case $state in
    absent)        join_dot absent 'no lab instance' 'next: helios-lab up' ;;
    running)       join_dot running "$guest" "$(uptime_field "$type" "$up")" "$autostop" ;;
    stopped)       join_dot "$cause" "$guest" "≈$(fmt_cents "$(storage_day_cents)")/day" ;;
    stopping)      join_dot stopping 'disk kept' ;;
    pending)       join_dot pending starting ;;
    shutting-down) join_dot shutting-down terminating ;;
    *)             join_dot "$state" ;;
  esac
}

# autostop_field <idle-minutes> -> the U1 auto-stop field (U4 replaces it)
autostop_field() { echo "auto-stops after $1 min idle"; }

# status_details <id> <az> <type> <public-ip> -> indented detail lines
status_details() {
  printf '  %-9s %s\n' instance "$1" zone "$2" type "$3"
  [[ $4 == None || -z $4 ]] || printf '  %-9s %s\n' ip "$4"
  printf '  %-9s %s\n' prices "approximate, as of $PRICE_DATE"
}

# --- Anomalies ---------------------------------------------------------------
# Anomalies print above the headline, each as one "! " line.
# anomaly <kind> [args] — kinds: duplicates, orphan-group, stuck-stopping,
# ip-not-allowed, ip-unknown (U1); from status's host probe (U3):
# guest-mismatch <text>, provision-failed <stage> <reason>,
# host-silent <seconds> <ssh said>, probe-failed <what>
anomaly() {
  case $1 in
    duplicates)       printf '! %s\n' "$2" ;;
    orphan-group)     printf '! security group %s exists with no instance: up reuses it, destroy --yes deletes it\n' "$2" ;;
    stuck-stopping)   printf '! stopping for %s (usually under 2 min): check the instance in the EC2 console\n' "$2" ;;
    ip-not-allowed)   printf "! this Mac's IP (%s) is not allowed in the security group: helios-lab up updates the rule\n" "$2" ;;
    ip-unknown)       printf "! could not check this Mac's IP: checkip.amazonaws.com gave no IPv4 address\n" ;;
    guest-mismatch)   printf '! %s\n' "$2" ;;
    provision-failed) printf '! provision failed at stage %s: %s; helios-lab up runs it again\n' "$2" "$3" ;;
    host-silent)      printf '! the host did not answer ssh within %ss (%s): it may be stopping itself; helios-lab up reconnects\n' "$2" "$3" ;;
    probe-failed)     printf "! the host's status probe failed (%s): helios-lab up pushes the current helper\n" "$2" ;;
    *)                return 1 ;;
  esac
}

# count_rows <rows> -> number of non-empty lines
count_rows() {
  local n=0 line
  while IFS= read -r line; do
    [[ -z $line ]] || n=$(( n + 1 ))
  done <<< "$1"
  echo "$n"
}

# instance_list <rows> -> "i-a (running), i-b (stopped)"
instance_list() {
  local id state rest out=''
  while IFS=$'\037' read -r id state rest; do
    [[ -z $id ]] || out="${out:+$out, }$id ($state)"
  done <<< "$1"
  echo "$out"
}

# duplicates_message <rows> -> the conflict report. Invariant: at most one live
# tagged instance exists; a violation is reported, never auto-resolved.
duplicates_message() {
  echo "$(count_rows "$1") lab instances exist; at most one should: $(instance_list "$1"). Terminate the extra one by hand"
}

# duplicates_report <rows> -> what status prints for a conflict (it lists, never refuses)
duplicates_report() {
  anomaly duplicates "$(duplicates_message "$1")"
  join_dot conflict "$(count_rows "$1") instances" 'up, stop and ssh refuse until one remains'
}

# --- Validation --------------------------------------------------------------
# Families with nested virtualization on non-metal sizes (Feb 2026: C8i/M8i/
# R8i and their -flex; Jun 2026: C7i/M7i/R7i). Metal sizes are out of scope.
readonly NESTED_VIRT_FAMILIES='c8i m8i r8i c8i-flex m8i-flex r8i-flex c7i m7i r7i'

# instance_type_ok <type> -> 0 for a non-metal size of a nested-virt family
instance_type_ok() {
  [[ $1 == *.* ]] || return 1
  case " $NESTED_VIRT_FAMILIES " in
    *" ${1%%.*} "*) ;;
    *) return 1 ;;
  esac
  case ${1#*.} in
    large|xlarge|[1-9]xlarge|[1-9][0-9]xlarge) return 0 ;;
    *) return 1 ;;
  esac
}

# nested_virt_families -> the families for a usage message
nested_virt_families() { echo "$NESTED_VIRT_FAMILIES"; }

# idle_minutes_ok <minutes> -> 0 for a multiple of 5 in 5..720. The idle check
# ticks every 5 min (U4), and 12h matches keep's cap.
idle_minutes_ok() {
  [[ $1 =~ ^[1-9][0-9]{0,3}$ ]] || return 1
  (( $1 % 5 == 0 && $1 <= 720 ))
}

# is_ipv4 <text> -> 0 for a strict dotted quad: no leading zeros, octets <= 255
is_ipv4() {
  local re='^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$' a b c d
  [[ $1 =~ $re ]] || return 1
  IFS=. read -r a b c d <<< "$1"
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 ))
}

# ingress_allows <ipv4> <rules> -> 0 when some ingress rule admits tcp/22 from
# exactly <ipv4>/32. <rules>: US-delimited "proto from to cidr" rows (Q_INGRESS).
ingress_allows() {
  local want="$1/32" proto from to cidr
  while IFS=$'\037' read -r proto from to cidr; do
    [[ $cidr == "$want" ]] || continue
    case $proto in
      -1)    return 0 ;;
      tcp|6) if port_in_range 22 "$from" "$to"; then return 0; fi ;;
    esac
  done <<< "$2"
  return 1
}

# port_in_range <port> <from> <to> -> 0 when from <= port <= to (numeric only)
port_in_range() {
  [[ $2 =~ ^[0-9]+$ && $3 =~ ^[0-9]+$ ]] || return 1
  (( $2 <= $1 && $1 <= $3 ))
}

# --- Guest sizing (create path) ----------------------------------------------
# The guest takes 3 vCPU and 8 GiB (plan: "Host and guest"). The host needs
# more of both for itself and QEMU, so a type that can't exceed them is a
# usage error at create, before any launch call. Pure: vCPUs follow from the
# size and memory from the family's ratio (c 2, m 4, r 8 GiB per vCPU), which
# holds for every family instance_type_ok admits. No describe-instance-types
# call, because the shipped policy doesn't grant it.
readonly GUEST_VCPUS=3 GUEST_MEM_GIB=8

# type_vcpus <type> -> vCPUs: large 2, xlarge 4, Nxlarge 4N
type_vcpus() {
  local size=${1#*.}
  case $size in
    large)  echo 2 ;;
    xlarge) echo 4 ;;
    *xlarge)
      [[ ${size%xlarge} =~ ^[1-9][0-9]?$ ]] || return 1
      echo $(( 4 * ${size%xlarge} )) ;;
    *) return 1 ;;
  esac
}

# type_mem_gib <type> -> GiB of memory
type_mem_gib() {
  local v
  v=$(type_vcpus "$1") || return 1
  case ${1:0:1} in
    c) echo $(( v * 2 )) ;;
    m) echo $(( v * 4 )) ;;
    r) echo $(( v * 8 )) ;;
    *) return 1 ;;
  esac
}

# guest_fits <type> -> 0 when the host has more vCPUs and memory than the guest
guest_fits() {
  local v m
  v=$(type_vcpus "$1") || return 1
  m=$(type_mem_gib "$1") || return 1
  (( v > GUEST_VCPUS && m > GUEST_MEM_GIB ))
}

# --- Preflight verdicts ------------------------------------------------------
# cli_version_of <`aws --version` output> -> 2.38.5, from "aws-cli/2.38.5 Python/..."
cli_version_of() {
  [[ $1 =~ ^aws-cli/([0-9]+\.[0-9]+\.[0-9]+)([^0-9.]|$) ]] || return 1
  echo "${BASH_REMATCH[1]}"
}

# version_at_least <have> <want> -> 0 when x.y.z <have> >= <want>, numerically
version_at_least() {
  local a b c x y z
  IFS=. read -r a b c <<< "$1"
  IFS=. read -r x y z <<< "$2"
  (( 10#$a > 10#$x || (10#$a == 10#$x && (10#$b > 10#$y || (10#$b == 10#$y && 10#$c >= 10#$z))) ))
}

# is_root_arn <arn> -> 0 for an account's root credentials (R9 refuses them)
is_root_arn() { [[ $1 =~ ^arn:aws[a-z-]*:iam::[0-9]{12}:root$ ]]; }

# pick_subnet <offered-azs> <subnet-rows> -> "subnet-id<US>az": the default
# subnet in the alphabetically first zone that offers the type (deterministic,
# so retries land in the same place). Fails when no default subnet qualifies.
# <offered-azs>: one zone per line. <subnet-rows>: US-delimited "id az" (Q_SUBNETS).
pick_subnet() {
  local id az best='' best_az=''
  while IFS=$'\037' read -r id az; do
    [[ -n $id ]] || continue
    zone_listed "$az" "$1" || continue
    if [[ -z $best_az || $az < $best_az ]]; then best=$id best_az=$az; fi
  done <<< "$2"
  [[ -n $best ]] || return 1
  printf '%s\037%s\n' "$best" "$best_az"
}

# zone_listed <zone> <zones, one per line> -> 0 when listed exactly
zone_listed() {
  case $'\n'$2$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
    *)                return 1 ;;
  esac
}

# --- Lab key -----------------------------------------------------------------
# fingerprint_of <`ssh-keygen -lf` line> -> SHA256:<43 base64 chars>
fingerprint_of() {
  local re='^[0-9]+ (SHA256:[A-Za-z0-9+/]{43}) '
  [[ $1 =~ $re ]] || return 1
  echo "${BASH_REMATCH[1]}"
}

# lab_key_verdict <local-fingerprint|""> <KeyFingerprint tag|None|""> -> ok | missing | mismatch
# Invariant: the lab key is never regenerated while a tagged instance exists.
# Neither verdict but ok lets up continue, and neither leads to a new key:
# the guest baked the key in at create time, so only destroy recovers.
# An untagged instance counts as a mismatch: its key can't be shown to match.
lab_key_verdict() {
  if [[ -z $1 ]]; then echo missing
  elif [[ $2 == "$1" ]]; then echo ok
  else echo mismatch
  fi
}

# --- Security-group convergence ----------------------------------------------
# The target (R10): egress exactly tcp 80 and 443 to 0.0.0.0/0; ingress
# exactly tcp/22 from the caller's /32. A plan lists the calls that reach it:
#   revoke <rule-id> <rule text>    authorize <port|cidr>
# An empty plan means converged, so a converged group costs no calls and no
# output. Applying a plan reaches the target, and the plan of the target is
# empty (tests/mutations.test.sh checks both).
# <rules>: US-delimited "rule-id is-egress proto from to cidr" rows (Q_RULES);
# is-egress prints True/False, a missing CidrIpv4 (IPv6, group or
# prefix-list source) prints None, and every such rule is revoked.
readonly EGRESS_PORTS='80 443'

# egress_plan <rules>
egress_plan() {
  local id egress proto from to cidr have=' ' port
  while IFS=$'\037' read -r id egress proto from to cidr; do
    [[ $egress == True ]] || continue
    if port=$(wanted_egress_port "$proto" "$from" "$to" "$cidr"); then have="$have$port "
    else echo "revoke $id $(rule_text "$proto" "$from" "$to" "$cidr")"
    fi
  done <<< "$1"
  for port in $EGRESS_PORTS; do
    [[ $have == *" $port "* ]] || echo "authorize $port"
  done
}

# wanted_egress_port <proto> <from> <to> <cidr> -> the port of a target egress rule
wanted_egress_port() {
  if is_tcp "$1" && [[ $2 == "$3" && $4 == 0.0.0.0/0 && " $EGRESS_PORTS " == *" $2 "* ]]; then
    echo "$2"
  else
    return 1
  fi
}

# ingress_plan <caller-ipv4> <rules>
ingress_plan() {
  local want="$1/32" id egress proto from to cidr kept=no
  while IFS=$'\037' read -r id egress proto from to cidr; do
    [[ $egress == False ]] || continue
    if [[ $kept == no ]] && is_tcp "$proto" && [[ $from == 22 && $to == 22 && $cidr == "$want" ]]; then
      kept=yes
    else
      echo "revoke $id $(rule_text "$proto" "$from" "$to" "$cidr")"
    fi
  done <<< "$2"
  [[ $kept == yes ]] || echo "authorize $want"
}

is_tcp() { [[ $1 == tcp || $1 == 6 ]]; }

# rule_text <proto> <from> <to> <cidr> -> "tcp/22 198.51.100.7/32", "all-traffic 0.0.0.0/0"
rule_text() {
  local what src=$4
  [[ $src != None ]] || src='a non-IPv4 source'
  if [[ $1 == -1 ]]; then what=all-traffic
  elif [[ $2 == "$3" ]]; then what="$1/$2"
  else what="$1/$2-$3"
  fi
  echo "$what $src"
}

# plan_args <verb> <plan> -> the arguments of that verb's lines, space-separated
plan_args() {
  local verb arg rest out=''
  while read -r verb arg rest; do
    [[ $verb != "$1" ]] || out="${out:+$out }$arg"
  done <<< "$2"
  printf '%s\n' "$out"
}

# sg_note <label> <target> <plan> -> one line when the plan changes anything,
# naming what it removes; nothing for an empty plan
sg_note() {
  [[ -n $3 ]] || return 0
  local verb arg rest removed=''
  while read -r verb arg rest; do
    [[ $verb != revoke ]] || removed="${removed:+$removed, }$rest"
  done <<< "$3"
  echo "$1: $2${removed:+ (removed $removed)}"
}

# --- Lifecycle messages ------------------------------------------------------
# type_override_note <HELIOS_LAB_INSTANCE_TYPE|""> <actual-type> <instance-id>
# -> a warning when an explicit override can't apply. It applies only at
# create: changing a stopped instance's type needs ModifyInstanceAttribute,
# which the shipped policy withholds.
type_override_note() {
  [[ -n $1 && $1 != "$2" ]] || return 0
  echo "HELIOS_LAB_INSTANCE_TYPE=$1 applies only at create; $3 stays $2"
}

# running_line <id> <public-ip> <type> <deadman-epoch> -> the line up ends its
# instance stage with
running_line() {
  join_dot 'host running' "$1" "$2" "$(hourly_cost "$3")" \
    "stops itself by about $(local_hhmm "$4") (dead-man timer)"
}

# stopped_line -> what stop ends with: compute billing ended, storage didn't
stopped_line() { join_dot stopped 'disk intact' "$(storage_month) storage continues"; }

# not_running_message <state> <instance-id> <StateReason.Code> <StateTransitionReason>
# -> why ssh and console refuse a host that isn't running, ending in the
# command that fixes it. They never start it themselves: it would bill
# (plan: "Explicit over implicit"). The stop cause is U1's: an idle stop
# (which also covers the dead-man timer) has no time, a manual one shows it.
not_running_message() {
  case $1:$3 in
    stopped:Client.InstanceInitiatedShutdown) echo "$2 stopped itself (idle) — run helios-lab up" ;;
    stopped:*)       echo "$2 is $(stop_cause "$3" "$4") — run helios-lab up" ;;
    stopping:*)      echo "$2 is stopping — run helios-lab up (it waits, then starts it again)" ;;
    pending:*)       echo "$2 is starting — run helios-lab up (it waits until it runs)" ;;
    shutting-down:*) echo "$2 is being terminated — run helios-lab up for a new lab" ;;
    absent:*)        echo 'no lab instance — run helios-lab up' ;;
    *)               echo "$2 is $1 — run helios-lab up" ;;
  esac
}

# stopped_while_connecting <instance-id> <StateReason.Code> <StateTransitionReason>
# -> what up says when ssh to the host failed because the host stopped: an
# idle poweroff (or the dead-man timer) can land between "saw running" and
# "connected" (plan: Host lifecycle)
stopped_while_connecting() {
  case $2 in
    Client.InstanceInitiatedShutdown) echo "host $1 stopped itself (idle) while up was connecting" ;;
    *)                                echo "host $1 was $(stop_cause "$2" "$3") while up was connecting" ;;
  esac
}

# ready_screen <elapsed-s|""> <dead-man epoch> -> what a successful up ends
# with (R14): the smoke check's result, one DTrace one-liner to try in the
# guest, the stop that is armed, then one runnable next command.
# --- Extension point (U4) ---
# Until U4's push enables the idle timer, the dead-man timer is the armed
# stop, so that is what this names; U4 replaces it with the idle countdown
# and the keep note.
readonly DTRACE_TRY="pfexec dtrace -n 'syscall:::entry { @[execname] = count(); }'"
ready_screen() {
  join_dot "guest ready${1:+ in $(fmt_elapsed "$1")}" illumos 'dtrace ok'
  echo "  in the guest, try: $DTRACE_TRY  (Ctrl-C prints system calls by process)"
  echo "  the host stops itself by about $(local_hhmm "$2") (dead-man timer, 2h after boot) · helios-lab stop pauses billing now"
  echo 'next: helios-lab ssh'
}

# billing_notice <instance-id|""> <type> <launch-epoch> -> what a failed or
# interrupted up prints once a host may be billing. An empty id means a launch
# or start call was in flight, so whether a host exists is unknown.
# Invariant (plan): from launch onward every boot has a stop armed. Until U4's
# push enables the idle timer, that is the user-data dead-man timer; U4 names
# the idle timer here once it exists.
billing_notice() {
  if [[ -z $1 ]]; then
    printf '%s\n' 'a launch or start was in flight: helios-lab status shows whether the host is up' \
      "  a running host bills $(hourly_cost "$2") until its dead-man timer stops it, 2h after boot"
  else
    printf '%s\n' "host $1 is running and billing ($(hourly_cost "$2"))" \
      "  it stops itself by about $(local_hhmm "$(deadman_epoch "$3")") (dead-man timer, 2h after boot)"
  fi
  echo '  helios-lab up reattaches · helios-lab stop pauses it now'
}

# destroy_preview <heading> <instance-rows> <root-volume-rows> <group-ids> <key-path>
# -> what destroy deletes. Invariant: destroy --yes terminates only what this
# lists, so --yes prints it from the same discovery it then acts on.
# <root-volume-rows>: US-delimited "volume-id delete-on-termination" (Q_ROOT_VOLUMES).
destroy_preview() {
  local id state type rest vol dot group
  echo "$1"
  while IFS=$'\037' read -r id state type rest; do
    [[ -z $id ]] || printf '  %-9s %s (%s, %s)\n' instance "$id" "$state" "$type"
  done <<< "$2"
  while IFS=$'\037' read -r vol dot; do
    [[ -z $vol ]] || printf '  %-9s %s (%s)\n' volume "$vol" "$(volume_fate "$dot")"
  done <<< "$3"
  while IFS= read -r group; do
    [[ -z $group ]] || printf '  %-9s %s (security group)\n' group "$group"
  done <<< "$4"
  [[ -z $2 ]] || echo '  guest disk and seed will be lost; rebuild ≈10 min + 2.4 GB download'
  echo "kept: the lab key $5"
}

# deleted_volumes <root-volume-rows> -> the IDs that go with their instance, space-separated
deleted_volumes() {
  local vol dot out=''
  while IFS=$'\037' read -r vol dot; do
    [[ -z $vol || $dot != True ]] || out="${out:+$out }$vol"
  done <<< "$1"
  printf '%s\n' "$out"
}

# volume_fate <DeleteOnTermination> -> what terminating its instance does to it
volume_fate() {
  case $1 in
    True) echo 'root disk, deleted with its instance' ;;
    *)    echo 'DeleteOnTermination is off: it survives; delete it in the EC2 console' ;;
  esac
}

# row_ids <instance-rows> -> their instance IDs, space-separated
row_ids() {
  local id rest out=''
  while IFS=$'\037' read -r id rest; do
    [[ -z $id ]] || out="${out:+$out }$id"
  done <<< "$1"
  printf '%s\n' "$out"
}
