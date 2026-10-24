# shellcheck shell=bash
#
# helios-lab render.sh — pure renderers: the instance user-data, and the
# structured AWS CLI arguments the launch and the security group need (U6).
# U2 adds the SSH fragment and the host config here.
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
