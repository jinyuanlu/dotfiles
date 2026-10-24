# helios-lab test fixtures

Real AWS CLI responses captured during the U7 spike (2026-10-24, aws-cli 2.38.5,
one m8i.xlarge in ap-northeast-1). The stub `aws` in `../stubs/` replays them,
so tests run against the real response shape, not a guess.

**Sanitized for a public repo.** Every account ID, resource ID, IP address, MAC,
internal hostname and IAM user name is replaced with a fixed synthetic value:

| Real value | Becomes |
|---|---|
| account ID | `123456789012` |
| any `i-`/`sg-`/`vol-`/`subnet-`/`vpc-`/`eni-`/`ami-`/`r-` ID | `<prefix>-0123456789abcdef0` |
| public IPv4 | `203.0.113.10` (documentation range) |
| VPC-private IPv4 | `172.31.0.10` |
| IAM user | `helios-lab` |

New captures must go through `../sanitize-capture`, then a grep for the real
values you know (account, instance and network IDs, your IP), before they are
committed. It matches resource IDs generically, because a fixed prefix list
once let a `dopt-` and a `vpc-cidr-assoc-` ID through. Never hand-edit a real ID
into a fixture.

| Fixture | What it shows |
|---|---|
| `run-instances.dry-run-ok.{stderr,exit}` | A dry-run that would succeed exits **254** with `DryRunOperation` |
| `describe-security-group-rules.after-create.json` | A new group already allows all egress (`-1`, `0.0.0.0/0`) |
| `describe-security-group-rules.converged.json` | Converged rules: tcp 80/443 out, tcp 22 in from one /32 |
| `describe-instances.stopped-idle.json` | Instance-initiated stop: `Client.InstanceInitiatedShutdown`, reason has **no timestamp** |
| `describe-instances.stopped-user.json` | Manual stop: `Client.UserInitiatedShutdown`, reason carries the time |
| `get-console-output.latest.first-boot.txt` | `--latest` on first boot: cloud-init's block and the per-boot block |
| `get-console-output.latest.later-boot.txt` | Later boot: per-boot block only, with systemd lines interleaved |
| `get-console-output.buffered.first-boot.txt` | Without `--latest`: empty |
| `ssh-keyscan.ed25519.txt` | `ssh-keyscan -t ed25519` of the same host: its key's fingerprint is the `(ED25519)` line in all three console blocks, so a test's "offered key matches the console" is a real match |
| `user-data.spike.yaml` | The user-data the spike booted, its throwaway key replaced by an all-zero placeholder; `lib/render.sh` must render exactly this design |
| the rest | Plain responses for describe, create, start, stop, terminate and delete calls |

## Derived replies (`derived/`)

The code always asks for `--output text` and shapes it with `--query`, and the
stub replays bytes without evaluating the query. So a stub reply is usually not
a capture above but **what the CLI prints for one query over one capture**:
`derived/<capture>.<query>.txt`.

These are not hand-written. `../derive-text '<query>' <capture>.json` produces
them offline with the CLI's own JMESPath library and text formatter (it never
runs `aws`). Re-derive whenever a query in `lib/aws.sh` changes; the lifecycle
tests pin each query string, so a changed query fails until you do. Tests make
variants (another state, another reason) by editing columns of these rows.

| Derived reply | Query (`lib/aws.sh`) |
|---|---|
| `describe-instances.{running,stopped-idle,stopped-user}.discover.txt` | `Q_DISCOVER` |
| `describe-security-group-rules.converged.ingress.txt` | `Q_INGRESS` |
| `describe-instances.running.key-tag.txt` | `Q_KEY_TAG` (`None`: the spike's instance had no `KeyFingerprint` tag) |
| `describe-instances.running.root-volumes.txt` | `Q_ROOT_VOLUMES` |
| `sts-get-caller-identity.caller.txt` | `Q_CALLER` |
| `describe-vpcs.default.vpc.txt` | `Q_VPC` |
| `describe-instance-type-offerings.azs.txt` | `Q_OFFERED_AZS` |
| `describe-subnets.default.subnets.txt` | `Q_SUBNETS` |
| `create-security-group.group-id.txt` | `Q_GROUP_ID` |
| `describe-security-group-rules.{after-create,converged}.rules.txt` | `Q_RULES` |
| `{revoke-security-group-egress,authorize-security-group-egress,authorize-security-group-ingress,delete-security-group}.return.txt` | `Q_RETURN` |
| `run-instances.launched.txt` | `Q_LAUNCHED` |
| `{start,stop,terminate}-instances.state.txt` | `Q_STARTING`, `Q_STOPPING`, `Q_TERMINATING` |

The console captures need no derivation: the spike ran `get-console-output
--query Output --output text` itself (`Q_CONSOLE`), so they already are the
reply bytes, trimmed to the fingerprint blocks (the full boot log is ~64 KB).
The later-boot one keeps its CRLF line ends and the systemd lines inside the
block; the parser must cope with both. The keyscan capture went through
`../sanitize-capture` like the rest (its address is the synthetic one, the
public host key of the terminated spike host is kept).

Text-output rules worth knowing when reading them: a null prints `None`, an
empty string prints an empty field, a boolean prints `True`/`False`, each
inner list prints as one tab-separated line, and an empty list prints nothing
(so "no instances" is an empty reply). The sanitizer gave every captured rule
the same `sgr-` ID, so tests that need distinct rules renumber them.

### Hand-written replies

Some calls have no capture, because the spike had no way to provoke them or
they print only IDs. The tests build these inline and mark each one:

- one-ID-per-line lists: `describe-security-groups` (`Q_GROUP_IDS`) and
  `describe-volumes` (`Q_VOLUME_IDS`)
- `revoke-security-group-ingress`, which replays the egress capture (same response shape)
- `aws --version`, in the format of the CLI's `clidriver._cli_version`
- errors, in the CLI v2 shape of `run-instances.dry-run-ok.stderr` (a blank
  line, then `aws: [ERROR]: An error occurred (Code) when calling the Op
  operation: message`): `InsufficientInstanceCapacity` on RunInstances and
  StartInstances, `UnauthorizedOperation` on the dry-run, `DependencyViolation`
  and `InvalidGroup.NotFound` on DeleteSecurityGroup, and a waiter timeout
- the host's side of ssh (U2): `helios-lab-host progress` replies
  (`../lib.sh` `progress_reply`), written in the progress protocol that
  `lib/remote.sh` and `host/helios-lab-host` document. The protocol is ours,
  so there is nothing to capture; instead `remote.test.sh` runs the helper's
  own provisioning (stages faked) and checks its output is exactly this shape.
  Journal lines, and ssh's own error messages, are hand-written too.
- the guest (U3): `helios-lab-host status` replies (`../lib.sh`
  `guest_status_reply`), checked against the helper's own `status` the same
  way in `guest.test.sh`; and what the guest itself prints, which the spike
  observed but did not capture: `uname -o`'s `illumos`, dtrace's stdout for
  a `BEGIN` probe that exits, the end of the first-boot console transcript
  (`INFO ok, run complete`, `Hostname: helios`), and `virsh domstate` lines.
  The guest's DHCP address is in libvirt's default `192.168.122.0/24`.
- the idle stop (U4): the idle lines of a `helios-lab-host status` reply
  (`../lib.sh` `idle_status_reply`), checked against the helper's own
  `idle_facts` the same way in `idle.test.sh`; `helios-lab-host keep`'s
  answer (a deadline epoch, or `off`); and, for the idle check run on the
  Mac against faked tools, the lines `ss -Htn state established` prints for
  sessions on :22, `systemctl show`'s `KEY=value` lines and `/proc/uptime`.
  Their epochs are relative to the test's clock or the fixed `NOW`.
