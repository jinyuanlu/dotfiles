# Known residuals: feat/helios-lab

Accepted at ce-work's residual-work gate on 2026-10-25, from the code review
`ce-code-review` run `20261025-helioslab` (mode autofix, base `45198d4`). The
user chose to fix the behaviour findings now (commits `a403350`, `1f908e7`) and
to record the rest here for a follow-up.

| # | Sev | File | Finding | Class | Suggested fix |
|---|---|---|---|---|---|
| 2 | P1 | `.local/share/helios-lab/host/helios-lab-host` | The host helper is about 1,350 lines: the dispatcher, six provisioning stages, and the idle and keep logic in one pushed file | manual | Move the stages and their `check_*` companions, and then the idle block, into sibling files pushed in the same bundle (a new `install_dest` case for each). Keep the dispatcher, progress protocol, status and install in the main file. Update the header layout and the tests' sourcing at the same time |
| 4 | P1 | `.local/share/helios-lab/lib/remote.sh` | `remote.sh` is about 1,150 lines covering U2, U3 and U4 | manual | Extract guest bring-up and the smoke check into `lib/guest.sh`, and add it to the entry's sourcing loop and to `tests/lib.sh` |
| AN2 | — | `.local/bin/helios-lab` (`cmd_status`) | `status` is prose only and exits 0 even for the duplicate-instance conflict; an agent has to parse human text | advisory | Add a machine mode (`status --porcelain`: one `key=value` per fact) and give the duplicate case exit 4 under that flag |

## Residual risks noted by reviewers (not findings)

- **Truncated push.** A push cut off mid-bundle by Ctrl-C or a dropped link could be installed as far as it arrived. A completion sentinel or a sha256 manifest that `install` checks would close this.
- **status keeps the host busy.** The 3-second probe is an established `:22` session, so a tight `status` loop (for example `watch`) can hold off the idle stop.
- **IAM side resources.** `RunInstances` is granted on subnet, security-group, network-interface and image resources with no tag or VPC condition. Narrow these if the account isn't dedicated to the lab.
- **Root refusal is create-only.** Preflight refuses root credentials only on the create path; start, stop and destroy with a profile later re-pointed at root are not refused.
- **First boot counts as idle.** During the guest wait, idle checks still count toward a stop, because the wait holds no session. With the default 60-minute window this doesn't matter in practice.
