# Disk Hygiene

This Mac's disk has filled up repeatedly (Oct–Nov 2026), every time because of what agents left behind.
Each rule below comes from an actual incident. They apply to every session and every subagent.

## Before heavy work
- Run `df -g /System/Volumes/Data` before any full build, test suite, model check or data load.
  Under 15G free → don't start; tell the user.

## Rust
- Never set `CARGO_TARGET_DIR` and never pass `--target-dir`. `~/.cargo/config.toml` points every
  project and worktree at `~/.cargo/shared-target`; a per-worktree `target/` costs 5G+ each.
- While iterating, build only what you need: `cargo check`, `-p <crate>`, `--test <name>`.
  Run `--workspace --all-targets` only once, as the final check.

## Containers
- Throwaway containers always get `--rm`. Never leave stopped containers or anonymous volumes behind
  (`docker rm -v`).
- A database for tests keeps its data in memory (`--tmpfs /var/lib/postgresql/data`, or the
  testcontainers tmpfs mount), with one container per test run and a fresh database per test,
  never a fresh container per test. Docker here never gives freed space back, so every byte a
  container writes stays in `Docker.raw` for good.
- Don't run `docker image/volume prune` on volumes you didn't create; `agent-fleet` holds user data.

## Worktrees
- Don't create a worktree for read-only work.
- When an agent's worktree is merged or abandoned and has no uncommitted changes, remove it before
  finishing (`git worktree remove <path>`). Keep the branch.

## Scratchpad and local services
- A service log in the scratchpad must never grow past 500MB. Send logs to `/dev/null` unless you
  need them; if you do, check the file's size during the task and empty it with `: > file` when it gets large.
- Stop any local service you started (soma, temporal, metaknow, sims) when the task ends, and delete
  its database and log files. Don't leave it running "for later".
- TLC: always `-metadir <scratchpad>/tlc-<spec>`, and delete that directory once the run finishes.

## Never
- Delete caches, logs or data that another live process or session is using (`lsof` first).
- Work around a full disk by moving files into other folders on the same disk.
