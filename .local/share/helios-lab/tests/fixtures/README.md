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

New captures must go through the same sanitizer and a leak check against the
real values before they are committed. Never hand-edit a real ID into a fixture.

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

Text-output rules worth knowing when reading them: a null prints `None`, an
empty string prints an empty field, each inner list prints as one tab-separated
line, and an empty list prints nothing (so "no instances" is an empty reply).
There is no `describe-security-groups` capture; its one-ID-per-line reply for
`Q_GROUP_IDS` is written inline in the tests.
