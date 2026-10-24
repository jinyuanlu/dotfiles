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
