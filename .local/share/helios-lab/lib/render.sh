# shellcheck shell=bash
#
# helios-lab render.sh — pure renderers: the instance user-data, and the
# structured AWS CLI arguments the launch and the security group need (U6);
# the ssh fragment, the host config and the push bundle (U2).
#
# Pure, like state.sh: output depends only on the arguments. Nothing here
# reads files, the environment or the clock, which is what makes "no secret
# reaches the user-data" checkable: the only input is the public key.

# --- User-data ---------------------------------------------------------------
# ed25519 public keys are 68 base64 characters, always with this prefix (the
# encoded key-type string).
readonly ED25519_PUB_RE='^ssh-ed25519 (AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43})( [^[:cntrl:]]*)?$'

# pubkey_material <public-key line> -> "ssh-ed25519 <base64>", the comment
# dropped (ssh-keygen defaults it to user@host, which has no business in
# user-data). Fails on anything else, including any private key.
pubkey_material() {
  [[ $1 =~ $ED25519_PUB_RE ]] || return 1
  echo "ssh-ed25519 ${BASH_REMATCH[1]}"
}

# render_user_data <public-key line> -> cloud-config text. Exactly the design
# the U7 spike validated live (tests/fixtures/user-data.spike.yaml), with the
# lab key in place of the spike's throwaway one:
# - the authorized public key, for the default user (ubuntu)
# - helios-lab-hostkeys.service, which prints the host-key fingerprints to the
#   console on every boot between fixed markers (U2 verifies against them)
# - helios-lab-deadman.timer, which powers the host off 2h after each boot,
#   until U4's first push enables the idle timer and disarms it
# Invariant: no credential, private key or pointer to a secret reaches the
# user-data. The public key is the only input, and it is shape-checked.
render_user_data() {
  local key
  key=$(pubkey_material "$1") || return 1
  printf '%s\n' '#cloud-config' \
    '# helios-lab user-data (lib/render.sh): the lab public key, a per-boot' \
    '# host-key fingerprint printer and a 2h dead-man timer. No secrets.' \
    'ssh_authorized_keys:' "  - $key helios-lab" ''
  cat <<'EOF'
write_files:
  - path: /etc/systemd/system/helios-lab-hostkeys.service
    content: |
      [Unit]
      Description=Print SSH host key fingerprints to the console (every boot)
      After=cloud-init.service ssh.socket
      [Service]
      Type=oneshot
      ExecStart=/bin/sh -c 'exec >/dev/console 2>&1; echo "-----BEGIN HELIOS-LAB HOST KEYS-----"; for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$f"; done; echo "-----END HELIOS-LAB HOST KEYS-----"'
      [Install]
      WantedBy=multi-user.target
  - path: /etc/systemd/system/helios-lab-deadman.service
    content: |
      [Unit]
      Description=helios-lab dead-man stop (no idle timer installed yet)
      [Service]
      Type=oneshot
      ExecStart=/usr/bin/systemctl poweroff
  - path: /etc/systemd/system/helios-lab-deadman.timer
    content: |
      [Unit]
      Description=helios-lab dead-man timer: power off 2h after boot
      [Timer]
      OnBootSec=2h
      Unit=helios-lab-deadman.service
      [Install]
      WantedBy=timers.target

runcmd:
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, helios-lab-deadman.timer]
  - [systemctl, enable, --now, helios-lab-hostkeys.service]
EOF
}

# --- CLI arguments -----------------------------------------------------------
# Shorthand syntax, as the spike ran it. Values never need quoting: tag values
# are fixed names or a SHA256 fingerprint ([A-Za-z0-9+/:]), and the CLI's own
# shorthand parser reads them back unchanged.

# render_tag_spec <resource-type> <Key=Value>... -> one --tag-specifications item
render_tag_spec() {
  local type=$1 kv tags=''
  shift
  for kv in "$@"; do
    tags="${tags:+$tags,}{Key=${kv%%=*},Value=${kv#*=}}"
  done
  echo "ResourceType=$type,Tags=[$tags]"
}

# render_tcp_perm <port> <cidr> -> one --ip-permissions item for tcp <port> from/to <cidr>
render_tcp_perm() { echo "IpProtocol=tcp,FromPort=$1,ToPort=$1,IpRanges=[{CidrIp=$2}]"; }

# render_root_device <GB> -> --block-device-mappings JSON: an encrypted gp3
# root at the Ubuntu AMI's root device, deleted with the instance (set
# explicitly, so destroy never leaves a billing volume behind). JSON, as the
# spike validated it.
render_root_device() {
  printf '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":%d,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]\n' "$1"
}

# --- SSH fragment (U2) -------------------------------------------------------
# render_ssh_config <instance-id> <public-ip> <key-path> <known-hosts-path>
# -> the file every connecting command passes as `ssh -F`, rendered fresh from
# just the instance and its current IP (the IP changes on every start). With
# -F, ssh reads neither ~/.ssh/config nor /etc/ssh/ssh_config. Two aliases,
# named for `helios-lab ssh [guest|host]`:
# - host: StrictHostKeyChecking yes and only the ed25519 key type, because
#   that key was pinned only after it matched the console (remote.sh).
# - guest: `HostName helios`, which libnss-libvirt resolves on the host,
#   through `ProxyJump host`; ssh hands -F to the jump, so this one file
#   governs both hops. accept-new is safe because it rides the verified hop,
#   and every guest create makes new keys (U3 forgets <id>-guest then).
# HostKeyAlias is the instance ID, so a recreated host never meets a stale
# key, and destroy needs no known_hosts cleanup. UseKeychain exists only in
# Apple's ssh; IgnoreUnknown keeps another ssh on PATH from refusing the file.
# Fails on an ID, IP or path it can't render safely.
# Known limit: ssh builds the ProxyJump hop as a shell command with the -F
# path unquoted, so the guest alias needs a state-dir path without spaces or
# shell metacharacters (jump_safe_path; up and `ssh guest` check it first).
# The host alias has no such limit.
render_ssh_config() {
  local key kh
  [[ $1 =~ ^i-[0-9a-f]+$ ]] && is_ipv4 "$2" || return 1
  key=$(ssh_config_path "$3") || return 1
  kh=$(ssh_config_path "$4") || return 1
  printf '%s\n' "# helios-lab ssh config for $1 (lib/render.sh), rendered on every" \
    '# connecting command and used only as ssh -F. Edits are overwritten.' 'IgnoreUnknown UseKeychain' \
    '' 'Host host' "  HostName $2" "  HostKeyAlias $1" '  StrictHostKeyChecking yes' '  HostKeyAlgorithms ssh-ed25519'
  ssh_common "$key" "$kh"
  printf '%s\n' '' 'Host guest' '  HostName helios' '  ProxyJump host' "  HostKeyAlias $1-guest" \
    '  StrictHostKeyChecking accept-new'
  ssh_common "$key" "$kh"
}

# ssh_common <key-arg> <known-hosts-arg> -> the settings both aliases share.
# ServerAliveInterval notices a dead link from this side; the host's sshd
# drop-in (U4) does the same from the other.
ssh_common() {
  printf '  %s\n' 'User ubuntu' "IdentityFile $1" 'IdentitiesOnly yes' 'AddKeysToAgent yes' 'UseKeychain yes' \
    "UserKnownHostsFile $2" 'ForwardAgent no' 'ServerAliveInterval 60' 'ConnectTimeout 15'
}

# jump_safe_path <path> -> 0 when ssh's ProxyJump can carry it as -F: an
# absolute path of letters, digits and / . _ - only, which no shell splits
jump_safe_path() { [[ $1 =~ ^/[A-Za-z0-9/._-]+$ ]]; }

# ssh_config_path <absolute path> -> the path as one ssh_config argument:
# double-quoted (a HOME with spaces), with % doubled, because IdentityFile and
# UserKnownHostsFile expand %-tokens. Fails on a relative path, or one holding
# a double quote or a control character, which no quoting can carry.
ssh_config_path() {
  [[ $1 == /* && $1 != *'"'* && $1 != *[[:cntrl:]]* ]] || return 1
  printf '"%s"\n' "${1//%/%%}"
}

# --- Host config (U2) --------------------------------------------------------
# render_host_config <idle-minutes> <engvm-pin> -> /etc/helios-lab/host.conf.
# Pushed on every up, so a changed setting reaches an existing host (R13).
# It carries the idle window (U4) and the helios-engvm commit (U3), and
# nothing else: KEY=value lines that the host helper parses, never sources.
# Fails on a value the host would refuse.
readonly ENGVM_PIN_RE='^[0-9a-f]{40}$'
render_host_config() {
  idle_minutes_ok "$1" && [[ $2 =~ $ENGVM_PIN_RE ]] || return 1
  printf '%s\n' '# helios-lab host config, rendered by lib/render.sh on the Mac and pushed' \
    '# on every up. The next push overwrites any edit.' "IDLE_MINUTES=$1" "ENGVM_PIN=$2"
}

# --- Push bundle (U2) --------------------------------------------------------
# render_push_bundle <name> <content> [<name> <content>]... -> a bash script
# that writes each file into the current directory, and does nothing else.
# remote.sh runs it on the host in a fresh directory, which it then hands to
# the helper the bundle carries (helios-lab-host install). Each content
# travels in a quoted here-document, so nothing in it expands. A file ends in
# exactly one newline, as every file under host/ does. Fails on a name that
# is not a plain file name, or a content holding the delimiter line.
readonly BUNDLE_EOF=HELIOS_LAB_PUSH_EOF
render_push_bundle() {
  printf '%s\n' '# helios-lab push bundle (lib/render.sh): writes the host files into the current directory.' \
    'set -eu' 'umask 022'
  while (( $# >= 2 )); do
    bundle_file "$1" "$2" || return 1
    shift 2
  done
  (( $# == 0 ))
}

# bundle_file <name> <content> -> one here-document that writes <name>
bundle_file() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  case $'\n'$2$'\n' in *$'\n'"$BUNDLE_EOF"$'\n'*) return 1 ;; esac
  printf "cat > '%s' <<'%s'\n%s\n%s\n" "$1" "$BUNDLE_EOF" "$2" "$BUNDLE_EOF"
}
