# shellcheck shell=bash
#
# helios-lab state.sh — pure decisions: EC2 state -> up action, stop cause,
# status lines, the cost table, and input validation.
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
# anomaly <kind> [arg] — kinds: duplicates, orphan-group, stuck-stopping,
# ip-not-allowed, ip-unknown
anomaly() {
  case $1 in
    duplicates)     printf '! %s\n' "$2" ;;
    orphan-group)   printf '! security group %s exists with no instance: up reuses it, destroy --yes deletes it\n' "$2" ;;
    stuck-stopping) printf '! stopping for %s (usually under 2 min): check the instance in the EC2 console\n' "$2" ;;
    ip-not-allowed) printf "! this Mac's IP (%s) is not allowed in the security group: helios-lab up updates the rule\n" "$2" ;;
    ip-unknown)     printf "! could not check this Mac's IP: checkip.amazonaws.com gave no IPv4 address\n" ;;
    *)              return 1 ;;
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
