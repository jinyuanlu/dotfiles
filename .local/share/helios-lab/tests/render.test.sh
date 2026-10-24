#!/bin/bash
# shellcheck source-path=SCRIPTDIR
#
# render.test.sh — U2's pure renderers in lib/render.sh: the ssh fragment,
# the host config and the push bundle, called directly after load_cli. Their
# use in a real `up` (written before the first ssh, pushed every time) is
# remote.test.sh's subject.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly HOST_IP=203.0.113.10      # documentation range, as in the fixtures
readonly PIN=8ef18ef53d3baa03eebe5f2238a3a4ceef1b6f4a

# host_block <alias> <config> -> that Host block's settings, unindented
host_block() {
  awk -v alias="$1" '$1 == "Host" { inside = ($2 == alias); next } inside && NF { sub(/^  /, ""); print }' <<< "$2"
}

# --- ssh fragment ------------------------------------------------------------
test_fragment_for_i_0abc_has_the_two_aliases_the_plan_names() {
  load_cli
  local key=$HOME/.ssh/helios-lab_ed25519 kh=$HELIOS_LAB_STATE_DIR/known_hosts cfg common
  cfg=$(render_ssh_config i-0abc "$HOST_IP" "$key" "$kh")
  common="User ubuntu
IdentityFile \"$key\"
IdentitiesOnly yes
AddKeysToAgent yes
UseKeychain yes
UserKnownHostsFile \"$kh\"
ForwardAgent no
ServerAliveInterval 60
ConnectTimeout 15"
  assert_eq "HostName $HOST_IP
HostKeyAlias i-0abc
StrictHostKeyChecking yes
HostKeyAlgorithms ssh-ed25519
$common" "$(host_block host "$cfg")" 'the host alias'
  assert_eq "HostName helios
ProxyJump host
HostKeyAlias i-0abc-guest
StrictHostKeyChecking accept-new
$common" "$(host_block guest "$cfg")" 'the guest alias'
  assert_eq $'Host host\nHost guest' "$(grep '^Host ' <<< "$cfg")" 'exactly two aliases'
  # Global lines (before the first Host) apply to both; only IgnoreUnknown is there.
  assert_eq 'IgnoreUnknown UseKeychain' "$(sed '/^Host /,$d' <<< "$cfg" | grep -v '^#' | grep .)"
}

test_the_entry_keeps_known_hosts_and_the_fragment_in_the_state_dir() {
  load_cli
  assert_eq "$HELIOS_LAB_STATE_DIR/known_hosts" "$KNOWN_HOSTS"
  assert_eq "$HELIOS_LAB_STATE_DIR/ssh_config" "$SSH_CONFIG"
  assert_eq "$HOME/.ssh/helios-lab_ed25519" "$LAB_KEY"
}

test_no_alias_trusts_a_key_on_first_use_except_the_guest_behind_the_verified_hop() {
  load_cli
  local cfg
  cfg=$(render_ssh_config i-0abc "$HOST_IP" /k /kh)
  assert_not_contains "$cfg" 'StrictHostKeyChecking no'
  assert_eq 'StrictHostKeyChecking yes' "$(host_block host "$cfg" | grep StrictHostKeyChecking)"
  assert_eq 'StrictHostKeyChecking accept-new' "$(host_block guest "$cfg" | grep StrictHostKeyChecking)"
  assert_not_contains "$cfg" 'ForwardAgent yes'
}

test_fragment_paths_are_quoted_with_percent_doubled() {
  load_cli
  local cfg
  cfg=$(render_ssh_config i-0abc "$HOST_IP" '/Users/a b/.ssh/k%1' '/Users/a b/state/known_hosts')
  assert_contains "$cfg" '  IdentityFile "/Users/a b/.ssh/k%%1"'
  assert_contains "$cfg" '  UserKnownHostsFile "/Users/a b/state/known_hosts"'
}

test_fragment_refuses_what_it_cannot_render_safely() {
  load_cli
  local args id ip key kh
  for args in "i-XYZ|$HOST_IP|/k|/kh" "sg-0abc|$HOST_IP|/k|/kh" "|$HOST_IP|/k|/kh" \
              'i-0abc|2001:db8::1|/k|/kh' 'i-0abc|None|/k|/kh' 'i-0abc||/k|/kh' \
              "i-0abc|$HOST_IP|relative/k|/kh" "i-0abc|$HOST_IP|/k|/a\"b" "i-0abc|$HOST_IP|/k|"; do
    IFS='|' read -r id ip key kh <<< "$args"
    if render_ssh_config "$id" "$ip" "$key" "$kh" >/dev/null; then fail "rendered: $args"; fi
  done
  if render_ssh_config i-0abc "$HOST_IP" $'/k\nIdentityFile /evil' /kh >/dev/null; then fail 'rendered a newline in a path'; fi
}

# --- Host config -------------------------------------------------------------
test_host_config_carries_idle_minutes_and_the_pin_and_nothing_else() {
  load_cli
  local conf
  conf=$(render_host_config 60 "$PIN")
  assert_eq $'IDLE_MINUTES=60\nENGVM_PIN='"$PIN" "$(grep -v '^#' <<< "$conf")"
  assert_eq '#' "$(grep -v '^[A-Z_]*=' <<< "$conf" | cut -c1 | sort -u)" 'everything else is a comment'
  assert_contains "$(render_host_config 90 "$PIN")" 'IDLE_MINUTES=90'
  assert_eq "$PIN" "$ENGVM_PIN" "the entry's pin"
}

test_host_config_refuses_values_the_host_would_refuse() {
  load_cli
  local spec idle pin upper
  upper=$(tr a-f A-F <<< "$PIN")
  for spec in "7|$PIN" "0|$PIN" "725|$PIN" "x|$PIN" "|$PIN" '60|8ef18ef' "60|$upper" '60|' "60|${PIN}0"; do
    IFS='|' read -r idle pin <<< "$spec"
    if render_host_config "$idle" "$pin" >/dev/null; then fail "rendered: $spec"; fi
  done
}

# --- Push bundle -------------------------------------------------------------
test_push_bundle_writes_each_file_verbatim_and_nothing_else() {
  load_cli
  # shellcheck disable=SC2016  # the point: nothing in a file may expand
  local tricky='#!/bin/bash
echo "$HOME" `id` $(rm -rf /) \n\t'"'"'single'"'"' %s
	tab-indented, trailing space
EOF
HELIOS_LAB_PUSH_EOF is fine inside a line'
  local bundle out=$SANDBOX/unpacked
  bundle=$(render_push_bundle tricky "$tricky" empty '' host.conf "$(render_host_config 60 "$PIN")")
  mkdir -p "$out"
  (cd "$out" && /bin/bash -s) <<< "$bundle"
  assert_eq "$tricky" "$(<"$out/tricky")" 'verbatim'
  assert_eq $(( $(printf '%s\n' "$tricky" | wc -c) )) $(( $(wc -c < "$out/tricky") )) 'exactly one trailing newline'
  assert_eq 1 $(( $(wc -c < "$out/empty") )) 'an empty file is one newline'
  assert_eq "$(render_host_config 60 "$PIN")" "$(<"$out/host.conf")"
  assert_eq $'empty\nhost.conf\ntricky' "$(ls -A "$out")" 'nothing else was written'
}

test_push_bundle_refuses_the_delimiter_line_and_odd_names() {
  load_cli
  local name
  for name in '' '../x' 'a/b' '.hidden' '-x' 'a b' $'a\nb' "a'b"; do
    if render_push_bundle "$name" content >/dev/null; then fail "bundled the name '$name'"; fi
  done
  if render_push_bundle f $'line\nHELIOS_LAB_PUSH_EOF\nmore' >/dev/null; then fail 'bundled the delimiter line'; fi
  if render_push_bundle f content orphan >/dev/null; then fail 'bundled an odd argument count'; fi
  render_push_bundle helios-lab-host x helios-lab-provision.service y >/dev/null || fail 'refused the real names'
}

run_tests
