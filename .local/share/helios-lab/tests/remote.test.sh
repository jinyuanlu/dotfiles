#!/bin/bash
# shellcheck source-path=SCRIPTDIR
#
# remote.test.sh — U2: host-key verification against the console, the push,
# the provision unit and its progress (lib/remote.sh), and the host helper's
# own logic (host/helios-lab-host: stage decisions, markers, install, and
# the progress lines it writes).
#
# Mac-side scenarios run the real entry, or its functions after load_cli,
# against the aws, ssh and ssh-keyscan stubs. The console fixtures and the
# keyscan capture all come from the spike's host, so the offered key and the
# console's ED25519 line genuinely match. Progress and journal replies are
# hand-written in the protocol's grammar (tests/lib.sh progress_reply); the
# "contract" tests prove the helper writes exactly that grammar.
#
# The helper is sourced, never executed, by host_env: its paths point into
# the sandbox (HELIOS_LAB_HOST_ROOT), and what it would run on a real host
# (apt, systemctl, nft, virsh, journalctl) is replaced by shell functions.
# The helper and the entry are never loaded into the same shell.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --- Fixtures ----------------------------------------------------------------
readonly RUNNING=$DERIVED/describe-instances.running.discover.txt
readonly RULES_CONVERGED=$DERIVED/describe-security-group-rules.converged.rules.txt
readonly CONSOLE_FIRST=$FIXTURES/get-console-output.latest.first-boot.txt
readonly CONSOLE_LATER=$FIXTURES/get-console-output.latest.later-boot.txt
readonly CONSOLE_BUFFERED=$FIXTURES/get-console-output.buffered.first-boot.txt
readonly KEYSCAN=$FIXTURES/ssh-keyscan.ed25519.txt
readonly HELPER=$HELIOS_LAB_HOME/host/helios-lab-host
readonly UNIT_FILE=$HELIOS_LAB_HOME/host/helios-lab-provision.service

readonly LAB_ID=i-0123456789abcdef0
readonly HOST_IP=203.0.113.10          # the fixtures' (sanitized) public IP
readonly HOST_FP=SHA256:e3nmpQY3OllEnw+YTnIxOK1vZttbrX0xpEMwqyQdKTQ   # the spike host's ED25519 key
readonly OTHER_FP=SHA256:kz+Tw/36PkRNhaOvv5otG5S4Peg4eicnqhu/ViZnv2E   # its ECDSA key's, never an ED25519 answer
readonly PIN=8ef18ef53d3baa03eebe5f2238a3a4ceef1b6f4a
readonly HELPER_PATH=/usr/local/libexec/helios-lab/helios-lab-host
readonly PUSH_CMD="sudo bash -c 'stage=\$(mktemp -d /tmp/helios-lab-push.XXXXXX) && cd \"\$stage\" && bash -s && exec bash ./helios-lab-host install \"\$stage\"'"
readonly SMOKE_CMD="uname -o 2>&1; echo \"helios-lab-smoke uname \$?\"; ( sleep 30 >/dev/null 2>&1; echo \"helios-lab-smoke timeout\" >&2; kill -9 -\$\$ 2>/dev/null || kill -9 \$\$ ) & w=\$!; pfexec dtrace -n 'BEGIN { exit(0); }' 2>&1; echo \"helios-lab-smoke dtrace \$?\"; kill \$w 2>/dev/null || :"
readonly RFD26_LINE='seed · fetching and verifying the 2.4 GB Helios seed (about 5 min the first time) · meanwhile, read RFD 26: https://rfd.shared.oxide.computer/rfd/0026'
# The provision lines of a clean first run (progress_reply 'done')
readonly STAGE_LINES="packages · done · 41s · 8 packages installed
libvirt · done · 3s · kvm ok, default network active
guard · done · 0s · virbr0 to 169.254.0.0/16 dropped
engvm · done · 9s · @8ef18ef · lab: 3 vCPU, 8 GiB, 60G
$RFD26_LINE
seed · done · 5m11s · verified against engvm's pinned checksums
guest · done · 1m05s · created · first boot under way"

# --- Scenario builders -------------------------------------------------------
# world_running — one running lab instance with the test key, a converged
# group, this Mac at the allowed IP, and a host that verifies and provisions
world_running() {
  lab_key
  tagged < "$RUNNING" | reply ec2-describe-instances
  reply ec2-describe-security-group-rules "$RULES_CONVERGED"
  reply ec2-wait < /dev/null
  caller_ip_is "$HOST_IP"
  world_host_ok
}

# up_again — a second `up` against the same world: AWS replies restart their
# sequence, ssh's keep counting (so each up's push stays apart)
up_again() { rm -rf "$STUB_AWS_DIR/.calls"; run_cli up; }

# pinned — the known_hosts entry a first contact leaves
pinned() {
  mkdir -p "$HELIOS_LAB_STATE_DIR"
  echo "$LAB_ID $(awk 'NR == 2 { print $2, $3 }' "$KEYSCAN")" > "$HELIOS_LAB_STATE_DIR/known_hosts"
}

# names_in <dir> -> its file names, sorted
names_in() { local f; for f in "$1"/*; do echo "${f##*/}"; done | sort; }

# code_of <text> -> its lines that are not comments
code_of() { grep -vE '^[[:space:]]*#' <<< "$1" || true; }

drop_epochs() { sed 's/^[0-9]* //'; }

# steady — the host-key line's elapsed time is the wall clock's (0s or 1s
# against the stubs), so assertions see "Ns"
steady() { sed -E 's/( · pinned · )[0-9]+s$/\1Ns/'; }

calls() { cat "$STUB_LOG"; }
calls_of() { grep -E "^(aws [a-z0-9-]+ $1|$1)( |$)" "$STUB_LOG" || true; }
count_of() { calls_of "$1" | grep -c . || true; }
ssh_calls() { grep '^ssh ' "$STUB_LOG" || true; }
ssh_count() { ssh_calls | grep -cF -- "$1" || true; }
line_no() { grep -nF -- "$1" "$STUB_LOG" | sed -n "${2:-1}p" | cut -d: -f1; }
first_out_line() { grep -nF -- "$1" <<< "$OUT" | head -1 | cut -d: -f1; }

# unpack_push <n> <dir> — what the nth push would write on the host
unpack_push() { mkdir -p "$2"; (cd "$2" && /bin/bash -s) < "$STUB_SSH_DIR/.stdin/ssh-host-bash.$1"; }

# host_env — the helper, sourced, with its root in the sandbox
host_env() {
  export HELIOS_LAB_HOST_ROOT=$SANDBOX/root
  # shellcheck source=../host/helios-lab-host
  source "$HELPER"
  require_root() { :; }
}

# host_conf_ok — the config a push leaves: host.conf rendered by the Mac's
# own code, and the shipped guest sizing
host_conf_ok() {
  mkdir -p "$SANDBOX/root/etc/helios-lab"
  ( load_cli; render_host_config 60 "$PIN" ) > "$SANDBOX/root/etc/helios-lab/host.conf"
  cp "$HELIOS_LAB_HOME/host/engvm-lab.sh" "$SANDBOX/root/etc/helios-lab/engvm-lab.sh"
}

# fake_stages — after host_env: stages and live checks that record, not
# apply; their summaries are the ones progress_reply (tests/lib.sh) uses
# shellcheck disable=SC2329  # called by the helper's run_stage, by name
fake_stages() {
  stage_packages() { echo packages >> "$SANDBOX/ran"; echo 'apt says hello'; echo '8 packages installed' >&3; }
  stage_libvirt() { echo libvirt >> "$SANDBOX/ran"; echo 'kvm ok, default network active' >&3; }
  stage_guard() { echo guard >> "$SANDBOX/ran"; echo 'virbr0 to 169.254.0.0/16 dropped' >&3; }
  stage_engvm() { echo engvm >> "$SANDBOX/ran"; echo "@${PIN:0:7} · lab: $LAB_SIZING" >&3; }
  stage_seed() { echo seed >> "$SANDBOX/ran"; echo "verified against engvm's pinned checksums" >&3; }
  stage_guest() { echo guest >> "$SANDBOX/ran"; echo 'created · first boot under way' >&3; }
  check_packages() { :; }
  check_libvirt() { :; }
  check_guard() { :; }
  check_engvm() { :; }
  check_seed() { :; }
}

ran() { tr '\n' ' ' < "$SANDBOX/ran" 2>/dev/null | sed 's/ $//'; }

# events — the progress file's lines without their epochs
events() { cut -d' ' -f2- "$SANDBOX/root/var/lib/helios-lab/progress"; }

marker() { cat "$SANDBOX/root/var/lib/helios-lab/stage.$1"; }

# --- Console fingerprints (pure) ---------------------------------------------
test_first_boot_console_yields_the_ed25519_fingerprint_from_either_block() {
  load_cli
  assert_eq "$HOST_FP" "$(console_fingerprints "$(<"$CONSOLE_FIRST")")" 'both blocks: one key'
  assert_eq '-----BEGIN HELIOS-LAB HOST KEYS-----' "$(sed -n 1p "$CONSOLE_FIRST")"
  assert_eq "$HOST_FP" "$(console_fingerprints "$(sed -n 1,5p "$CONSOLE_FIRST")")" 'the per-boot block alone'
  assert_contains "$(sed -n 6p "$CONSOLE_FIRST")" 'cloud-init: -----BEGIN SSH HOST KEY FINGERPRINTS-----'
  assert_eq "$HOST_FP" "$(console_fingerprints "$(sed -n 6,10p "$CONSOLE_FIRST")")" "cloud-init's block alone"
  assert_eq match "$(hostkey_verdict "$(console_fingerprints "$(<"$CONSOLE_FIRST")")" "$HOST_FP")"
}

test_later_boot_console_with_systemd_lines_inside_the_block_still_yields_it() {
  load_cli
  local text
  text=$(<"$CONSOLE_LATER")
  [[ $text == *$'\r'* && $text == *'Starting'* ]] || fail 'the fixture lost its CRLF or its interleaved lines'
  assert_not_contains "$text" 'SSH HOST KEY FINGERPRINTS'   # no cloud-init block on a later boot
  assert_eq "$HOST_FP" "$(console_fingerprints "$text")"
}

test_buffered_console_is_not_yet_available_and_never_a_match() {
  load_cli
  local text
  [[ ! -s $CONSOLE_BUFFERED ]] || fail 'the buffered fixture should be empty'
  # the empty capture, the CLI's bare newline for "", and its None for no Output
  for text in "$(<"$CONSOLE_BUFFERED")" $'\n' None; do
    assert_eq '' "$(console_fingerprints "$text")"
    assert_eq pending "$(hostkey_verdict "$(console_fingerprints "$text")" "$HOST_FP")"
  done
}

test_only_complete_blocks_and_fingerprint_shaped_lines_count() {
  load_cli
  local begin='-----BEGIN HELIOS-LAB HOST KEYS-----' end='-----END HELIOS-LAB HOST KEYS-----'
  local ed="256 $HOST_FP root@ip-172-31-0-10 (ED25519)" text
  assert_eq '' "$(console_fingerprints "$begin"$'\n'"$ed")" 'no END yet'
  assert_eq '' "$(console_fingerprints "$ed")" 'outside any block'
  assert_eq '' "$(console_fingerprints "$begin"$'\n'"256 $OTHER_FP root@h (ECDSA)"$'\n'"$end")" 'ECDSA only'
  assert_eq '' "$(console_fingerprints "$begin"$'\n'"256 ${HOST_FP:0:30} root@h (ED25519)"$'\n'"$end")" 'truncated'
  assert_eq '' "$(console_fingerprints "$begin"$'\n'"Starting x... $ed"$'\n'"$end")" 'glued to systemd output'
  assert_eq '' "$(console_fingerprints "$begin"$'\n'"$ed"$'\n''<14>Oct 24 cloud-init: -----END SSH HOST KEY FINGERPRINTS-----')" \
    "closed by the other block's END"
  text="$begin"$'\n'"$ed"$'\n'"$end"$'\n'"$begin"$'\n'"256 ${OTHER_FP} root@h (ED25519)"$'\n'"$end"
  assert_eq "$HOST_FP"$'\n'"$OTHER_FP" "$(console_fingerprints "$text")" 'two blocks that disagree'
  assert_eq mismatch "$(hostkey_verdict "$(console_fingerprints "$text")" "$HOST_FP")" 'disagreeing blocks never match'
}

test_hostkey_verdict_table() {
  load_cli
  assert_eq pending "$(hostkey_verdict '' "$HOST_FP")"
  assert_eq pending "$(hostkey_verdict '' '')"
  assert_eq match "$(hostkey_verdict "$HOST_FP" "$HOST_FP")"
  assert_eq mismatch "$(hostkey_verdict "$HOST_FP" "$OTHER_FP")"
  assert_eq mismatch "$(hostkey_verdict "$HOST_FP" '')"
  assert_eq mismatch "$(hostkey_verdict "$HOST_FP"$'\n'"$OTHER_FP" "$HOST_FP")"
}

test_the_captured_keyscan_is_the_key_the_console_printed() {
  load_cli
  local key
  key=$(keyscan_key "$HOST_IP" "$(<"$KEYSCAN")")
  [[ $key == 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI'* ]] || fail "not an ed25519 key: $key"
  assert_eq "$HOST_FP" "$(key_fingerprint "$key")"
  if keyscan_key 198.51.100.7 "$(<"$KEYSCAN")" >/dev/null; then fail 'took a key for another address'; fi
  if keyscan_key "$HOST_IP" "$(sed -n 1p "$KEYSCAN")" >/dev/null; then fail 'took the banner comment for a key'; fi
  if keyscan_key "$HOST_IP" '' >/dev/null; then fail 'took nothing for a key'; fi
  ssh-keygen -q -t ed25519 -N '' -f "$SANDBOX/rogue"
  if keyscan_key "$HOST_IP" "$(<"$KEYSCAN")"$'\n'"$HOST_IP $(cut -d' ' -f1,2 "$SANDBOX/rogue.pub")" >/dev/null; then
    fail 'took one of two different keys'
  fi
}

# --- Host key: the flow ------------------------------------------------------
test_first_contact_pins_the_console_verified_key_under_the_instance_id() {
  load_cli
  world_host_ok
  run_fn host_reach "$LAB_ID" "$HOST_IP"
  assert_rc 0
  assert_eq "$LAB_ID $(awk 'NR == 2 { print $2, $3 }' "$KEYSCAN")" "$(<"$KNOWN_HOSTS")" 'the pinned entry'
  ssh-keygen -F "$LAB_ID" -f "$KNOWN_HOSTS" >/dev/null || fail 'ssh-keygen does not find the alias'
  assert_eq 600 "$(stat -f %Lp "$KNOWN_HOSTS" 2>/dev/null || stat -c %a "$KNOWN_HOSTS")" 'known_hosts mode'
  assert_eq "aws ec2 get-console-output --instance-id $LAB_ID --latest --query Output --output text --profile helios-lab --region ap-northeast-1" \
    "$(calls_of get-console-output)"
  assert_eq "ssh-keyscan -T 10 -t ed25519 $HOST_IP" "$(calls_of ssh-keyscan)"
  assert_line 1 "host key · waiting for $LAB_ID's fingerprints on its console"
  assert_eq "host key · ED25519 $HOST_FP matches the console · pinned · Ns" "$(sed -n 2p <<< "$OUT" | steady)"
  assert_contains "$(<"$SSH_CONFIG")" "  HostName $HOST_IP"
  assert_contains "$(<"$SSH_CONFIG")" "  HostKeyAlias $LAB_ID"
}

test_the_poll_reads_the_console_with_latest_until_a_block_appears() {
  load_cli
  world_host_ok
  reply_seq ec2-get-console-output 1 "$CONSOLE_BUFFERED"
  reply_seq ec2-get-console-output 2 "$CONSOLE_BUFFERED"
  reply_seq ec2-get-console-output 3 "$CONSOLE_LATER"   # say, a restart
  run_fn host_reach "$LAB_ID" "$HOST_IP"
  assert_rc 0
  assert_eq 3 "$(count_of get-console-output)" 'console reads'
  assert_eq 3 "$(calls_of get-console-output | grep -c -- ' --latest ')" 'every read is --latest'
  assert_eq 1 "$(count_of ssh-keyscan)" 'one scan, once the console showed the key'
  assert_called_in_order get-console-output ssh-keyscan
  ssh-keygen -F "$LAB_ID" -f "$KNOWN_HOSTS" >/dev/null || fail 'not pinned'
}

assert_called_in_order() {
  local a b
  a=$(grep -n -- "$1" "$STUB_LOG" | tail -1 | cut -d: -f1)
  b=$(grep -n -- "$2" "$STUB_LOG" | head -1 | cut -d: -f1)
  if [[ -z $a || -z $b ]] || (( a >= b )); then fail "expected every '$1' before '$2' in:" "$(calls)"; fi
}

test_an_offered_key_the_console_never_printed_fails_naming_interception() {
  load_cli
  world_host_ok
  ssh-keygen -q -t ed25519 -N '' -f "$SANDBOX/rogue"
  echo "$HOST_IP $(cut -d' ' -f1,2 "$SANDBOX/rogue.pub")" | ssh_reply ssh-keyscan
  local rogue
  rogue=$(ssh-keygen -lf "$SANDBOX/rogue.pub" | awk '{ print $2 }')
  run_fn host_reach "$LAB_ID" "$HOST_IP"
  assert_rc 6
  assert_contains "$ERR" "host key mismatch: $HOST_IP offered ED25519 $rogue, but $LAB_ID's console printed $HOST_FP"
  assert_contains "$ERR" 'this can mean the connection is being intercepted; nothing was pinned'
  assert_contains "$ERR" "aws ec2 get-console-output --instance-id $LAB_ID --latest"
  [[ ! -e $KNOWN_HOSTS ]] || fail "known_hosts was written: $(<"$KNOWN_HOSTS")"
  assert_eq '' "$(ssh_calls)" 'no ssh to a host that failed verification'
}

test_a_console_without_fingerprints_by_the_timeout_is_an_explicit_failure() {
  load_cli
  world_host_ok
  reply ec2-get-console-output "$CONSOLE_BUFFERED"
  run_fn host_reach "$LAB_ID" "$HOST_IP"
  assert_rc 6
  assert_contains "$ERR" "$LAB_ID's console showed no host-key fingerprints in $CONSOLE_ATTEMPTS reads"
  assert_contains "$ERR" 'helios-lab never trusts a key on first use'
  assert_eq "$CONSOLE_ATTEMPTS" "$(count_of get-console-output)" 'console reads'
  assert_eq 0 "$(count_of ssh-keyscan)" 'no key is even read without the console'
  [[ ! -e $KNOWN_HOSTS ]] || fail 'known_hosts was written'
}

test_a_pinned_host_is_not_verified_again() {
  load_cli
  world_host_ok
  mkdir -p "$HELIOS_LAB_STATE_DIR"
  pinned
  run_fn host_reach "$LAB_ID" "$HOST_IP"
  assert_rc 0
  assert_eq '' "$(calls)" 'no console read, no scan'
  assert_eq '' "$OUT"
  [[ -f $SSH_CONFIG ]] || fail 'the fragment is still rendered on every connect'
}

test_a_host_that_offers_no_key_fails_as_network_and_pins_nothing() {
  load_cli
  world_host_ok
  ssh_reply ssh-keyscan < /dev/null
  run_fn host_reach "$LAB_ID" "$HOST_IP"
  assert_rc 8
  assert_contains "$ERR" "the host at $HOST_IP offered no ED25519 host key on tcp/22 in $KEYSCAN_ATTEMPTS tries"
  assert_eq "$KEYSCAN_ATTEMPTS" "$(count_of ssh-keyscan)"
  [[ ! -e $KNOWN_HOSTS ]] || fail 'known_hosts was written'
}

test_a_running_host_without_a_public_ip_is_named() {
  load_cli
  run_fn host_reach "$LAB_ID" None
  assert_rc 1
  assert_contains "$ERR" "$LAB_ID is running but has no public IPv4"
  assert_eq '' "$(calls)"
}

# --- ssh errors --------------------------------------------------------------
test_ssh_error_classes() {
  load_cli
  local spec class text
  for spec in 'hostkey|Host key verification failed.' \
              'hostkey|@@@@@@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@@@@@@' \
              "hostkey|No ED25519 host key is known for $LAB_ID and you have requested strict checking." \
              'auth|ubuntu@203.0.113.10: Permission denied (publickey).' \
              'network|ssh: connect to host 203.0.113.10 port 22: Operation timed out' \
              'network|ssh: connect to host 203.0.113.10 port 22: Connection refused' \
              'network|Connection closed by 203.0.113.10 port 22' \
              'network|kex_exchange_identification: read: Connection reset by peer' \
              'other|channel 0: open failed: administratively prohibited'; do
    IFS='|' read -r class text <<< "$spec"
    assert_eq "$class" "$(ssh_error_class "$text")" "$text"
  done
}

test_ssh_failures_on_the_push_map_to_typed_exit_codes() {
  world_running
  local spec rc text hint
  for spec in "6|Host key verification failed.|ssh-keygen -R <instance-id> -f $HELIOS_LAB_STATE_DIR/known_hosts" \
              '8|ssh: connect to host 203.0.113.10 port 22: Operation timed out|helios-lab status' \
              '1|ubuntu@203.0.113.10: Permission denied (publickey).|ssh-add --apple-use-keychain' \
              '1|helios-lab-host: no install rule for stray.conf|installing the host code failed on the host (exit 1)'; do
    IFS='|' read -r rc text hint <<< "$spec"
    rm -rf "$STUB_AWS_DIR/.calls"
    ssh_reply_error ssh-host-bash "$( [[ $rc == 1 && $text == helios-* ]] && echo 1 || echo 255 )" "$text"
    run_cli up
    assert_rc "$rc"
    assert_contains "$ERR" "$hint"
    assert_contains "$ERR" "$text"
    assert_contains "$ERR" "host $LAB_ID is running and billing"
  done
  assert_eq 0 "$(ssh_count 'systemctl start')" 'no unit start after a failed push'
}

# --- up: push and provision --------------------------------------------------
test_up_verifies_pushes_starts_and_follows_on_a_running_host() {
  world_running
  export TZ=Asia/Tokyo
  run_cli up
  assert_rc 0
  assert_eq "host running · $LAB_ID · $HOST_IP · ≈\$0.27/hr
host key · waiting for $LAB_ID's fingerprints on its console
host key · ED25519 $HOST_FP matches the console · pinned · Ns
push · host code and config installed · idle 60 min · engvm @8ef18ef
$STAGE_LINES
host ready · KVM, libvirt and the metadata guard are in place
first boot · waiting for the guest's smoke check (up to 30m)
guest · verified · its console is free · it starts with the host from now on
guest ready in Ns · illumos · dtrace ok
  in the guest, try: pfexec dtrace -n 'syscall:::entry { @[execname] = count(); }'  (Ctrl-C prints system calls by process)
  auto-stops after 60 min idle · helios-lab keep 3h to hold it · helios-lab stop when done
next: helios-lab ssh" "$(steady <<< "$OUT" | sed -E 's/^(guest ready in )[0-9]+s/\1Ns/')"
  assert_eq '' "$ERR"
  local cfg=$HELIOS_LAB_STATE_DIR/ssh_config
  assert_eq "ssh -F $cfg host $PUSH_CMD
ssh -F $cfg host sudo $HELPER_PATH status
ssh -F $cfg host sudo systemctl start helios-lab-provision.service
ssh -F $cfg host $HELPER_PATH progress
ssh -F $cfg host sudo $HELPER_PATH status
ssh -F $cfg guest $SMOKE_CMD
ssh -F $cfg host sudo $HELPER_PATH guest-verified
ssh -F $cfg host sudo $HELPER_PATH status" "$(ssh_calls)"   # the last: the ready screen's countdown
  assert_not_contains "$(calls)" 'StrictHostKeyChecking'   # no call loosens the fragment
  assert_not_contains "$(calls)" 'scp '
}

test_two_consecutive_ups_push_and_start_the_unit_both_times() {
  world_running
  run_cli up
  assert_rc 0
  up_again
  assert_rc 0
  assert_eq 2 "$(ssh_count "host $PUSH_CMD")" 'pushes'
  assert_eq 2 "$(ssh_count 'host sudo systemctl start helios-lab-provision.service')" 'unit starts'
  (( $(line_no "$PUSH_CMD" 1) < $(line_no 'systemctl start' 1) )) || fail 'first start before its push'
  (( $(line_no "$PUSH_CMD" 2) < $(line_no 'systemctl start' 2) )) || fail 'second start before its push'
  (( $(line_no 'systemctl start' 1) < $(line_no "$PUSH_CMD" 2) )) || fail 'the pushes ran together'
  assert_eq 1 "$(count_of get-console-output)" 'the second up trusts the pin'
  assert_not_contains "$OUT" 'host key'
  assert_contains "$OUT" 'push · host code and config installed'
  assert_eq "$(ssh_stdin ssh-host-bash 1)" "$(ssh_stdin ssh-host-bash 2)" 'the same bundle twice'
}

test_the_push_carries_every_host_file_and_the_rendered_config_verbatim() {
  world_running
  export HELIOS_LAB_IDLE_MINUTES=90
  run_cli up
  assert_rc 0
  unpack_push 1 "$SANDBOX/pushed"
  local f
  for f in "$HELIOS_LAB_HOME"/host/*; do
    cmp -s "$f" "$SANDBOX/pushed/${f##*/}" || fail "${f##*/} did not arrive verbatim"
  done
  assert_eq "$( ( load_cli; render_host_config 90 "$PIN" ) )" "$(<"$SANDBOX/pushed/host.conf")"
  assert_eq "$( { names_in "$HELIOS_LAB_HOME/host"; echo host.conf; } | sort)" "$(names_in "$SANDBOX/pushed")" 'exactly those files'
  assert_contains "$OUT" 'idle 90 min'
}

test_an_edited_host_file_reaches_the_host_on_the_next_up() {
  world_running
  local copy=$SANDBOX/share
  mkdir -p "$copy"
  cp -R "$HELIOS_LAB_HOME/lib" "$HELIOS_LAB_HOME/host" "$copy/"
  export HELIOS_LAB_HOME=$copy
  run_cli up
  assert_rc 0
  echo '# edited in the repo' >> "$copy/host/helios-lab-provision.service"
  up_again
  assert_rc 0
  assert_not_contains "$(ssh_stdin ssh-host-bash 1)" '# edited in the repo'
  unpack_push 2 "$SANDBOX/pushed"
  assert_eq '# edited in the repo' "$(tail -1 "$SANDBOX/pushed/helios-lab-provision.service")"
}

test_pushed_files_install_where_the_units_expect_them_then_the_stop_is_handed_over() {
  world_running
  run_cli up
  assert_rc 0
  local stage=$SANDBOX/tmp/helios-lab-push.test root=$SANDBOX/root
  unpack_push 1 "$stage"
  host_env
  mkdir -p "$root/etc/systemd/system"
  : > "$root/etc/systemd/system/helios-lab-deadman.timer"   # user-data's
  # shellcheck disable=SC2329  # called by cmd_install
  systemctl() { echo "systemctl $*" >> "$SANDBOX/systemctl.log"; }
  # shellcheck disable=SC2329  # called by cmd_install; never the Mac's real sshd
  sshd() { echo "sshd $*" >> "$SANDBOX/systemctl.log"; }
  local printed f
  printed=$(cmd_install "$stage")
  [[ $printed =~ ^[0-9]+$ ]] || fail "install should print only its epoch, printed: $printed"
  cmp -s "$HELPER" "$root$HELPER_PATH" || fail 'the helper differs once installed'
  [[ -x $root$HELPER_PATH ]] || fail 'the helper is not executable'
  for f in helios-lab-provision.service helios-lab-idle.service helios-lab-idle.timer; do
    cmp -s "$HELIOS_LAB_HOME/host/$f" "$root/etc/systemd/system/$f" || fail "$f differs"
    [[ ! -x $root/etc/systemd/system/$f ]] || fail "$f is executable"
  done
  cmp -s "$HELIOS_LAB_HOME/host/sshd-helios-lab.conf" "$root/etc/ssh/sshd_config.d/10-helios-lab.conf" || fail 'the sshd drop-in differs'
  assert_eq "$( ( load_cli; render_host_config 60 "$PIN" ) )" "$(<"$root/etc/helios-lab/host.conf")"
  # U4: the idle timer is armed first, and only then the dead-man disarmed
  # (idle.test.sh: no disarm when arming fails).
  assert_eq 'systemctl daemon-reload
sshd -t
systemctl try-reload-or-restart ssh.service
systemctl enable --now helios-lab-idle.timer
systemctl is-active --quiet helios-lab-idle.timer
systemctl disable --now helios-lab-deadman.timer' "$(<"$SANDBOX/systemctl.log")" 'what install runs'
  [[ ! -e $stage ]] || fail 'the push directory was left behind'
}

test_install_refuses_an_unknown_file_and_a_directory_not_named_like_the_push() {
  host_env
  # shellcheck disable=SC2329  # called by cmd_install
  systemctl() { :; }
  local stage=$SANDBOX/helios-lab-push.x
  mkdir -p "$stage" "$SANDBOX/elsewhere"
  echo x > "$stage/stray.conf"
  RC=0; ERR=$( (cmd_install "$stage") 2>&1 ) || RC=$?
  assert_eq 1 "$RC"
  assert_contains "$ERR" 'no install rule for stray.conf'
  RC=0; ERR=$( (cmd_install "$SANDBOX/elsewhere") 2>&1 ) || RC=$?
  assert_eq 1 "$RC"
  assert_contains "$ERR" "install takes the push's directory"
  [[ -d $SANDBOX/elsewhere ]] || fail 'removed a directory that was not the push'
}

test_up_renders_stage_lines_as_progress_arrives() {
  world_running
  progress_reply packages-running | ssh_reply_seq ssh-host-progress 1
  progress_reply libvirt-running | ssh_reply_seq ssh-host-progress 2
  run_cli up
  assert_rc 0
  assert_eq 3 "$(ssh_count "$HELPER_PATH progress")" 'polls until done'
  local line
  for line in 'packages · done · 41s · 8 packages installed' 'libvirt · done · 3s · kvm ok, default network active' \
              'guard · done · 0s · virbr0 to 169.254.0.0/16 dropped'; do
    assert_eq 1 "$(grep -cxF -- "$line" <<< "$OUT")" "printed once: $line"
  done
  (( $(first_out_line 'push ·') < $(first_out_line 'packages ·') )) || fail 'stages before the push'
  (( $(first_out_line 'guard ·') < $(first_out_line 'host ready') )) || fail 'ready before the last stage'
}

test_a_run_that_predates_the_push_runs_again_with_the_pushed_code() {
  world_running
  # An interrupted up left a run active: it began before this push...
  progress_reply 'done' $(( PUSH_EPOCH - 600 )) | ssh_reply_seq ssh-host-progress 1
  # ...so up starts the unit again once it ends; the fresh run began after.
  progress_reply 'done' $(( PUSH_EPOCH + 5 )) | ssh_reply_seq ssh-host-progress 2
  run_cli up
  assert_rc 0
  assert_eq 2 "$(ssh_count 'host sudo systemctl start helios-lab-provision.service')" 'unit starts'
  assert_eq 1 "$(ssh_count "host $PUSH_CMD")" 'one push'
  assert_contains "$OUT" 'provision · that run was already active and predates this push: running it again with the pushed code'
  assert_eq 2 "$(grep -c '^guard · done' <<< "$OUT")" "both runs' stage lines"
  assert_above 'predates this push' 'host ready'
}

test_a_failed_run_that_predates_the_push_is_rerun_not_reported() {
  world_running
  progress_reply guard-failed $(( PUSH_EPOCH - 600 )) | ssh_reply_seq ssh-host-progress 1
  run_cli up
  assert_rc 0
  assert_contains "$OUT" 'guard · failed'
  assert_contains "$OUT" 'predates this push'
  assert_contains "$OUT" $'guest · done · 1m05s · created · first boot under way\nhost ready · KVM, libvirt and the metadata guard are in place'
  assert_eq 'next: helios-lab ssh' "$(tail -1 <<< "$OUT")"
  assert_eq '' "$(ssh_calls | grep journal || true)" 'no failure report'
}

test_a_network_blip_while_polling_is_retried_and_a_lasting_one_is_not() {
  world_running
  ssh_reply_error ssh-host-progress.1 255 'ssh: connect to host 203.0.113.10 port 22: Operation timed out'
  ssh_reply_error ssh-host-progress.2 255 'Connection closed by 203.0.113.10 port 22'
  run_cli up
  assert_rc 0
  assert_eq 3 "$(ssh_count "$HELPER_PATH progress")" 'two blips, then the reply'
  rm -rf "$STUB_SSH_DIR"/ssh-host-progress* "$STUB_SSH_DIR/.calls"
  ssh_reply_error ssh-host-progress 255 'ssh: connect to host 203.0.113.10 port 22: Operation timed out'
  up_again
  assert_rc 8
  assert_contains "$ERR" 'cannot reach the host over ssh'
  assert_eq 6 "$(ssh_count "$HELPER_PATH progress")" "the first up's 3 polls, then 3 tries"
}

test_only_network_failures_of_ssh_itself_are_retried_while_polling() {
  world_running
  ssh_reply_error ssh-host-progress 255 'Host key verification failed.'
  run_cli up
  assert_rc 6
  assert_eq 1 "$(ssh_count "$HELPER_PATH progress")" 'no retry for a host-key failure'
  rm -rf "$STUB_SSH_DIR"/ssh-host-progress* "$STUB_SSH_DIR/.calls"
  ssh_reply_error ssh-host-progress 127 'bash: /usr/local/libexec/helios-lab/helios-lab-host: No such file or directory'
  up_again
  assert_rc 1
  assert_contains "$ERR" 'reading the provision progress failed on the host (exit 127)'
}

test_run_predates_install_epoch_and_ssh_blip() {
  load_cli
  local t=$RUN_EPOCH
  run_predates "$(progress_reply 'done' "$t")" $(( t + 1 )) || fail 'a run that began before the push'
  if run_predates "$(progress_reply 'done' "$t")" "$t"; then fail 'a run that began with the push'; fi
  if run_predates 'unit failed exit-code' "$t"; then fail 'a run without a start line'; fi
  assert_eq 1792839095 "$(install_epoch $'some output\n1792839095')"
  assert_eq 0 "$(install_epoch '')"
  assert_eq 0 "$(install_epoch 'installed')"
  ssh_blip 255 'ssh: connect to host 203.0.113.10 port 22: Operation timed out' || fail 'a timeout is a blip'
  if ssh_blip 255 'Host key verification failed.'; then fail 'a host-key failure is no blip'; fi
  if ssh_blip 1 'Operation timed out'; then fail "the remote command's failure is no blip"; fi
}

test_a_second_up_on_a_provisioned_host_says_every_stage_is_unchanged() {
  world_running
  pinned
  progress_reply unchanged | ssh_reply ssh-host-progress
  guest_status_reply verified unchanged | ssh_reply ssh-host-status
  run_cli up
  assert_rc 0
  # Every stage but guest, which is never skipped: it found the verified guest running.
  assert_contains "$OUT" $'packages · unchanged\nlibvirt · unchanged\nguard · unchanged\nengvm · unchanged\nseed · unchanged\nguest · done · 0s · verified guest running\nhost ready'
  assert_not_contains "$OUT" 'RFD 26'   # the seed stage did not start
}

test_a_failed_stage_names_it_and_shows_the_journal_tail() {
  world_running
  progress_reply guard-failed | ssh_reply ssh-host-progress
  # Hand-written: journal lines as `journalctl -o cat` prints them.
  printf '%s\n' '1792839144 guard start' 'Error: Could not process rule: No such file or directory' \
    '1792839146 guard fail loading /etc/helios-lab/guard.nft failed (nft -f): see the journal' | ssh_reply ssh-host-journal
  run_cli up
  assert_rc 1
  assert_contains "$OUT" 'guard · failed · 2s · loading /etc/helios-lab/guard.nft failed (nft -f): see the journal'
  assert_not_contains "$OUT" 'host ready'
  assert_contains "$ERR" 'helios-lab: provision failed at stage guard: loading /etc/helios-lab/guard.nft failed (nft -f): see the journal'
  assert_contains "$ERR" $'  last lines of its journal on the host:\n    1792839144 guard start\n    Error: Could not process rule'
  assert_contains "$ERR" 'run helios-lab up again: it pushes again, and finished stages are skipped'
  assert_contains "$ERR" "host $LAB_ID is running and billing"
  assert_eq "ssh -F $HELIOS_LAB_STATE_DIR/ssh_config host sudo $HELPER_PATH journal 20" "$(ssh_calls | grep journal)"
}

test_a_unit_that_stops_before_finishing_is_a_failure() {
  world_running
  progress_reply died | ssh_reply ssh-host-progress
  ssh_reply ssh-host-journal < /dev/null
  run_cli up
  assert_rc 1
  assert_contains "$OUT" 'packages · done · 41s'
  assert_contains "$ERR" 'provision failed at stage provision: the provision unit stopped before finishing (failed signal)'
  assert_contains "$ERR" '(the journal is empty)'
}

test_a_provision_still_running_at_the_timeout_says_up_reattaches() {
  world_running
  progress_reply packages-running | ssh_reply ssh-host-progress
  run_cli up
  assert_rc 1
  assert_contains "$ERR" 'provision is still running on the host after'
  assert_contains "$ERR" 'helios-lab up reattaches to it'
  assert_eq 180 "$(ssh_count "$HELPER_PATH progress")" 'polls'
}

test_a_unit_that_cannot_start_shows_the_journal() {
  world_running
  ssh_reply_error ssh-host-systemctl 1 'Job for helios-lab-provision.service failed because the control process exited with error code.'
  echo 'helios-lab-host: progress-reset must run as root' | ssh_reply ssh-host-journal
  run_cli up
  assert_rc 1
  assert_contains "$ERR" 'provision failed at stage provision: systemctl start helios-lab-provision.service failed: Job for helios-lab-provision.service failed'
  assert_contains "$ERR" '    helios-lab-host: progress-reset must run as root'
  assert_eq 0 "$(ssh_count "$HELPER_PATH progress")" 'no polls'
}

test_up_v_prints_the_whole_journal_and_other_arguments_are_usage_errors() {
  world_running
  printf '%s\n' '1792839100 provision start' 'Reading package lists...' | ssh_reply ssh-host-journal
  run_cli up -v
  assert_rc 0
  assert_contains "$OUT" $'guest · done · 1m05s · created · first boot under way\nhost journal (helios-lab-provision.service, this run):\n  1792839100 provision start\n  Reading package lists...\nhost ready'
  assert_contains "$(ssh_calls)" "host sudo $HELPER_PATH journal all"
  local args
  for args in '-v -v' --verbose -x now; do
    # shellcheck disable=SC2086  # split the arguments
    run_cli up $args
    assert_rc 2
    assert_contains "$ERR" 'up takes no argument but -v'
  done
}

test_the_fragment_is_written_for_this_ip_before_the_first_ssh() {
  world_running
  run_cli up
  assert_rc 0
  local cfg
  cfg=$(<"$HELIOS_LAB_STATE_DIR/ssh_config")
  assert_contains "$cfg" $'Host host\n  HostName 203.0.113.10\n  HostKeyAlias '"$LAB_ID"
  assert_contains "$cfg" "  HostKeyAlias $LAB_ID-guest"
  assert_eq 700 "$(stat -f %Lp "$HELIOS_LAB_STATE_DIR" 2>/dev/null || stat -c %a "$HELIOS_LAB_STATE_DIR")" 'state dir mode'
}

# --- Progress protocol (pure, Mac side) --------------------------------------
test_progress_lines_show_each_finished_stage_with_its_elapsed_time() {
  load_cli
  assert_eq "$STAGE_LINES" "$(progress_lines "$(progress_reply 'done')")"
  assert_eq $'packages · unchanged\nlibvirt · unchanged\nguard · unchanged\nengvm · unchanged\nseed · unchanged\nguest · done · 0s · verified guest running' \
    "$(progress_lines "$(progress_reply unchanged)")"
  assert_eq 'guard · failed · 2s · loading /etc/helios-lab/guard.nft failed (nft -f): see the journal' \
    "$(progress_lines "$(progress_reply guard-failed)" | tail -1)"
  assert_eq '' "$(progress_lines "$(progress_reply packages-running)")" 'nothing has finished yet'
  assert_eq 'packages · done · 41s · 8 packages installed' "$(progress_lines "$(progress_reply libvirt-running)")"
}

test_progress_verdict_table() {
  load_cli
  local t=$RUN_EPOCH
  assert_eq 'done' "$(progress_verdict "$(progress_reply 'done')")"
  assert_eq 'done' "$(progress_verdict "$(progress_reply unchanged)")"
  assert_eq running "$(progress_verdict "$(progress_reply packages-running)")"
  assert_eq "failed${US}guard${US}loading /etc/helios-lab/guard.nft failed (nft -f): see the journal" \
    "$(progress_verdict "$(progress_reply guard-failed)")"
  assert_eq "failed${US}provision${US}the provision unit stopped before finishing (failed signal)" \
    "$(progress_verdict "$(progress_reply died)")"
  assert_eq "failed${US}provision${US}bad host config /etc/helios-lab/host.conf: ENGVM_PIN is missing; run helios-lab up" \
    "$(progress_verdict "$t provision start"$'\n'"$t provision fail bad host config /etc/helios-lab/host.conf: ENGVM_PIN is missing; run helios-lab up"$'\n''unit inactive success')"
  assert_eq "failed${US}provision${US}the provision unit stopped before finishing (inactive success)" \
    "$(progress_verdict 'unit inactive success')" 'an empty run that ended'
  assert_eq running "$(progress_verdict "$t provision start"$'\n''unit deactivating success')"
  assert_eq running "$(progress_verdict 'unit activating start-pre')"
  assert_eq "failed${US}provision${US}the host's progress reply had no unit state" "$(progress_verdict "$t provision start")"
  assert_eq running "$(progress_verdict $'garbage\n\nnot a line\nunit active running')" 'noise is ignored'
}

test_lines_after_prints_only_lines_not_yet_printed() {
  load_cli
  assert_eq $'c\nd' "$(lines_after 2 $'a\nb\nc\nd')"
  assert_eq $'a\nb' "$(lines_after 0 $'a\nb')"
  assert_eq '' "$(lines_after 2 $'a\nb')"
  assert_eq '' "$(lines_after 0 '')"
}

# --- The provision unit ------------------------------------------------------
test_the_unit_runs_the_helper_where_install_puts_it_as_type_exec() {
  local unit dest
  unit=$(code_of "$(<"$UNIT_FILE")")
  assert_eq 'Type=exec' "$(grep '^Type=' <<< "$unit")"
  assert_not_contains "$unit" 'RemainAfterExit'
  assert_eq "ExecStartPre=$HELPER_PATH progress-reset" "$(grep '^ExecStartPre=' <<< "$unit")"
  assert_eq "ExecStart=$HELPER_PATH provision" "$(grep '^ExecStart=' <<< "$unit")"
  assert_not_contains "$unit" '[Install]'   # only up starts it
  assert_eq "$HELPER_PATH" "$( ( load_cli; echo "$HOST_HELPER" ) )" 'the path the Mac calls'
  dest=$( host_env; install_dest helios-lab-host )
  assert_eq "$SANDBOX/root$HELPER_PATH 0755" "$dest" 'the path install writes'
  assert_eq helios-lab-provision.service "$( ( load_cli; echo "$PROVISION_UNIT" ) )"
}

# --- Host helper (pure) ------------------------------------------------------
test_sourcing_the_helper_runs_nothing() {
  local out
  out=$( host_env 2>&1; echo "sourced:$?" )
  assert_eq 'sourced:0' "$out"
  [[ ! -e $SANDBOX/root ]] || fail 'sourcing wrote files'
}

test_stage_decision_table() {
  host_env
  assert_eq run "$(stage_decision '' sha256:aa)" 'marker absent'
  assert_eq skip "$(stage_decision sha256:aa sha256:aa)" 'recorded input equals the pushed one'
  assert_eq run "$(stage_decision sha256:aa sha256:bb)" 'recorded input differs'
  assert_eq run "$(stage_decision '' '')" 'no input is never a skip'
  # A changed package list: the input of the old list differs from the pushed one.
  local old
  old=$(spec_input 'packages r1: qemu-system-x86 qemu-utils')
  assert_eq run "$(stage_decision "$old" "$(stage_input packages)")" 'changed package list'
  # A new engvm pin (U3's engvm stage records the pin itself as its input).
  assert_eq run "$(stage_decision "$PIN" 0123456789abcdef0123456789abcdef01234567)" 'new engvm pin'
  assert_eq skip "$(stage_decision "$PIN" "$PIN")" 'same engvm pin'
}

test_stage_inputs_hash_what_each_stage_applies() {
  host_env
  local s inputs='' input
  for s in packages libvirt guard; do
    input=$(stage_input "$s")
    [[ $input =~ ^sha256:[0-9a-f]{64}$ ]] || fail "$s: $input"
    assert_eq "$input" "$(stage_input "$s")" "$s is stable"
    [[ $inputs != *"$input"* ]] || fail "$s shares an input"
    inputs="$inputs $input"
  done
  assert_eq "$(spec_input "$(stage_spec packages)")" "$(stage_input packages)"
  for s in qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients libnss-libvirt cpu-checker cpio nftables; do
    assert_contains "$(stage_spec packages)" "$s"
  done
  assert_contains "$(stage_spec guard)" "$(guard_ruleset)"
  assert_contains "$(stage_spec libvirt)" "$(libvirt_guests_conf)"
  if stage_input bogus >/dev/null; then fail 'an input for an unknown stage'; fi
}

test_progress_lines_follow_the_protocol_grammar() {
  host_env
  assert_eq '1792839100 packages start' "$(progress_line 1792839100 packages start)"
  assert_eq '1792839100 guard fail nft said: line 2  oops' "$(progress_line 1792839100 guard fail $'nft said: line 2\n\toops')"
  assert_eq '1792839100 provision done' "$(progress_line 1792839100 provision 'done' '')"
  local bad
  for bad in 'x packages start' '1 Packages start' '1 packages finish' '1 -x start' '1 a_b start'; do
    # shellcheck disable=SC2086  # split the spec
    if progress_line $bad >/dev/null; then fail "accepted: $bad"; fi
  done
}

test_install_rules_cover_every_host_file() {
  host_env
  assert_eq "$SANDBOX/root/usr/local/libexec/helios-lab/helios-lab-host 0755" "$(install_dest helios-lab-host)"
  assert_eq "$SANDBOX/root/etc/systemd/system/helios-lab-provision.service 0644" "$(install_dest helios-lab-provision.service)"
  assert_eq "$SANDBOX/root/etc/helios-lab/host.conf 0644" "$(install_dest host.conf)"
  local f
  for f in "$HELIOS_LAB_HOME"/host/*; do
    install_dest "${f##*/}" >/dev/null || fail "no install rule for ${f##*/}"
  done
  for f in stray.conf helios-lab-host.bak ../x ''; do
    if install_dest "$f" >/dev/null; then fail "a rule for '$f'"; fi
  done
}

test_host_conf_rendered_on_the_mac_parses_on_the_host() {
  local conf
  conf=$( load_cli; render_host_config 60 "$PIN" )
  host_env
  assert_eq '' "$(conf_problem "$conf")"
  assert_eq 60 "$(conf_get "$conf" IDLE_MINUTES)"
  assert_eq "$PIN" "$(conf_get "$conf" ENGVM_PIN)"
  assert_eq 'ENGVM_PIN is missing' "$(conf_problem 'IDLE_MINUTES=60')"
  assert_eq 'IDLE_MINUTES is missing' "$(conf_problem "ENGVM_PIN=$PIN")"
  assert_eq 'IDLE_MINUTES=7 is not 5..720 in steps of 5' "$(conf_problem "IDLE_MINUTES=7"$'\n'"ENGVM_PIN=$PIN")"
  assert_eq 'ENGVM_PIN=8ef18ef is not a full commit hash' "$(conf_problem $'IDLE_MINUTES=60\nENGVM_PIN=8ef18ef')"
  assert_eq 'unexpected line: rm -rf /' "$(conf_problem "$conf"$'\nrm -rf /')"
}

test_nsswitch_gains_libvirt_guest_once() {
  host_env
  local ubuntu=$'# /etc/nsswitch.conf\npasswd:         files systemd\nhosts:          files dns\nnetworks:       files'
  local once
  once=$(with_libvirt_guest "$ubuntu")
  assert_eq $'# /etc/nsswitch.conf\npasswd:         files systemd\nhosts:          files libvirt_guest dns\nnetworks:       files' "$once"
  assert_eq "$once" "$(with_libvirt_guest "$once")" 'idempotent'
  assert_eq 'hosts:          files libvirt_guest' "$(with_libvirt_guest 'hosts:          files')"
  assert_eq 'hosts: libvirt_guest  dns files' "$(with_libvirt_guest 'hosts: dns files')"
}

test_environment_gets_exactly_one_system_uri() {
  host_env
  local env='PATH="/usr/local/sbin:/usr/bin"'
  assert_eq "$env"$'\nLIBVIRT_DEFAULT_URI=qemu:///system' "$(environment_with_uri "$env")"
  assert_eq "$env"$'\nLIBVIRT_DEFAULT_URI=qemu:///system' \
    "$(environment_with_uri "$env"$'\nLIBVIRT_DEFAULT_URI=qemu:///session\nLIBVIRT_DEFAULT_URI=qemu:///system')"
  assert_eq 'LIBVIRT_DEFAULT_URI=qemu:///system' "$(environment_with_uri '')"
}

test_libvirt_guests_shut_down_gracefully_and_never_start_from_here() {
  host_env
  assert_eq $'ON_BOOT=ignore\nON_SHUTDOWN=shutdown\nSHUTDOWN_TIMEOUT=120' "$(libvirt_guests_conf | grep -v '^#')"
}

test_guard_ruleset_is_the_spike_validated_atomic_file() {
  host_env
  # The file the U7 host loaded with nft -f (twice: the second run proved it idempotent).
  assert_eq 'table inet helios_lab_guard
delete table inet helios_lab_guard
table inet helios_lab_guard {
  chain forward_guard {
    type filter hook forward priority -10; policy accept;
    iifname "virbr0" ip daddr 169.254.0.0/16 drop
  }
}' "$(guard_ruleset | grep -v '^#')"
  assert_not_contains "$(guard_ruleset)" 'chain fwd'
}

test_the_guard_loads_at_boot_before_libvirtd_and_never_flushes_anything() {
  host_env
  local unit
  unit=$(guard_unit)
  assert_contains "$unit" 'ExecStart=/usr/sbin/nft -f /etc/helios-lab/guard.nft'
  assert_contains "$unit" 'Before=network-pre.target libvirtd.service'
  assert_contains "$unit" $'Type=oneshot\nRemainAfterExit=yes'
  assert_contains "$unit" $'WantedBy=sysinit.target\nRequiredBy=libvirtd.service'   # fail closed
  assert_not_contains "$unit" 'ExecStop'
  assert_not_contains "$unit" 'flush'
}

# --- Host helper: stages against faked tools ---------------------------------
# The stage functions themselves, with the tools they drive replaced by
# functions that record their arguments: the command sequences and flags are
# checked on the Mac; only the tools' real effects stay live-only.

# stage_call <stage function> — runs it as apply_stage does; sets RC and
# SUMMARY (its fd-3 line); its stdout and stderr go to $SANDBOX/stage.out
stage_call() {
  RC=0
  SUMMARY=$("$1" 3>&1 1>>"$SANDBOX/stage.out" 2>&1) || RC=$?
}

# tools_log — what the faked tools were asked to do, one call per line
tools_log() { cat "$SANDBOX/tools.log" 2>/dev/null || true; }

# shellcheck disable=SC2329  # the fakes are called by the stages
fake_tools() {
  tool() { echo "$*" >> "$SANDBOX/tools.log"; }
  systemctl() { tool systemctl "$@"; }
  nft() { tool nft "$@"; [[ $1 != list ]] || printf '%s\n' "$NFT_LISTING"; }
  usermod() { tool usermod "$@"; }
  virsh() { tool virsh "$@"; [[ $3 != net-info ]] || printf 'Name: default\nActive: %s\n' "$NET_ACTIVE"; }
  apt-get() { tool apt-get "$@"; fail_first apt-get "$APT_LOCKED"; }
  dpkg() { tool dpkg "$@"; fail_first dpkg "$DPKG_LOCKED"; }
  timeout() { tool timeout "$@"; return 2; }   # cloud-init status --wait: "degraded"
  sleep() { tool sleep "$@"; }
  kvm_usable() { [[ $KVM == yes ]]; }
  # snap remove --purge <name>: removes the snap's /snap/<name>, as snapd
  # does, unless SNAP_FAILS is set
  snap() {
    tool snap "$@"
    [[ $1 == remove ]] || return 0
    [[ -z ${SNAP_FAILS:-} ]] || { echo "error: cannot remove \"$3\": hand-written failure" >&2; return 1; }
    rm -rf "$SANDBOX/root/snap/$3"
  }
}

# fail_first <tool> <what it says while another apt holds the lock> — the
# tool fails while its $FAILS calls remain (only FAIL_TOOL fails, when set),
# saying FAIL_SAYS when set (a failure that is no held lock), else that line
fail_first() {
  local counter=$SANDBOX/fails.$1 left
  [[ -z ${FAIL_TOOL:-} || $FAIL_TOOL == "$1" ]] || return 0
  left=$(cat "$counter" 2>/dev/null || echo "${FAILS:-0}")
  (( left > 0 )) || return 0
  echo $(( left - 1 )) > "$counter"
  printf '%s\n' "${FAIL_SAYS:-$2}" >&2
  return 100
}

# What apt (2.7, Ubuntu 24.04) and dpkg (1.22) print while another run holds
# the lock: hand-written in their shapes, as no capture has them
readonly APT_LOCKED='E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 4242 (unattended-upgr)'
readonly DPKG_LOCKED='dpkg: error: dpkg frontend lock was locked by another process with pid 4242'

test_the_packages_stage_waits_out_apt_locks_and_never_prompts() {
  host_env
  fake_tools
  FAILS=2 stage_call stage_packages   # dpkg and apt-get update each find a lock twice
  assert_eq 0 "$RC" "the stage failed: $(<"$SANDBOX/stage.out")"
  assert_eq '8 packages installed' "$SUMMARY"
  local apt='apt-get -o DPkg::Lock::Timeout=15 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -q'
  assert_eq "timeout 600 cloud-init status --wait
dpkg --configure -a
sleep 10
dpkg --configure -a
sleep 10
dpkg --configure -a
$apt update
sleep 10
$apt update
sleep 10
$apt update
$apt -y install qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients libnss-libvirt cpu-checker cpio nftables" "$(tools_log)"
  assert_contains "$(<"$SANDBOX/stage.out")" 'cloud-init did not report done; continuing'
  assert_contains "$(<"$SANDBOX/stage.out")" "$APT_LOCKED"   # what apt said reaches the journal
}

test_the_packages_stage_gives_up_after_its_lock_retries_with_a_reason() {
  host_env
  fake_tools
  FAILS=99 stage_call stage_packages
  assert_eq 1 "$RC"
  assert_eq 'dpkg --configure -a found the lock held in 30 tries, 10s apart, over about 5 min: another apt or dpkg run holds it (see the journal)' "$SUMMARY"
  assert_eq "$LOCK_TRIES" "$(tools_log | grep -c '^dpkg ')" 'bounded tries'
  assert_eq $(( LOCK_TRIES - 1 )) "$(tools_log | grep -c '^sleep 10$')" 'a wait between tries'
  assert_eq 0 "$(tools_log | grep -c '^apt-get ' || true)" 'no apt after dpkg failed'
}

# The AMI's SSM agent snap could open Session Manager past the ssh ingress
# rule (helios-lab-host SSM_SNAP): purged first, before any apt step; a host
# without it is left alone; a removal that fails fails the stage.
test_the_packages_stage_purges_the_ssm_agent_snap_and_tolerates_its_absence() {
  host_env
  fake_tools
  local snapdir=$SANDBOX/root/snap/amazon-ssm-agent
  mkdir -p "$snapdir/current"
  stage_call stage_packages
  assert_eq 0 "$RC" "the stage failed: $(<"$SANDBOX/stage.out")"
  assert_eq '8 packages installed · amazon-ssm-agent removed' "$SUMMARY"
  assert_eq $'timeout 600 cloud-init status --wait\ntimeout 300 snap wait system seed.loaded\nsnap remove --purge amazon-ssm-agent\ndpkg --configure -a' \
    "$(tools_log | sed -n 1,4p)" 'seeded, purged, then apt'
  [[ ! -e $snapdir ]] || fail 'the snap is still installed'
  # Absent (a second run, or an AMI without it): no snap call at all.
  : > "$SANDBOX/tools.log"
  stage_call stage_packages
  assert_eq 0 "$RC"
  assert_eq '8 packages installed' "$SUMMARY"
  assert_eq 0 "$(tools_log | grep -c 'snap' || true)" 'snap calls'
  # A removal snapd refuses fails the stage before apt runs.
  : > "$SANDBOX/tools.log"
  mkdir -p "$snapdir/current"
  SNAP_FAILS=1 stage_call stage_packages
  assert_eq 1 "$RC"
  assert_eq 'cannot remove the amazon-ssm-agent snap (see the journal): with SSM Default Host Management it is a way in past the ssh ingress rule' "$SUMMARY"
  assert_eq 0 "$(tools_log | grep -c '^apt-get ' || true)" 'no apt after the failed removal'
}

test_the_ssm_agent_is_in_the_packages_input_and_its_return_fails_the_live_check() {
  host_env
  assert_contains "$(stage_spec packages)" 'snap remove --purge amazon-ssm-agent'
  # A host provisioned before the removal existed runs the stage again.
  assert_eq run "$(stage_decision "$(spec_input "packages r1: $PACKAGES")" "$(stage_input packages)")"
  # shellcheck disable=SC2329  # called by check_packages
  dpkg-query() { local n; for (( n = 1; n <= 8; n++ )); do echo 'install ok installed'; done; }
  check_packages || fail 'all packages installed and no agent failed its check'
  mkdir -p "$SANDBOX/root/snap/amazon-ssm-agent"
  if check_packages; then fail 'the agent back passed the live check'; fi
}

# apt waits for dpkg's frontend lock itself, but only briefly: the retry
# loop governs, and its message states the budget it really spent
test_an_apt_lock_held_throughout_fails_stating_the_true_budget() {
  host_env
  fake_tools
  FAILS=99 FAIL_TOOL=apt-get stage_call stage_packages
  assert_eq 1 "$RC"
  assert_eq 'apt-get update found the lock held in 30 tries, 10s apart, over about 12 min: another apt or dpkg run holds it (see the journal)' "$SUMMARY"
  assert_eq "$LOCK_TRIES" "$(tools_log | grep -c "^apt-get -o DPkg::Lock::Timeout=$APT_LOCK_WAIT_S ")" 'bounded tries, each bounded'
  # 30 tries of at most 15 s inside apt, 29 waits of 10 s between them
  assert_eq 740 "$(lock_budget_s "$APT_LOCK_WAIT_S")"
  assert_eq 290 "$(lock_budget_s 0)" 'dpkg fails at once: only the waits between tries'
  (( APT_LOCK_WAIT_S <= 2 * LOCK_WAIT_S )) || fail "apt's own lock wait ($APT_LOCK_WAIT_S s) would govern the loop"
}

test_a_packages_failure_that_is_not_a_held_lock_fails_at_once_with_apts_own_line() {
  host_env
  fake_tools
  local says=$'Reading package lists...\nE: Unable to locate package nftables'
  FAILS=99 FAIL_TOOL=apt-get FAIL_SAYS=$says stage_call stage_packages
  assert_eq 1 "$RC"
  assert_eq 'apt-get update failed (exit 100): E: Unable to locate package nftables' "$SUMMARY"
  assert_eq 1 "$(tools_log | grep -c '^apt-get ')" 'one try'
  assert_eq 0 "$(tools_log | grep -c '^sleep ' || true)" 'no wait'
  assert_contains "$(<"$SANDBOX/stage.out")" "$says"   # apt's whole say, in the journal
  : > "$SANDBOX/tools.log"; rm -f "$SANDBOX"/fails.*
  FAILS=99 FAIL_TOOL=dpkg FAIL_SAYS='dpkg: error processing package libvirt-daemon (--configure): subprocess installed post-installation script returned error exit status 1' \
    stage_call stage_packages
  assert_eq 'dpkg --configure -a failed (exit 100): dpkg: error processing package libvirt-daemon (--configure): subprocess installed post-installation script returned error exit status 1' "$SUMMARY"
  assert_eq 1 "$(tools_log | grep -c '^dpkg ')" 'one try'
}

test_only_a_held_lock_is_worth_waiting_out() {
  host_env
  local text
  # Hand-written in the shapes apt 2.7 and dpkg 1.22 (and dpkg before 1.21) print
  for text in "$APT_LOCKED" "$DPKG_LOCKED" \
              'E: Unable to acquire the dpkg frontend lock (/var/lib/dpkg/lock-frontend), is another process using it?' \
              $'E: Could not get lock /var/lib/apt/lists/lock. It is held by process 4242 (apt-get)\nE: Unable to lock directory /var/lib/apt/lists/' \
              'dpkg: error: dpkg status database is locked by another process'; do
    lock_held "$text" || fail "not taken for a held lock: $text"
  done
  for text in '' 'E: Unable to locate package nftables' 'E: Failed to fetch http://archive.ubuntu.com/ubuntu/dists/noble/InRelease' \
              'dpkg: error processing package x (--configure):' 'E: Sub-process /usr/bin/dpkg returned an error code (1)'; do
    if lock_held "$text"; then fail "taken for a held lock: $text"; fi
  done
  assert_eq 'E: Unable to locate package nftables' "$(apt_said $'Reading package lists...\nE: Unable to locate package nftables\nE: second')"
  assert_eq 'dpkg: error: x' "$(apt_said $'noise\ndpkg: error: x')"
  assert_eq 'the last line' "$(apt_said $'first\nthe last line\n  ')" 'no error line: the last one'
  assert_eq '' "$(apt_said '')"
}

test_the_libvirt_stage_checks_kvm_first_then_configures_libvirt() {
  host_env
  fake_tools
  local root=$SANDBOX/root
  mkdir -p "$root/etc/default"
  printf '%s\n' 'PATH="/usr/bin"' > "$root/etc/environment"
  printf '%s\n' 'passwd: files' 'hosts:          files dns' > "$root/etc/nsswitch.conf"
  KVM=no NET_ACTIVE=no stage_call stage_libvirt
  assert_eq 1 "$RC"
  assert_contains "$SUMMARY" 'no usable /dev/kvm: the instance needs nested virtualization'
  assert_eq '' "$(tools_log)" 'nothing configured without KVM'
  KVM=yes NET_ACTIVE=no stage_call stage_libvirt
  assert_eq 0 "$RC" "the stage failed: $(<"$SANDBOX/stage.out")"
  assert_eq 'kvm ok, default network active' "$SUMMARY"
  assert_eq 'usermod -aG libvirt,kvm ubuntu
systemctl enable --now libvirt-guests.service
virsh -c qemu:///system net-autostart default
virsh -c qemu:///system net-info default
virsh -c qemu:///system net-start default' "$(tools_log)"
  assert_eq $'PATH="/usr/bin"\nLIBVIRT_DEFAULT_URI=qemu:///system' "$(<"$root/etc/environment")"
  assert_eq 'hosts:          files libvirt_guest dns' "$(grep '^hosts:' "$root/etc/nsswitch.conf")"
  assert_eq "$(libvirt_guests_conf)" "$(<"$root/etc/default/libvirt-guests")"
  : > "$SANDBOX/tools.log"
  KVM=yes NET_ACTIVE=yes stage_call stage_libvirt   # again, on a configured host
  assert_eq 0 "$RC"
  assert_not_contains "$(tools_log)" 'net-start'
  assert_eq 1 "$(grep -c '^LIBVIRT_DEFAULT_URI=' "$root/etc/environment")" 'still one URI line'
}

test_the_guard_stage_loads_the_ruleset_without_restarting_anything() {
  host_env
  fake_tools
  NFT_LISTING=$'table inet helios_lab_guard {\n\tchain forward_guard {\n\t\tiifname "virbr0" ip daddr 169.254.0.0/16 drop\n\t}\n}'
  stage_call stage_guard
  assert_eq 0 "$RC" "the stage failed: $(<"$SANDBOX/stage.out")"
  assert_eq 'virbr0 to 169.254.0.0/16 dropped' "$SUMMARY"
  assert_eq "systemctl daemon-reload
systemctl enable helios-lab-guard.service
nft -f $SANDBOX/root/etc/helios-lab/guard.nft
systemctl start helios-lab-guard.service
systemctl is-enabled --quiet helios-lab-guard.service
nft list chain inet helios_lab_guard forward_guard" "$(tools_log)"
  assert_eq "$(guard_ruleset)" "$(<"$SANDBOX/root/etc/helios-lab/guard.nft")"
  assert_eq "$(guard_unit)" "$(<"$SANDBOX/root/etc/systemd/system/helios-lab-guard.service")"
  : > "$SANDBOX/tools.log"
  NFT_LISTING='table inet helios_lab_guard {}'   # loaded, but the chain is missing
  stage_call stage_guard
  assert_eq 1 "$RC"
  assert_eq 'the guard chain is not loaded after nft -f' "$SUMMARY"
}

test_live_checks_read_their_tools_output() {
  host_env
  # The listing the U7 host printed after loading the guard (its host-setup log).
  local listing=$'table inet helios_lab_guard {\n\tchain forward_guard {\n\t\ttype filter hook forward priority filter - 10; policy accept;\n\t\tiifname "virbr0" ip daddr 169.254.0.0/16 drop\n\t}\n}'
  local enabled=0 nft_out=$listing
  # shellcheck disable=SC2329  # called by check_guard
  systemctl() { return "$enabled"; }
  # shellcheck disable=SC2329  # called by check_guard
  nft() { [[ -n $nft_out ]] || return 1; printf '%s\n' "$nft_out"; }
  check_guard || fail 'a loaded guard failed its check'
  nft_out=''
  if check_guard; then fail 'no table passed'; fi
  nft_out=$listing enabled=1
  if check_guard; then fail 'a guard unit that is not enabled passed'; fi
  # Hand-written: the shape of `virsh net-info`.
  # (The fakes' variables have names the helper's locals don't shadow.)
  local fake_info=$'Name:           default\nUUID:           00000000-0000-0000-0000-000000000000\nActive:         yes\nPersistent:     yes\nAutostart:      yes\nBridge:         virbr0'
  # shellcheck disable=SC2329  # called by net_active
  virsh() { printf '%s\n' "$fake_info"; }
  net_active || fail 'an active network failed its check'
  fake_info=${fake_info/Active:         yes/Active:         no}
  if net_active; then fail 'an inactive network passed'; fi
  local installed=8
  # shellcheck disable=SC2329  # called by check_packages
  dpkg-query() { local n; for (( n = 1; n <= installed; n++ )); do echo 'install ok installed'; done; }
  check_packages || fail 'all packages installed failed its check'
  installed=7
  if check_packages; then fail 'a missing package passed'; fi
}

# --- Host helper: provisioning runs (stages faked) ---------------------------
test_provision_runs_every_stage_once_then_skips_them_all() {
  host_env
  fake_stages
  host_conf_ok
  provision_run > "$SANDBOX/journal"
  assert_eq "provision start
packages start
packages done 8 packages installed
libvirt start
libvirt done kvm ok, default network active
guard start
guard done virbr0 to 169.254.0.0/16 dropped
engvm start
engvm done @8ef18ef · lab: $LAB_SIZING
seed start
seed done verified against engvm's pinned checksums
guest start
guest done created · first boot under way
provision done" "$(events)"
  assert_eq 'packages libvirt guard engvm seed guest' "$(ran)"
  local s conf lab
  conf=$(<"$SANDBOX/root/etc/helios-lab/host.conf")
  lab=$(<"$SANDBOX/root/etc/helios-lab/engvm-lab.sh")
  for s in packages libvirt guard engvm seed; do
    assert_eq "$(stage_input "$s" "$conf" "$lab")" "$(marker "$s")" "$s marker"
  done
  [[ ! -e $SANDBOX/root/var/lib/helios-lab/stage.guest ]] || fail 'the guest stage wrote a stage marker'
  assert_contains "$(<"$SANDBOX/journal")" 'apt says hello'   # a stage's output reaches the journal
  assert_contains "$(<"$SANDBOX/journal")" 'packages done 8 packages installed'
  # Re-running provision on a completed host skips every stage but guest,
  # which guest-verified, not a stage marker, governs.
  : > "$SANDBOX/ran"
  cmd_progress_reset
  provision_run > /dev/null
  assert_eq $'provision start\npackages skip\nlibvirt skip\nguard skip\nengvm skip\nseed skip\nguest start\nguest done created · first boot under way\nprovision done' "$(events)"
  assert_eq 'guest' "$(ran)"
}

test_a_changed_input_or_a_failed_live_check_reruns_only_that_stage() {
  host_env
  fake_stages
  host_conf_ok
  provision_run > /dev/null
  echo 'sha256:0000' > "$SANDBOX/root/var/lib/helios-lab/stage.libvirt"   # an older libvirt stage
  # shellcheck disable=SC2329  # called by run_stage
  check_guard() { false; }                                                  # say, the table didn't load at boot
  : > "$SANDBOX/ran"
  cmd_progress_reset
  provision_run > /dev/null
  assert_eq 'libvirt guard guest' "$(ran)"
  assert_eq 'packages skip' "$(events | sed -n 2p)"
  assert_eq "$(stage_input libvirt)" "$(marker libvirt)" 'the marker records the new input'
}

test_a_failing_stage_records_its_reason_and_stops_the_run() {
  host_env
  fake_stages
  host_conf_ok
  # shellcheck disable=SC2329  # called by apply_stage
  stage_libvirt() { echo libvirt >> "$SANDBOX/ran"; echo 'checking /dev/kvm'; stage_fail 'no usable /dev/kvm: the instance needs nested virtualization'; }
  RC=0; provision_run > "$SANDBOX/journal" || RC=$?
  assert_eq 1 "$RC"
  assert_eq 'provision start
packages start
packages done 8 packages installed
libvirt start
libvirt fail no usable /dev/kvm: the instance needs nested virtualization
provision fail libvirt' "$(events)"
  assert_eq 'packages libvirt' "$(ran)" 'guard never ran'
  [[ ! -e $SANDBOX/root/var/lib/helios-lab/stage.libvirt ]] || fail 'a failed stage wrote its marker'
  assert_contains "$(<"$SANDBOX/journal")" 'checking /dev/kvm'
  # A stage that just exits non-zero still gets a reason.
  # shellcheck disable=SC2329  # called by apply_stage
  stage_libvirt() { return 3; }
  cmd_progress_reset
  RC=0; provision_run > /dev/null || RC=$?
  assert_eq 'libvirt fail exited 3; see the journal' "$(events | grep '^libvirt fail')"
}

test_a_bad_or_missing_host_config_fails_before_any_stage() {
  host_env
  fake_stages
  RC=0; provision_run > /dev/null || RC=$?
  assert_eq 1 "$RC"
  assert_eq "provision fail bad host config $SANDBOX/root/etc/helios-lab/host.conf: missing or empty; run helios-lab up" "$(events | sed -n 2p)"
  mkdir -p "$SANDBOX/root/etc/helios-lab"
  echo 'IDLE_MINUTES=60' > "$SANDBOX/root/etc/helios-lab/host.conf"
  cmd_progress_reset
  RC=0; provision_run > /dev/null || RC=$?
  assert_contains "$(events)" 'ENGVM_PIN is missing'
  assert_eq '' "$(ran)" 'no stage ran'
}

test_the_helpers_progress_is_exactly_what_the_mac_parses() {
  local snapshot failed
  snapshot=$( host_env; fake_stages; host_conf_ok; provision_run > /dev/null; unit_inactive; cmd_progress )
  rm -rf "$SANDBOX/root"   # a fresh host: no markers from the run above
  # shellcheck disable=SC2329  # stage_guard is called by apply_stage
  failed=$( host_env; fake_stages; host_conf_ok
            stage_guard() { stage_fail 'loading /etc/helios-lab/guard.nft failed (nft -f): see the journal'; }
            provision_run > /dev/null || true; unit_inactive; cmd_progress )
  assert_eq 'unit inactive success' "$(tail -1 <<< "$snapshot")"
  load_cli
  assert_eq 'done' "$(progress_verdict "$snapshot")"
  # Elapsed is whatever the clock said (0s or 1s): normalized.
  assert_eq "$(sed -E 's/ · [0-9m]+s · / · Ns · /' <<< "$STAGE_LINES")" "$(progress_lines "$snapshot" | sed -E 's/ · [0-9]+s · / · Ns · /')"
  assert_eq "failed${US}guard${US}loading /etc/helios-lab/guard.nft failed (nft -f): see the journal" "$(progress_verdict "$failed")"
  # The hand-written replies every Mac test uses have the same shape.
  assert_eq "$(drop_epochs <<< "$snapshot")" "$(progress_reply 'done' | drop_epochs)"
}

# unit_inactive — after host_env: systemctl answers as for a finished run,
# one `systemctl show` block per unit asked for (from its 6th argument on)
# shellcheck disable=SC2329  # called through cmd_progress
unit_inactive() {
  systemctl() {
    local sep=''
    for _ in "${@:6}"; do printf '%sActiveState=inactive\nResult=success\n' "$sep"; sep=$'\n'; done
  }
}

test_progress_reset_empties_the_file_and_progress_reports_an_unknown_unit() {
  host_env
  host_conf_ok
  fake_stages
  provision_run > /dev/null
  cmd_progress_reset
  assert_eq '' "$(<"$SANDBOX/root/var/lib/helios-lab/progress")"
  # shellcheck disable=SC2329  # called by unit_property
  systemctl() { return 1; }
  assert_eq 'unit unknown unknown' "$(cmd_progress)"
}

test_journal_reads_the_unit_since_the_runs_first_line() {
  host_env
  host_conf_ok
  fake_stages
  # shellcheck disable=SC2329  # called by cmd_journal
  journalctl() { echo "journalctl $*"; }
  assert_eq "journalctl -u helios-lab-provision.service -o cat --no-pager -n 20" "$(cmd_journal 20)" 'no run yet'
  provision_run > /dev/null
  local since
  since=$(cut -d' ' -f1 "$SANDBOX/root/var/lib/helios-lab/progress" | head -1)
  assert_eq "journalctl -u helios-lab-provision.service -o cat --no-pager --since @$since -n 20" "$(cmd_journal 20)"
  assert_eq "journalctl -u helios-lab-provision.service -o cat --no-pager --since @$since" "$(cmd_journal all)"
  RC=0; ( cmd_journal 'x; rm' ) 2>/dev/null || RC=$?
  assert_eq 1 "$RC" 'a bad line count'
}

run_tests
