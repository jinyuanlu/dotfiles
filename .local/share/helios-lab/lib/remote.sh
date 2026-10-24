# shellcheck shell=bash
#
# helios-lab remote.sh — everything that reaches the host (U2): host-key
# verification against the console, the per-command ssh fragment, the push
# of host/ and its config, and following the provision unit. U3: the guest's
# smoke check and bring-up at the end of up, the read-only probe status
# runs, and the ssh calls behind `ssh` and `console`.
#
# Pure parsers come first, each marked (pure), as aws.sh keeps its error
# parsers: the console's fingerprint blocks, the host-key verdict, ssh's
# error classes, the provision progress protocol and the host's status
# reply. Effects follow.
#
# Call contract (tests/stubs/ssh enforces it, exit 98 otherwise):
#   ssh -F <state-dir>/ssh_config [-t] [-o ConnectTimeout=N] [-o BatchMode=yes] <host|guest> [<remote command>]
# - -F always, and first: every connection goes through the rendered
#   fragment, so its host-key settings and dedicated known_hosts can't be
#   bypassed, and ~/.ssh/config never applies. Only those options may
#   follow: -t for the console, the two -o for status's 3-second probe.
# - The remote command is one argument; the remote shell parses it. `ssh`
#   without one is an interactive login (helios-lab ssh).
# ssh-keyscan, which reads the key a host offers, is the one call without -F.
#
# Requires from the entry: PROFILE, SSH_CONFIG, KNOWN_HOSTS, LAB_KEY,
# RETRY_SECONDS, IDLE_MINUTES, ENGVM_PIN, HELIOS_LAB_HOME, state_dir_ensure,
# die, warn, EX_*; aws.sh: aws_console_output, first_line, REGION, US;
# state.sh: fmt_elapsed, fmt_duration, join_dot, count_rows, fingerprint_of,
# anomaly; render.sh: the renderers and ED25519_PUB_RE.

readonly HOST_HELPER=/usr/local/libexec/helios-lab/helios-lab-host
readonly PROVISION_UNIT=helios-lab-provision.service
# Polls, each RETRY_SECONDS (10 s) apart. The spike's first boot printed the
# fingerprint blocks within a few minutes and provisioned in about 10.
readonly CONSOLE_ATTEMPTS=60      # 10 min for the console's fingerprint block
readonly KEYSCAN_ATTEMPTS=12      # 2 min more for sshd to offer its key
# 30 min: a first provision took about 7 (packages 40 s, seed 311 s, the
# create about a minute), and the seed stage's own timeout is 20.
readonly PROGRESS_ATTEMPTS=180
# The guest's smoke check, polled within the plan's timeouts. The spike's
# guest had a DHCP lease 77 s after create.sh started and passed at once; a
# restarted, verified guest was ready 42 s after the host started.
readonly GUEST_FIRST_BOOT_ATTEMPTS=180   # 30 min
readonly GUEST_RESTART_ATTEMPTS=30       # 5 min
# "Boots" means this, through the guest alias (R8): uname -o names the OS
# (uname -a prints SunOS and never "illumos"), and a DTrace probe that ends
# itself runs to completion under pfexec (a bare BEGIN would run forever).
readonly SMOKE_UNAME='uname -o'
readonly SMOKE_DTRACE="pfexec dtrace -n 'BEGIN { exit(0); }'"
# On the host, as helios-lab-host names them (tests check they agree).
readonly GUEST_MARKER=/var/lib/helios-lab/guest-verified
readonly GUEST_NAME=helios   # engvm's VM name, which libnss-libvirt resolves
readonly GUEST_CONSOLE_COMMAND='virsh -c qemu:///system console --force helios'
readonly RFD26_URL=https://rfd.shared.oxide.computer/rfd/0026
readonly PROBE_TIMEOUT_S=3   # status's probes (plan: U1, "3-second probes")

# --- Console fingerprints (pure) ---------------------------------------------
# Two blocks carry the host's fingerprints on the serial console:
# - the per-boot one that user-data's helios-lab-hostkeys.service prints
#   (render.sh), on EVERY boot, so verification also works after a stop/start
#   and after the known_hosts cache is lost
# - cloud-init's, once per instance, each line behind a syslog prefix
# On later boots systemd's own console output interleaves INSIDE the per-boot
# block, with CRLF line ends (fixtures/get-console-output.latest.later-boot.txt),
# so only fingerprint-shaped lines between the markers count:
#   <bits> SHA256:<43 base64> <comment> (<TYPE>)
readonly HOSTKEYS_BEGIN='-----BEGIN HELIOS-LAB HOST KEYS-----'
readonly HOSTKEYS_END='-----END HELIOS-LAB HOST KEYS-----'
readonly CLOUDINIT_BEGIN='-----BEGIN SSH HOST KEY FINGERPRINTS-----'
readonly CLOUDINIT_END='-----END SSH HOST KEY FINGERPRINTS-----'
readonly FP_LINE_RE='^[0-9]+ (SHA256:[A-Za-z0-9+/]{43}) ([^[:cntrl:]]+ )?\(ED25519\)$'

# console_fingerprints <console text> -> each distinct ED25519 fingerprint
# inside a complete block (its END seen), one per line, in order; nothing
# while no block is complete, which includes the buffered (non --latest)
# output and the CLI's "None" for no output at all
console_fingerprints() {
  local line in='' block='' out=''
  while IFS= read -r line; do
    line=${line//$'\r'/}
    case $line in
      *"$HOSTKEYS_BEGIN"*)  in=ours block='' ;;
      *"$CLOUDINIT_BEGIN"*) in=cloud block='' ;;
      *"$HOSTKEYS_END"*)    [[ $in != ours ]] || out=$(fp_union "$out" "$block"); in='' ;;
      *"$CLOUDINIT_END"*)   [[ $in != cloud ]] || out=$(fp_union "$out" "$block"); in='' ;;
      *)                    [[ -z $in ]] || block="$block$(fp_ed25519 "$line")"$'\n' ;;
    esac
  done <<< "$1"
  printf '%s' "$out"
}

# fp_ed25519 <console line> -> its ED25519 fingerprint, or nothing. A
# cloud-init line loses its "<14>Mon DD HH:MM:SS cloud-init: " prefix first.
fp_ed25519() {
  local line=${1##*cloud-init: }
  [[ $line =~ $FP_LINE_RE ]] || return 0
  printf '%s' "${BASH_REMATCH[1]}"
}

# fp_union <fingerprints> <more, one per line> -> the first, plus each of the
# others not in it yet, one per line
fp_union() {
  local out=$1 fp
  while IFS= read -r fp; do
    [[ -n $fp && $'\n'$out$'\n' != *$'\n'"$fp"$'\n'* ]] || continue
    out=${out:+$out$'\n'}$fp
  done <<< "$2"
  printf '%s' "$out"
}

# hostkey_verdict <console fingerprints> <offered fingerprint> -> pending | match | mismatch
# pending: no complete block yet, so keep polling. match: the console shows
# exactly one ED25519 key, and it is the one offered. Anything else is a
# mismatch: an offered key the console never printed, or blocks that disagree.
# There is no trust-on-first-use verdict.
hostkey_verdict() {
  if [[ -z $1 ]]; then echo pending
  elif [[ $1 == "$2" ]]; then echo match
  else echo mismatch
  fi
}

# keyscan_key <ip> <ssh-keyscan output> -> "ssh-ed25519 <base64>": the one
# ED25519 key the host at <ip> offered. Comment lines (keyscan prints the
# server banner as "# ip:22 SSH-2.0-...") and other types are skipped. Fails
# when none was offered, or two different ones were.
keyscan_key() {
  local host type b64 rest found=''
  while read -r host type b64 rest; do
    [[ $host == "$1" && $type == ssh-ed25519 && "ssh-ed25519 $b64" =~ $ED25519_PUB_RE ]] || continue
    [[ -z $found || $found == "$b64" ]] || return 1
    found=$b64
  done <<< "$2"
  [[ -n $found ]] || return 1
  echo "ssh-ed25519 $found"
}

# --- ssh errors (pure) -------------------------------------------------------
# ssh_error_class <ssh stderr> -> hostkey | auth | network | other, for an
# exit 255 (ssh's own failure, not the remote command's)
ssh_error_class() {
  case $1 in
    *'Host key verification failed'*|*'REMOTE HOST IDENTIFICATION HAS CHANGED'*|*'host key is known'*) echo hostkey ;;
    *'Permission denied'*|*'Too many authentication failures'*) echo auth ;;
    *'timed out'*|*'Connection refused'*|*'No route to host'*|*'Network is unreachable'*|\
    *'Could not resolve hostname'*|*'Connection closed'*|*'Connection reset'*) echo network ;;
    *) echo other ;;
  esac
}

# --- Provision progress protocol (pure) --------------------------------------
# Keep in step with host/helios-lab-host, which writes it. The helper
# appends one line per event to /var/lib/helios-lab/progress (and prints it
# to the unit's journal):
#   <epoch> <name> <event> [<message>]
#   name:    provision (the run itself) or a stage (packages, libvirt, guard,
#            engvm, seed, guest), [a-z][a-z0-9-]*
#   event:   start | done | skip | fail
#   message: one line; for fail, the reason; for done, an optional summary
# A run begins with "provision start" and ends with "provision done" or
# "provision fail <stage>". The unit's ExecStartPre empties the file, and
# `systemctl start` (Type=exec) returns only after that, so once up has
# started the unit, the file never shows an earlier run.
# `helios-lab-host progress` prints the file, then one last line:
#   unit <ActiveState> <Result>
# up prints one line per finished stage (done, skip or fail) as polls reveal
# it, plus one when the seed stage starts (the RFD 26 hint, R11), and stops
# at "provision done", at a fail, or when the unit stops first.

# progress_events <snapshot> -> one "name<US>event<US>elapsed-s<US>message"
# row per stage event, in order. Elapsed counts from the stage's start
# line; a start and a skip have none.
progress_events() {
  local epoch name event msg starts=' ' began
  while read -r epoch name event msg; do
    [[ $epoch =~ ^[0-9]+$ && $name != provision ]] || continue
    case $event in
      start)          starts="$starts$name=$epoch "
                      printf '%s\n' "$name${US}start$US$US" ;;
      done|skip|fail) began=$(stage_began "$name" "$starts")
                      printf '%s\n' "$name$US$event$US${began:+$(( epoch - began ))}$US$msg" ;;
    esac
  done <<< "$1"
}

# stage_began <name> <" name=epoch ..."> -> the epoch of that stage's last start
stage_began() {
  local pair out=''
  for pair in $2; do
    [[ ${pair%%=*} != "$1" ]] || out=${pair#*=}
  done
  printf '%s' "$out"
}

# stage_line <name> <event> <elapsed-s|""> <message|""> -> what up prints for
# one stage event: "packages · done · 41s", "guard · unchanged"; a start
# prints only where stage_start_line has something to say
stage_line() {
  local took=''
  [[ -z $3 ]] || took=$(fmt_elapsed "$3")
  case $2 in
    start) stage_start_line "$1" ;;
    done)  join_dot "$1" 'done' "$took" "$4" ;;
    skip)  join_dot "$1" unchanged ;;
    fail)  join_dot "$1" failed "$took" "$4" ;;
  esac
}

# stage_start_line <name> -> the line a starting stage gets, if any: the
# seed's 2.4 GB download is the wait RFD 26 is for (R11, runbook step 0)
stage_start_line() {
  [[ $1 == seed ]] || return 0
  join_dot seed 'fetching and verifying the 2.4 GB Helios seed (about 5 min the first time)' \
    "meanwhile, read RFD 26: $RFD26_URL"
}

# progress_lines <snapshot> -> one line per finished stage, and the seed's start line
progress_lines() {
  local name event took msg
  while IFS=$US read -r name event took msg; do
    [[ -z $name ]] || stage_line "$name" "$event" "$took" "$msg"
  done <<< "$(progress_events "$1")"
}

# progress_verdict <snapshot> -> running | done | failed<US><stage><US><reason>
# "provision done" wins; else the first fail, which is the stage's own line
# (its reason), ahead of "provision fail <stage>"; else the unit decides: an
# active unit is still running, any other state means it ended unfinished.
progress_verdict() {
  local epoch name event msg finished=no failed='' unit=''
  while read -r epoch name event msg; do
    if [[ $epoch == unit ]]; then unit="$name $event"; continue; fi
    [[ $epoch =~ ^[0-9]+$ ]] || continue
    case $name:$event in
      provision:done) finished=yes ;;
      *:fail)         [[ -n $failed ]] || failed=$name$US$msg ;;
    esac
  done <<< "$1"
  if [[ $finished == yes ]]; then echo 'done'
  elif [[ -n $failed ]]; then echo "failed$US$failed"
  else unit_verdict "$unit"
  fi
}

# unit_verdict <"ActiveState Result"|""> -> running | failed<US>provision<US><reason>
unit_verdict() {
  case ${1%% *} in
    active|activating|deactivating|reloading) echo running ;;
    '') echo "failed${US}provision${US}the host's progress reply had no unit state" ;;
    *)  echo "failed${US}provision${US}the provision unit stopped before finishing ($1)" ;;
  esac
}

# run_predates <snapshot> <push epoch> -> 0 when the run began before the
# push: it was already active when up started the unit (start is a no-op
# then), so it runs the helper and config of an earlier push
run_predates() {
  local epoch name event rest
  while read -r epoch name event rest; do
    [[ $name == provision && $event == start && $epoch =~ ^[0-9]+$ ]] || continue
    (( epoch < $2 ))
    return
  done <<< "$1"
  return 1
}

# install_epoch <install output> -> its last line, the install's epoch on the
# host's clock; 0 when it is not one, so no run counts as predating the push
install_epoch() {
  local last=${1##*$'\n'}
  if [[ $last =~ ^[0-9]+$ ]]; then echo "$last"; else echo 0; fi
}

# ssh_blip <exit status> <stderr> -> 0 for a network-class failure of ssh
# itself, which a poll may retry
ssh_blip() { (( $1 == 255 )) && [[ $(ssh_error_class "$2") == network ]]; }

# lines_after <n> <text> -> its non-empty lines after the first <n>
lines_after() {
  local n=0 line
  while IFS= read -r line; do
    n=$(( n + 1 ))
    (( n <= $1 )) || [[ -z $line ]] || printf '%s\n' "$line"
  done <<< "$2"
}

# --- Host status reply (pure) ------------------------------------------------
# Keep in step with host/helios-lab-host cmd_status, which writes it: the
# progress protocol above, then one "<key> <value>" line per guest fact
# (verified, pushed, domain, create, lease, sshd, then console lines). The
# progress parsers skip the guest lines (no epoch), these skip the rest.

# status_value <reply> <key> -> the value of its first <key> line; fails when there is none
status_value() {
  local line
  while IFS= read -r line; do
    [[ $line == "$2 "* ]] || continue
    printf '%s\n' "${line#"$2" }"
    return 0
  done <<< "$1"
  return 1
}

# console_lines <reply> -> the transcript lines it carries, oldest first
console_lines() {
  local line
  while IFS= read -r line; do
    [[ $line != 'console '* ]] || printf '%s\n' "${line#console }"
  done <<< "$1"
}

# guest_verified_of <reply> -> yes | no. Anything but an explicit "verified
# no" with a value is yes: the marker exists, even if its record is unreadable.
guest_verified_of() {
  local v
  v=$(status_value "$1" verified) || v=no
  if [[ $v == no ]]; then echo no; else echo yes; fi
}

# guest_ssh_ready <reply> -> 0 when the host sees the guest answer on tcp/22:
# its domain runs, it holds a DHCP lease, and its sshd accepts connections
guest_ssh_ready() {
  [[ $(status_value "$1" domain || true) == running && $(status_value "$1" sshd || true) == open ]] \
    && [[ $(status_value "$1" lease || echo none) != none ]]
}

# guest_wait_phrase <reply> -> how far the guest is, as the host sees it
guest_wait_phrase() {
  local domain lease
  domain=$(status_value "$1" domain) || domain=unknown
  lease=$(status_value "$1" lease) || lease=none
  if [[ $domain != running ]]; then echo "domain $domain"
  elif [[ $lease == none ]]; then echo 'domain running, no DHCP lease yet'
  elif [[ $(status_value "$1" sshd || true) != open ]]; then echo "lease $lease, sshd not listening yet"
  else echo "lease $lease, sshd listening"
  fi
}

# guest_wait_line <reply> -> what up shows while it waits: a first boot's
# latest console line, else the host's view (a restarted guest's console has
# no transcript: nothing records it once the guest is verified)
guest_wait_line() {
  local last
  last=$(console_lines "$1" | tail -1)
  if [[ -n $last ]]; then printf '%s\n' "${last:0:100}"; else guest_wait_phrase "$1"; fi
}

# guest_mismatch <reply> -> the anomaly when the verified guest was built from
# another engvm pin or sizing than the host's pushed config; nothing when
# they agree, or when either side is unknown. Invariant: a verified guest is
# never recreated, so this is reported, never applied.
guest_mismatch() {
  local built pushed bpin bsize ppin psize
  built=$(status_value "$1" verified) || return 0
  pushed=$(status_value "$1" pushed) || return 0
  [[ $built != no && $pushed != unknown ]] || return 0
  read -r bpin bsize <<< "$built"
  read -r ppin psize <<< "$pushed"
  [[ $bpin != "$ppin" || $bsize != "$psize" ]] || return 0
  echo "the guest was built from engvm @${bpin:0:7}, $bsize; the pushed config says @${ppin:0:7}, $psize." \
    "A verified guest is kept as it is; to rebuild it (its disk is lost):" \
    "helios-lab ssh host sudo rm $GUEST_MARKER, then helios-lab up"
}

# guest_field <reply> -> status's headline field for a running host
guest_field() {
  local domain create
  domain=$(status_value "$1" domain) || domain=unknown
  create=$(status_value "$1" create) || create=unknown
  if [[ $(guest_verified_of "$1") == yes ]]; then
    if [[ $domain == running ]]; then echo 'guest ready'; else echo "guest $domain"; fi
    return 0
  fi
  case $create:$domain in
    active:*|activating:*) echo 'guest first boot' ;;
    *:absent)              echo 'guest not built' ;;
    *)                     echo 'guest not verified' ;;
  esac
}

# guest_detail <reply> -> status's guest detail
guest_detail() {
  local domain verified pin sizing
  domain=$(status_value "$1" domain) || domain=unknown
  verified=$(status_value "$1" verified) || verified=no
  if [[ $verified != no ]]; then
    read -r pin sizing <<< "$verified"
    echo "$GUEST_NAME $domain · verified · engvm @${pin:0:7} · $sizing"
    return 0
  fi
  case $(guest_field "$1") in
    'guest first boot') echo "$GUEST_NAME $domain · first boot under way" ;;
    'guest not built')  echo 'not built yet: helios-lab up builds it' ;;
    *)                  echo "$GUEST_NAME $domain · not verified: the next helios-lab up recreates it" ;;
  esac
}

# provision_state <reply> -> done | running<US><stage> | failed<US><stage><US><reason> | none
# The last run, as status reports it. A run's progress outlives a reboot
# (it lives in /var/lib), so a stopped run reads as failed, which it is.
provision_state() {
  local epoch name event rest stage='' any=no verdict
  while read -r epoch name event rest; do
    [[ $epoch =~ ^[0-9]+$ ]] || continue
    any=yes
    [[ $name == provision || $event != start ]] || stage=$name
  done <<< "$1"
  verdict=$(progress_verdict "$1")
  case $any:${verdict%%"$US"*} in
    *:running) echo "running$US$stage" ;;
    no:*)      echo none ;;
    *)         echo "$verdict" ;;
  esac
}

# provision_detail <provision state> -> status's provision detail
provision_detail() {
  local kind stage reason
  IFS=$US read -r kind stage reason <<< "$1"
  case $kind in
    'done')  echo 'done' ;;
    running) echo "running${stage:+: $stage}" ;;
    failed)  echo "failed at $stage: $reason" ;;
    *)       echo 'has not run yet: helios-lab up starts it' ;;
  esac
}

# --- Smoke check (pure) ------------------------------------------------------
# uname_verdict <exit status> <output> -> illumos | other | failed | hostkey | wait
# 255 is ssh's own failure: the guest isn't reachable yet (still booting, no
# lease, sshd up before its user exists), so the poll goes on; only a
# changed host key settles it.
uname_verdict() {
  case $1 in
    0)   if [[ ${2//[[:space:]]/} == illumos ]]; then echo illumos; else echo other; fi ;;
    255) if [[ $(ssh_error_class "$2") == hostkey ]]; then echo hostkey; else echo wait; fi ;;
    *)   echo failed ;;
  esac
}

# dtrace_verdict <exit status> <output> -> ok | failed | hostkey | wait
dtrace_verdict() {
  case $1 in
    0)   echo ok ;;
    255) if [[ $(ssh_error_class "$2") == hostkey ]]; then echo hostkey; else echo wait; fi ;;
    *)   echo failed ;;
  esac
}

# guest_attempts <verified: yes|no> -> polls for the guest: a first boot
# gets the long budget, a verified guest's restart the short one
guest_attempts() {
  case $1 in
    yes) echo "$GUEST_RESTART_ATTEMPTS" ;;
    *)   echo "$GUEST_FIRST_BOOT_ATTEMPTS" ;;
  esac
}

# guest_wait_label <verified: yes|no> -> the wait's stage name
guest_wait_label() { if [[ $1 == yes ]]; then echo 'guest boot'; else echo 'first boot'; fi; }

# --- ssh arguments (pure) ----------------------------------------------------
# ssh_alias [guest|host] [cmd...] -> the alias: the first word when it names one, else guest
ssh_alias() {
  case ${1:-} in
    host|guest) echo "$1" ;;
    *)          echo guest ;;
  esac
}

# ssh_command [guest|host] [cmd...] -> the remote command: the words after
# the alias, joined by spaces as ssh itself joins them, so they reach the
# remote shell exactly as they would with plain ssh; "" means a login
ssh_command() {
  case ${1:-} in host|guest) shift ;; esac
  printf '%s\n' "$*"
}

# probe_kind <probe> / probe_body <probe> — host_probe's two parts: its first
# line (ok | unreachable | failed | unpinned | no-ip), then the rest
probe_kind() { printf '%s\n' "${1%%$'\n'*}"; }
probe_body() { [[ $1 != *$'\n'* ]] || printf '%s\n' "${1#*$'\n'}"; }

# --- ssh ---------------------------------------------------------------------
# remote_attempt <alias> <command> -> an Either, like aws_attempt: 0 with the
# remote stdout, or the exit status with ssh's stderr (on stdout, for the
# caller to classify). 255 is ssh's own failure; anything else is the remote
# command's. stdin passes through: the push sends its bundle that way.
remote_attempt() { ssh_capture "$1" "$2"; }

# ssh_capture [options] <alias> <command> -> the same Either, for any call
# the contract allows (status's probe adds its -o options)
ssh_capture() {
  local errf out rc=0
  errf=$(mktemp "${TMPDIR:-/tmp}/helios-lab.XXXXXX") || return 1
  out=$(ssh -F "$SSH_CONFIG" "$@" 2>"$errf") || rc=$?
  (( rc == 0 )) || out=$(<"$errf")
  rm -f "$errf"
  printf '%s' "$out"
  return "$rc"
}

# remote_call <alias> <command> <what it does> -> the remote stdout; dies
# with a typed code otherwise (remote_fail)
remote_call() {
  local out rc=0
  out=$(remote_attempt "$1" "$2") || rc=$?
  (( rc == 0 )) || remote_fail "$1" "$3" "$rc" "$out"
  printf '%s' "$out"
}

# remote_fail <alias> <what> <exit status> <stderr> — dies: ssh's own
# failures by class, the remote command's with its exit status
remote_fail() {
  (( $3 != 255 )) || ssh_fail "$1" "$4"
  die "$EX_FAIL" "$2 failed on the $1 (exit $3)" "the $1 said: $(first_line "$4")"
}

# ssh_fail <alias> <stderr> — dies: host key 6, network 8, others 1
ssh_fail() {
  local said
  said="ssh said: $(first_line "$2")"
  case $(ssh_error_class "$2") in
    hostkey) [[ $1 != guest ]] || die "$EX_HOSTKEY" 'the guest offered a host key other than the one pinned for it' \
               'only a guest created since it was verified has new keys, and helios-lab never recreates a verified guest' \
               "if you rebuilt it yourself, drop the pin: ssh-keygen -R <instance-id>-guest -f $KNOWN_HOSTS" "$said"
             die "$EX_HOSTKEY" "the $1 offered a host key other than the one pinned for it" \
               'the pinned key matched the console when it was pinned; a different key can mean interception' \
               "to re-verify against the console, drop the pin (helios-lab status shows the ID):" \
               "  ssh-keygen -R <instance-id> -f $KNOWN_HOSTS, then helios-lab up" "$said" ;;
    auth)    die "$EX_FAIL" "the $1 refused the lab key $LAB_KEY" \
               "if it asks for a passphrase, load it once: ssh-add --apple-use-keychain $LAB_KEY" "$said" ;;
    network) die "$EX_NET" "cannot reach the $1 over ssh" \
               "the host may have stopped itself, or this Mac's IP changed: helios-lab status" "$said" ;;
    *)       die "$EX_FAIL" "ssh to the $1 failed" "$said" ;;
  esac
}

# --- Fragment and host key ---------------------------------------------------
# host_reach <instance-id> <public-ip> — the host is safe to talk to: a fresh
# fragment for this IP, and its key pinned from the console. Every connecting
# command runs it once the ingress refresh has admitted this Mac (up: in
# up_existing and up_create; U3's ssh and console: ingress_refresh first).
host_reach() {
  [[ -n $2 && $2 != None ]] || die "$EX_FAIL" "$1 is running but has no public IPv4" 'helios-lab status shows the details'
  fragment_write "$1" "$2"
  hostkey_ensure "$1" "$2"
}

# fragment_write <instance-id> <public-ip> — renders the fragment on every
# connecting command; replaced atomically, so a concurrent reader never sees
# half a file
fragment_write() {
  local text
  text=$(render_ssh_config "$1" "$2" "$LAB_KEY" "$KNOWN_HOSTS") \
    || die "$EX_FAIL" "cannot render the ssh config for $1 at $2" "paths must be absolute and quote-free: $LAB_KEY, $KNOWN_HOSTS"
  state_dir_ensure
  printf '%s\n' "$text" > "$SSH_CONFIG.new"
  mv -f "$SSH_CONFIG.new" "$SSH_CONFIG"
}

# hostkey_pinned <instance-id> -> 0 when the dedicated known_hosts holds its alias
hostkey_pinned() { [[ -f $KNOWN_HOSTS ]] && ssh-keygen -F "$1" -f "$KNOWN_HOSTS" >/dev/null 2>&1; }

# hostkey_ensure <instance-id> <public-ip> — on first contact, or when the
# cache has lost the alias: the key the host offers must match the console's
# fingerprints (get-console-output --latest) before it is pinned under
# HostKeyAlias <instance-id>. Invariant: the host alias's known_hosts entry
# only ever comes from a key that matched the console. A mismatch, or a
# console that never shows a block, is a hard failure (exit 6), and neither
# falls back to trust-on-first-use.
hostkey_ensure() {
  hostkey_pinned "$1" && return 0
  local started fps key fp
  started=$(date +%s)
  echo "host key · waiting for $1's fingerprints on its console"
  fps=$(console_fingerprints_wait "$1") || return
  key=$(offered_key_wait "$2") || return
  fp=$(key_fingerprint "$key") || die "$EX_FAIL" "cannot fingerprint the key $2 offered"
  case $(hostkey_verdict "$fps" "$fp") in
    match) hostkey_pin "$1" "$key"
           echo "host key · ED25519 $fp matches the console · pinned · $(fmt_elapsed $(( $(date +%s) - started )))" ;;
    *)     hostkey_mismatch "$1" "$2" "$fp" "$fps" ;;
  esac
}

# console_fingerprints_wait <instance-id> -> the console's ED25519
# fingerprints; dies 6 when no block shows within CONSOLE_ATTEMPTS reads
console_fingerprints_wait() {
  local n out fps
  for (( n = 1; n <= CONSOLE_ATTEMPTS; n++ )); do
    out=$(aws_console_output "$1") || return
    fps=$(console_fingerprints "$out")
    if [[ -n $fps ]]; then printf '%s\n' "$fps"; return 0; fi
    (( n == CONSOLE_ATTEMPTS )) || sleep "$RETRY_SECONDS"
  done
  die "$EX_HOSTKEY" "$1's console showed no host-key fingerprints in $CONSOLE_ATTEMPTS reads ($(fmt_duration $(( CONSOLE_ATTEMPTS * RETRY_SECONDS ))))" \
    'without them the key the host offers cannot be verified, and helios-lab never trusts a key on first use' \
    'a first boot can be slow: run helios-lab up again in a few minutes (the host bills meanwhile)' \
    'every boot prints them again: on a host that has run for long, helios-lab stop, then helios-lab up'
}

# offered_key_wait <public-ip> -> "ssh-ed25519 <base64>"; dies 8 when the
# host offers none within KEYSCAN_ATTEMPTS scans
offered_key_wait() {
  local n out key
  for (( n = 1; n <= KEYSCAN_ATTEMPTS; n++ )); do
    out=$(ssh-keyscan -T 10 -t ed25519 "$1" 2>/dev/null) || true
    if key=$(keyscan_key "$1" "$out"); then echo "$key"; return 0; fi
    (( n == KEYSCAN_ATTEMPTS )) || sleep "$RETRY_SECONDS"
  done
  die "$EX_NET" "the host at $1 offered no ED25519 host key on tcp/22 in $KEYSCAN_ATTEMPTS tries" \
    "its security group admits ssh only from this Mac's IP: helios-lab status says whether it still does"
}

# key_fingerprint <"ssh-ed25519 <base64>"> -> its SHA256 fingerprint
key_fingerprint() {
  local f line
  f=$(mktemp "${TMPDIR:-/tmp}/helios-lab.XXXXXX") || return 1
  printf '%s\n' "$1" > "$f"
  line=$(ssh-keygen -lf "$f" 2>/dev/null) || line=''
  rm -f "$f"
  fingerprint_of "$line"
}

# hostkey_pin <instance-id> <"ssh-ed25519 <base64>"> — the only writer of
# the host alias's entry, and only after a match
hostkey_pin() {
  state_dir_ensure
  printf '%s %s\n' "$1" "$2" >> "$KNOWN_HOSTS"
  chmod 600 "$KNOWN_HOSTS"
}

# hostkey_mismatch <instance-id> <ip> <offered fingerprint> <console fingerprints> — dies 6, pinning nothing
hostkey_mismatch() {
  die "$EX_HOSTKEY" "host key mismatch: $2 offered ED25519 ${3:-(no readable key)}, but $1's console printed ${4//$'\n'/ and }" \
    'this can mean the connection is being intercepted; nothing was pinned, and nothing was sent to the host' \
    "read the console yourself: aws ec2 get-console-output --instance-id $1 --latest --output text --profile $PROFILE --region $REGION"
}

# --- Push --------------------------------------------------------------------
# The push's remote command, as root: unpack the bundle (stdin) into a fresh
# directory, then hand that directory to the helper the bundle carries, so
# the newest helper always does the install (host/helios-lab-host install).
readonly PUSH_COMMAND="sudo bash -c 'stage=\$(mktemp -d /tmp/helios-lab-push.XXXXXX) && cd \"\$stage\" && bash -s && exec bash ./helios-lab-host install \"\$stage\"'"

# host_push -> the install's epoch (host clock). Every up copies host/ and
# the rendered host config and installs them, so a fix in this repo reaches
# an existing host (R13). Until U4 lands, nothing in the push touches the
# dead-man timer: it stays armed.
host_push() {
  local bundle out
  bundle=$(push_bundle) || die "$EX_FAIL" "cannot bundle $HELIOS_LAB_HOME/host for the push" \
    'every host file needs a plain name, and none may hold the line HELIOS_LAB_PUSH_EOF'
  out=$(remote_call host "$PUSH_COMMAND" 'installing the host code' <<< "$bundle") || return
  install_epoch "$out"
}

# push_line — what up prints once the push is installed
push_line() { echo "push · host code and config installed · idle $IDLE_MINUTES min · engvm @${ENGVM_PIN:0:7}"; }

# push_bundle -> the bundle: every file under host/, then host.conf
push_bundle() {
  local f conf
  local -a files=()
  for f in "$HELIOS_LAB_HOME"/host/*; do
    [[ ! -f $f ]] || files+=("${f##*/}" "$(<"$f")")
  done
  (( ${#files[@]} > 0 )) || return 1
  conf=$(render_host_config "$IDLE_MINUTES" "$ENGVM_PIN") || return 1
  render_push_bundle "${files[@]}" host.conf "$conf"
}

# --- Provision ---------------------------------------------------------------
# provision_start — a no-op when the unit is already active (an earlier up
# that was interrupted): the follow below then attaches to that run
provision_start() {
  local out rc=0
  out=$(remote_attempt host "sudo systemctl start $PROVISION_UNIT" < /dev/null) || rc=$?
  (( rc != 0 )) || return 0
  (( rc != 255 )) || ssh_fail host "$out"
  provision_failed provision "systemctl start $PROVISION_UNIT failed: $(first_line "$out")"
}

# provision_follow <push epoch> — polls the unit's progress and prints each
# stage as it finishes, until the run is done; a failure dies naming its
# stage. A run that predates the push (an interrupted up left it active)
# finishes with the old code, so it is started once more with the new: the
# push's changes take effect on this up, not the next (R13).
provision_follow() {
  local n printed=0 restarted=no snapshot lines verdict kind stage reason
  for (( n = 1; n <= PROGRESS_ATTEMPTS; n++ )); do
    (( n == 1 )) || sleep "$RETRY_SECONDS"
    snapshot=$(progress_snapshot) || return
    lines=$(progress_lines "$snapshot")
    lines_after "$printed" "$lines"
    printed=$(count_rows "$lines")
    # Not inline in the read's here-string: bash 3.2 would run the parser
    # with read's IFS=US in effect.
    verdict=$(progress_verdict "$snapshot")
    IFS=$US read -r kind stage reason <<< "$verdict"
    [[ $kind != running ]] || continue
    if [[ $restarted == no ]] && run_predates "$snapshot" "$1"; then
      echo 'provision · that run was already active and predates this push: running it again with the pushed code'
      provision_start
      restarted=yes printed=0
      continue
    fi
    [[ $kind != 'done' ]] || return 0
    provision_failed "$stage" "$reason"
  done
  die "$EX_FAIL" "provision is still running on the host after $(fmt_duration $(( PROGRESS_ATTEMPTS * RETRY_SECONDS )))" \
    'helios-lab up reattaches to it; the unit keeps running meanwhile' "or pause the host: helios-lab stop"
}

# progress_snapshot -> one `helios-lab-host progress` reply
progress_snapshot() { host_poll "$HOST_HELPER progress" 'reading the provision progress'; }

# host_poll <remote command> <what it does> -> its reply. Over a 30-minute
# follow a network blip is likely, so up to POLL_TRIES network failures of
# ssh in a row are retried; any other failure dies at once. A lasting one
# dies 8, which up answers by asking EC2 whether the host stopped itself.
readonly POLL_TRIES=3
host_poll() {
  local n out rc
  for (( n = 1; ; n++ )); do
    rc=0
    out=$(remote_attempt host "$1" < /dev/null) || rc=$?
    if (( rc == 0 )); then printf '%s' "$out"; return 0; fi
    if (( n >= POLL_TRIES )) || ! ssh_blip "$rc" "$out"; then
      remote_fail host "$2" "$rc" "$out"
    fi
    sleep "$RETRY_SECONDS"
  done
}

# provision_failed <stage> <reason> — dies naming the stage, with the last
# lines of the run's journal
provision_failed() {
  local line
  local -a tail=()
  while IFS= read -r line; do tail+=("  $line"); done <<< "$(provision_journal 20)"
  die "$EX_FAIL" "provision failed at stage $1: ${2:-no reason given}" 'last lines of its journal on the host:' \
    "${tail[@]}" 'fix the cause and run helios-lab up again: it pushes again, and finished stages are skipped'
}

# provision_journal <lines|all> -> the current run's journal lines, or a
# note saying why there are none; never fails, because it only ever adds
# detail to a report
provision_journal() {
  local out
  out=$(remote_attempt host "sudo $HOST_HELPER journal $1" < /dev/null) || out="(journal unavailable: $(first_line "$out"))"
  printf '%s\n' "${out:-(the journal is empty)}"
}

# provision_journal_print — up -v: the whole run's journal after its stage lines
provision_journal_print() {
  echo "host journal ($PROVISION_UNIT, this run):"
  provision_journal all | sed 's/^/  /'
}

# --- Guest -------------------------------------------------------------------
# guest_bringup <instance-id> — the end of up (U3), once provisioning has the
# guest's domain running: the smoke check through the guest alias (R8),
# polled within the first-boot or the restart budget. An unverified guest
# has new host keys (every create makes them), so the alias's old pin goes
# first; a verified guest keeps its pin. Invariant: guest-verified is
# written only after both checks passed, and only through the host helper.
guest_bringup() {
  local reply verified note
  reply=$(host_status) || return
  verified=$(guest_verified_of "$reply")
  note=$(guest_mismatch "$reply")
  [[ -z $note ]] || warn "$note"
  [[ $verified == yes ]] || guest_key_forget "$1"
  guest_wait "$verified" "$reply"
  [[ $verified == yes ]] || guest_mark_verified
}

# host_status -> one `helios-lab-host status` reply
host_status() { host_poll "sudo $HOST_HELPER status" 'reading the guest status'; }

# guest_key_forget <instance-id> — drops the guest alias's pin, if any
guest_key_forget() {
  hostkey_pinned "$1-guest" || return 0
  ssh-keygen -R "$1-guest" -f "$KNOWN_HOSTS" >/dev/null 2>&1 \
    || die "$EX_FAIL" "cannot drop the pin $1-guest from $KNOWN_HOSTS"
  rm -f "$KNOWN_HOSTS.old"   # ssh-keygen's backup, which still holds it
  echo "guest key · dropped the pin $1-guest: a guest that is not verified yet has new host keys"
}

# guest_wait <verified: yes|no> <status reply> — polls until the smoke check
# passes. Each round asks the host first (a failing host dies 8, which up
# answers by asking EC2), and tries the guest only once the host sees it
# answer on tcp/22. Shows the latest console line, or the host's view, each
# time it changes. Dies on a definitive answer, or at the budget.
guest_wait() {
  local attempts label started n reply=$2 line shown='' verdict
  attempts=$(guest_attempts "$1")
  label=$(guest_wait_label "$1")
  started=$(date +%s)
  echo "$label · waiting for the guest's smoke check (up to $(fmt_duration $(( attempts * RETRY_SECONDS ))))"
  for (( n = 1; n <= attempts; n++ )); do
    if (( n > 1 )); then
      sleep "$RETRY_SECONDS"
      reply=$(host_status) || return
    fi
    line=$(guest_wait_line "$reply")
    if guest_ssh_ready "$reply"; then
      verdict=$(smoke_check) || return
      [[ $verdict != pass ]] || return 0
      line=${verdict#wait"$US"}
    fi
    [[ $line == "$shown" ]] || echo "$label · $(fmt_elapsed $(( $(date +%s) - started ))) · $line"
    shown=$line
  done
  guest_timeout "$1" "$reply" "$shown"
}

# smoke_check -> pass, or wait<US><why> while the guest can't be reached yet;
# dies on an answer that settles it: not illumos, or DTrace failing
smoke_check() {
  local out rc=0
  out=$(remote_attempt guest "$SMOKE_UNAME" < /dev/null) || rc=$?
  case $(uname_verdict "$rc" "$out") in
    illumos) ;;
    wait)    smoke_wait "$out"; return 0 ;;
    hostkey) ssh_fail guest "$out" ;;
    other)   die "$EX_FAIL" "the guest is not Helios: uname -o printed '$(first_line "$out")', not illumos" \
               "the guest alias reaches HostName $GUEST_NAME through the host; see what that is: helios-lab ssh host getent hosts $GUEST_NAME" ;;
    failed)  die "$EX_FAIL" "uname -o failed on the guest (exit $rc)" "the guest said: $(first_line "$out")" ;;
  esac
  rc=0
  out=$(remote_attempt guest "$SMOKE_DTRACE" < /dev/null) || rc=$?
  case $(dtrace_verdict "$rc" "$out") in
    ok)      echo pass ;;
    wait)    smoke_wait "$out" ;;
    hostkey) ssh_fail guest "$out" ;;
    failed)  die "$EX_FAIL" "DTrace failed on the guest: $SMOKE_DTRACE exited $rc" \
               "DTrace needs privileges, which pfexec grants through the guest user's Primary Administrator profile" \
               "the guest said: $(first_line "$out")" ;;
  esac
}

smoke_wait() { printf 'wait%s%s\n' "$US" "the guest's ssh does not answer yet ($(first_line "$1"))"; }

# guest_timeout <verified: yes|no> <last reply> <last line shown> — dies. A
# first boot that never passed is abandoned, so the next up recreates the
# guest; a verified guest is only ever retried.
guest_timeout() {
  local budget line
  local -a tail=()
  budget=$(fmt_duration $(( $(guest_attempts "$1") * RETRY_SECONDS )))
  [[ $1 != yes ]] || die "$EX_FAIL" "the verified guest did not pass the smoke check within $budget" \
    "last seen: ${3:-nothing}" 'helios-lab console attaches to its serial console' \
    'helios-lab up tries again; a verified guest is never recreated'
  while IFS= read -r line; do
    [[ -z $line ]] || tail+=("  $line")
  done <<< "$(console_lines "$2")"
  (( ${#tail[@]} > 0 )) || tail=('  (the transcript is empty)')
  guest_abandon
  die "$EX_FAIL" "the guest's first boot did not pass the smoke check within $budget" "last seen: ${3:-nothing}" \
    'last lines of its console transcript (/var/log/helios-lab/console.log on the host):' "${tail[@]}" \
    'the next helios-lab up recreates the guest; the downloaded seed is kept'
}

# guest_abandon — best effort: if it fails, the next up waits on that first
# boot once more, so say so
guest_abandon() {
  local out rc=0
  out=$(remote_attempt host "sudo $HOST_HELPER guest-abandon" < /dev/null) || rc=$?
  (( rc == 0 )) || warn "could not stop the first boot's create unit ($(first_line "$out")): the next up may wait on that guest again"
}

# guest_mark_verified — the host records the guest as verified, stops the
# create unit (freeing the console) and enables autostart
guest_mark_verified() {
  remote_call host "sudo $HOST_HELPER guest-verified" 'recording the verified guest' < /dev/null > /dev/null
  echo 'guest · verified · its console is free · it starts with the host from now on'
}

# --- ssh and console sessions ------------------------------------------------
# Both replace helios-lab with ssh (exec), so the session's exit status is
# the command's, and nothing of helios-lab outlives it.

# ssh_session <host|guest> <remote command|""> — "" is an interactive login
ssh_session() {
  [[ -z $2 ]] || exec ssh -F "$SSH_CONFIG" "$1" "$2"
  exec ssh -F "$SSH_CONFIG" "$1"
}

# console_session — virsh console on the host, with a terminal (-t), as the
# lab user (the libvirt group reaches the system libvirt)
console_session() {
  echo "console · the guest's serial console (Ctrl-] detaches) · it takes the console from the first-boot transcript logger, if one runs" >&2
  exec ssh -F "$SSH_CONFIG" -t host "$GUEST_CONSOLE_COMMAND"
}

# --- status probe ------------------------------------------------------------
# host_probe <instance-id> <public-ip> <caller access> -> "<kind>\n<body>":
# status's one look at the host. Read-only by construction: one ssh, to the
# read-only `status` subcommand, bounded at PROBE_TIMEOUT_S and never
# prompting (BatchMode); the only write is the Mac-local fragment, rendered
# for the current IP as on every connect. Only a host this Mac may reach,
# whose key is pinned, is probed: verifying a key against the console is
# up's job, and status never waits on it. Never dies, so status always
# prints its lines.
# Kinds: ok, unreachable, failed, unpinned, no-ip, not-allowed (body: the
# access, as caller_access gives it).
host_probe() {
  local out rc=0
  [[ $3 == allowed ]] || { printf 'not-allowed\n%s\n' "$3"; return 0; }
  [[ -n $2 && $2 != None ]] || { echo no-ip; return 0; }
  hostkey_pinned "$1" || { echo unpinned; return 0; }
  fragment_write "$1" "$2"
  out=$(ssh_capture -o "ConnectTimeout=$PROBE_TIMEOUT_S" -o BatchMode=yes host "sudo $HOST_HELPER status" < /dev/null) || rc=$?
  case $rc in
    0)   printf 'ok\n%s\n' "$out" ;;
    255) printf 'unreachable\n%s\n' "$(first_line "$out")" ;;
    *)   printf 'failed\nexit %s: %s\n' "$rc" "$(first_line "$out")" ;;
  esac
}

# probe_anomalies <probe> -> its "! " lines (pure): a guest built from other
# settings than pushed, a failed last provision run, a silent host
probe_anomalies() {
  local body note state kind stage reason
  body=$(probe_body "$1")
  case $(probe_kind "$1") in
    ok)          note=$(guest_mismatch "$body")
                 [[ -z $note ]] || anomaly guest-mismatch "$note"
                 state=$(provision_state "$body")
                 IFS=$US read -r kind stage reason <<< "$state"
                 [[ $kind != failed ]] || anomaly provision-failed "$stage" "$reason" ;;
    unreachable) anomaly host-silent "$PROBE_TIMEOUT_S" "$body" ;;
    failed)      anomaly probe-failed "$body" ;;
  esac
}

# probe_details <probe> -> status's host and guest detail lines (pure)
probe_details() {
  local body last
  body=$(probe_body "$1")
  case $(probe_kind "$1") in
    ok)          detail provision "$(provision_detail "$(provision_state "$body")")"
                 detail guest "$(guest_detail "$body")"
                 last=$(console_lines "$body" | tail -1)
                 [[ -z $last ]] || detail console "${last:0:100}" ;;
    unreachable) detail host "no answer over ssh within ${PROBE_TIMEOUT_S}s" ;;
    failed)      detail host 'the status probe failed: helios-lab up pushes the current helper' ;;
    unpinned)    detail host 'its key is not pinned on this Mac yet: helios-lab up verifies it against the console' ;;
    no-ip)       detail host 'no public IPv4 to probe' ;;
    not-allowed) detail host "not probed: $(access_phrase "$body")" ;;
  esac
}

# access_phrase <caller access> -> why status could not reach the host
access_phrase() {
  case $1 in
    denied*) echo "this Mac's IP (${1#denied }) is not allowed in the security group" ;;
    unknown) echo "this Mac's IP is unknown" ;;
    *)       echo 'the instance has no security group' ;;
  esac
}

detail() { printf '  %-9s %s\n' "$1" "$2"; }
