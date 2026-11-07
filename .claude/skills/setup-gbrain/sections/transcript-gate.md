<!-- AUTO-GENERATED from transcript-gate.md.tmpl — do not edit directly -->
<!-- Regenerate: bun run gen:skill-docs -->
After memory sync is wired (Step 7) but before persisting the CLAUDE.md
config (Step 8), ask whether this machine's coding-agent session
transcripts may go into gbrain. Curated `~/.gstack/` artifacts (learnings,
timeline, plans, designs, retros) sync whatever the answer; this question
covers transcripts only. Transcripts are ingested only after the user picks
`recent`, `all` or `new` (only sessions that start from now on).

Check whether the user already chose. The gate keys on `has`, because `get`
prints the `off` default for a key that was never set:
```bash
_TIM=$(~/.claude/skills/bin/config get transcript_ingest_mode 2>/dev/null || true)
if ~/.claude/skills/bin/config has transcript_ingest_mode; then
  _T='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]t[0-9][0-9]:[0-9][0-9]:[0-9][0-9]z'
  case "$(printf '%s' "$_TIM" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')" in
    recent|all|off|recent+repos|all+repos|new@$_T|new@$_T+repos)
      echo "TRANSCRIPT_MODE: $_TIM (repos: $(~/.claude/skills/bin/config get transcript_repos 2>/dev/null || true))" ;;
    *) echo "TRANSCRIPT_MODE: ask (stored value '$_TIM' is not recognized by this version)" ;;
  esac
else
  echo "TRANSCRIPT_MODE: ask (not set)"
fi
```

- `TRANSCRIPT_MODE:` with a value (`recent`, `all`, `off`, `new@<time>`,
  any of them with `+repos`): the user already chose. Do not ask again;
  continue to Step 8.
- `TRANSCRIPT_MODE: ask`: ask once, below. With `SESSION_KIND: spawned` or
  `headless`, do not ask and do not store a value. Consent is never
  auto-chosen; leave the key unset (transcripts stay skipped) and report
  that the next interactive `/sync-gbrain` will ask.

Size the question with two probes. `--sources transcript` makes the probe
count transcripts even though none are consented yet:
```bash
bun --no-env-file --config=/dev/null run ~/.claude/skills/bin/memory-ingest.ts --probe --sources transcript
bun --no-env-file --config=/dev/null run ~/.claude/skills/bin/memory-ingest.ts --probe --sources transcript --all-history
```
Read `Total files in window`, `Total bytes` and the estimate from each.

**No transcripts found** (both probes report 0): ask yes/no instead:

> "Ingest coding-agent sessions as they appear?"

Yes means `recent` (then ask the scope question below); No stores `off`.

**Otherwise**, AskUserQuestion with the counts. Name both session sources
and the destination brain from Step 4: the user's Supabase brain (Paths 1,
2a, 2b) or the local PGLite brain on this machine (Path 3).

> "Found <N_recent> Claude Code and Codex sessions from the last 90 days
> (<N_all> in all history, <bytes>) across the projects on this machine
> that your repo policy allows. Ingest them into your <Supabase | local
> PGLite> brain?
>
> What you get: gstack skills load recent context from your past sessions,
> so the agent finds your prior work without you describing it, and you
> can ask 'what was I doing on day X'. Per-session pages are searchable,
> taggable and deletable. Secret scanning runs before any push.
>
> What stays the same: nothing leaves this machine unless brain sync is
> enabled (Step 7). Per-repo trust policies still apply. The first full
> sync can take a while on a large history (estimate: <est>); skills stay
> usable while it runs.
>
> Multi-machine note: with brain sync enabled, transcript pages sync across
> your machines. Deleting a page later removes it from gbrain, but git
> history keeps it in earlier commits. Use `gstack-transcript-prune` to
> delete in bulk, and `git filter-repo` on the brain remote to remove it
> from history."

Options:
- A) Yes, last 90 days (`recent`)
- B) Yes, all history (`all`)
- C) Yes, only new sessions starting now (`new`)
- E) No, never ingest transcripts (`off`)

On any yes, ask a second, separate question: "Which repos' sessions?"
A) every project repo your repo policy allows, or B) only this repo (offer
B only when `git remote get-url origin` succeeds here). Store nothing until
both answers are known; if the user cancels in between, store nothing.
Then store the scope, then the mode value (never the letter; `new` stores
`new@` plus the current UTC time):
```bash
~/.claude/skills/bin/config set transcript_repos "$(git remote get-url origin)"  # only this repo
~/.claude/skills/bin/config unset transcript_repos                                 # every repo
~/.claude/skills/bin/config set transcript_ingest_mode <recent|all|off|new@$(date -u +%Y-%m-%dT%H:%M:%SZ)>
bun --no-env-file --config=/dev/null run ~/.claude/skills/lib/transcript-consent.ts --describe
```
Tell the user the `--describe` line: what will be ingested, in words.

For `recent`, `all` or `new@…`, run the first sync now:
```bash
bun --no-env-file --config=/dev/null run ~/.claude/skills/bin/gbrain-sync.ts --full --no-brain-sync
```
(`--no-brain-sync` because Step 7 already wired that path; this runs the
code import and memory ingest stages, and `all` walks the full history.)
For `off`, run nothing here; other memory still syncs on the next
`/sync-gbrain`.

New transcripts are ingested on the next `/sync-gbrain` run. Nothing at
skill start ingests them.

Reference doc for users: `setup-gbrain/memory.md#transcripts`.
