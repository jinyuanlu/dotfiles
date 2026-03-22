---
name: release-announce
version: 1.0.0
description: |
  Generate platform-specific release announcements from git diffs and changelogs.
  Supports Show HN, LinkedIn, X/Twitter, and internal launch posts. Reads the
  diff, understands what shipped, and produces tailored copy for each platform.
  Use when asked to "write release notes", "announce this", "Show HN post",
  "LinkedIn post", "tweet this launch", or "internal launch email".
  Proactively suggest after /ship or /document-release completes.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - AskUserQuestion
---
<!-- AUTO-GENERATED from SKILL.md.tmpl — do not edit directly -->
<!-- Regenerate: bun run gen:skill-docs -->

## Preamble (run first)

```bash
_UPD=$(~/.claude/skills/bin/update-check 2>/dev/null || .claude/skills/bin/update-check 2>/dev/null || true)
[ -n "$_UPD" ] && echo "$_UPD" || true
mkdir -p ~/.gstack/sessions
touch ~/.gstack/sessions/"$PPID"
_SESSIONS=$(find ~/.gstack/sessions -mmin -120 -type f 2>/dev/null | wc -l | tr -d ' ')
find ~/.gstack/sessions -mmin +120 -type f -delete 2>/dev/null || true
_CONTRIB=$(~/.claude/skills/bin/config get gstack_contributor 2>/dev/null || true)
_PROACTIVE=$(~/.claude/skills/bin/config get proactive 2>/dev/null || echo "true")
_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
echo "BRANCH: $_BRANCH"
echo "PROACTIVE: $_PROACTIVE"
_LAKE_SEEN=$([ -f ~/.gstack/.completeness-intro-seen ] && echo "yes" || echo "no")
echo "LAKE_INTRO: $_LAKE_SEEN"
_TEL=$(~/.claude/skills/bin/config get telemetry 2>/dev/null || true)
_TEL_PROMPTED=$([ -f ~/.gstack/.telemetry-prompted ] && echo "yes" || echo "no")
_TEL_START=$(date +%s)
_SESSION_ID="$$-$(date +%s)"
echo "TELEMETRY: ${_TEL:-off}"
echo "TEL_PROMPTED: $_TEL_PROMPTED"
echo "TEL_START: $_TEL_START"
echo "SESSION_ID: $_SESSION_ID"
mkdir -p ~/.gstack/analytics
echo "$_TEL_START" > ~/.gstack/analytics/.pending-"$_SESSION_ID"
echo '{"skill":"release-announce","ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","repo":"'$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "unknown")'"}'  >> ~/.gstack/analytics/skill-usage.jsonl 2>/dev/null || true
for _PF in ~/.gstack/analytics/.pending-*; do [ -f "$_PF" ] && ~/.claude/skills/bin/telemetry-log --event-type skill_run --skill _pending_finalize --outcome unknown --session-id "$_SESSION_ID" 2>/dev/null || true; break; done
```

If `PROACTIVE` is `"false"`, do not proactively suggest gstack skills — only invoke
them when the user explicitly asks. The user opted out of proactive suggestions.

If output shows `UPGRADE_AVAILABLE <old> <new>`: read `~/.claude/skills/gstack-upgrade/SKILL.md` and follow the "Inline upgrade flow" (auto-upgrade if configured, otherwise AskUserQuestion with 4 options, write snooze state if declined). If `JUST_UPGRADED <from> <to>`: tell user "Running gstack v{to} (just updated!)" and continue.

If `LAKE_INTRO` is `no`: Before continuing, introduce the Completeness Principle.
Tell the user: "gstack follows the **Boil the Lake** principle — always do the complete
thing when AI makes the marginal cost near-zero. Read more: https://garryslist.org/posts/boil-the-ocean"
Then offer to open the essay in their default browser:

```bash
open https://garryslist.org/posts/boil-the-ocean
touch ~/.gstack/.completeness-intro-seen
```

Only run `open` if the user says yes. Always run `touch` to mark as seen. This only happens once.

If `TEL_PROMPTED` is `no` AND `LAKE_INTRO` is `yes`: After the lake intro is handled,
ask the user about telemetry. Use AskUserQuestion:

> Help gstack get better! Community mode shares usage data (which skills you use, how long
> they take, crash info) with a stable device ID so we can track trends and fix bugs faster.
> No code, file paths, or repo names are ever sent.
> Change anytime with `gstack-config set telemetry off`.

Options:
- A) Help gstack get better! (recommended)
- B) No thanks

If A: run `~/.claude/skills/bin/config set telemetry community`

If B: ask a follow-up AskUserQuestion:

> How about anonymous mode? We just learn that *someone* used gstack — no unique ID,
> no way to connect sessions. Just a counter that helps us know if anyone's out there.

Options:
- A) Sure, anonymous is fine
- B) No thanks, fully off

If B→A: run `~/.claude/skills/bin/config set telemetry anonymous`
If B→B: run `~/.claude/skills/bin/config set telemetry off`

Always run:
```bash
touch ~/.gstack/.telemetry-prompted
```

This only happens once. If `TEL_PROMPTED` is `yes`, skip this entirely.

## AskUserQuestion Format

**ALWAYS follow this structure for every AskUserQuestion call:**
1. **Re-ground:** State the project, the current branch (use the `_BRANCH` value printed by the preamble — NOT any branch from conversation history or gitStatus), and the current plan/task. (1-2 sentences)
2. **Simplify:** Explain the problem in plain English a smart 16-year-old could follow. No raw function names, no internal jargon, no implementation details. Use concrete examples and analogies. Say what it DOES, not what it's called.
3. **Recommend:** `RECOMMENDATION: Choose [X] because [one-line reason]` — always prefer the complete option over shortcuts (see Completeness Principle). Include `Completeness: X/10` for each option. Calibration: 10 = complete implementation (all edge cases, full coverage), 7 = covers happy path but skips some edges, 3 = shortcut that defers significant work. If both options are 8+, pick the higher; if one is ≤5, flag it.
4. **Options:** Lettered options: `A) ... B) ... C) ...` — when an option involves effort, show both scales: `(human: ~X / CC: ~Y)`

Assume the user hasn't looked at this window in 20 minutes and doesn't have the code open. If you'd need to read the source to understand your own explanation, it's too complex.

Per-skill instructions may add additional formatting rules on top of this baseline.

## Completeness Principle — Boil the Lake

AI-assisted coding makes the marginal cost of completeness near-zero. When you present options:

- If Option A is the complete implementation (full parity, all edge cases, 100% coverage) and Option B is a shortcut that saves modest effort — **always recommend A**. The delta between 80 lines and 150 lines is meaningless with CC+gstack. "Good enough" is the wrong instinct when "complete" costs minutes more.
- **Lake vs. ocean:** A "lake" is boilable — 100% test coverage for a module, full feature implementation, handling all edge cases, complete error paths. An "ocean" is not — rewriting an entire system from scratch, adding features to dependencies you don't control, multi-quarter platform migrations. Recommend boiling lakes. Flag oceans as out of scope.
- **When estimating effort**, always show both scales: human team time and CC+gstack time. The compression ratio varies by task type — use this reference:

| Task type | Human team | CC+gstack | Compression |
|-----------|-----------|-----------|-------------|
| Boilerplate / scaffolding | 2 days | 15 min | ~100x |
| Test writing | 1 day | 15 min | ~50x |
| Feature implementation | 1 week | 30 min | ~30x |
| Bug fix + regression test | 4 hours | 15 min | ~20x |
| Architecture / design | 2 days | 4 hours | ~5x |
| Research / exploration | 1 day | 3 hours | ~3x |

- This principle applies to test coverage, error handling, documentation, edge cases, and feature completeness. Don't skip the last 10% to "save time" — with AI, that 10% costs seconds.

**Anti-patterns — DON'T do this:**
- BAD: "Choose B — it covers 90% of the value with less code." (If A is only 70 lines more, choose A.)
- BAD: "We can skip edge case handling to save time." (Edge case handling costs minutes with CC.)
- BAD: "Let's defer test coverage to a follow-up PR." (Tests are the cheapest lake to boil.)
- BAD: Quoting only human-team effort: "This would take 2 weeks." (Say: "2 weeks human / ~1 hour CC.")

## Contributor Mode

If `_CONTRIB` is `true`: you are in **contributor mode**. You're a gstack user who also helps make it better.

**At the end of each major workflow step** (not after every single command), reflect on the gstack tooling you used. Rate your experience 0 to 10. If it wasn't a 10, think about why. If there is an obvious, actionable bug OR an insightful, interesting thing that could have been done better by gstack code or skill markdown — file a field report. Maybe our contributor will help make us better!

**Calibration — this is the bar:** For example, `$B js "await fetch(...)"` used to fail with `SyntaxError: await is only valid in async functions` because gstack didn't wrap expressions in async context. Small, but the input was reasonable and gstack should have handled it — that's the kind of thing worth filing. Things less consequential than this, ignore.

**NOT worth filing:** user's app bugs, network errors to user's URL, auth failures on user's site, user's own JS logic bugs.

**To file:** write `~/.gstack/contributor-logs/{slug}.md` with **all sections below** (do not truncate — include every section through the Date/Version footer):

```
# {Title}

Hey gstack team — ran into this while using /release-announce:

**What I was trying to do:** {what the user/agent was attempting}
**What happened instead:** {what actually happened}
**My rating:** {0-10} — {one sentence on why it wasn't a 10}

## Steps to reproduce
1. {step}

## Raw output
```
{paste the actual error or unexpected output here}
```

## What would make this a 10
{one sentence: what gstack should have done differently}

**Date:** {YYYY-MM-DD} | **Version:** {gstack version} | **Skill:** /release-announce
```

Slug: lowercase, hyphens, max 60 chars. Skip if file already exists. Max 3 reports per session. File inline and continue — don't stop the workflow. Tell user: "Filed gstack field report: {title}"

## Completion Status Protocol

When completing a skill workflow, report status using one of:
- **DONE** — All steps completed successfully. Evidence provided for each claim.
- **DONE_WITH_CONCERNS** — Completed, but with issues the user should know about. List each concern.
- **BLOCKED** — Cannot proceed. State what is blocking and what was tried.
- **NEEDS_CONTEXT** — Missing information required to continue. State exactly what you need.

### Escalation

It is always OK to stop and say "this is too hard for me" or "I'm not confident in this result."

Bad work is worse than no work. You will not be penalized for escalating.
- If you have attempted a task 3 times without success, STOP and escalate.
- If you are uncertain about a security-sensitive change, STOP and escalate.
- If the scope of work exceeds what you can verify, STOP and escalate.

Escalation format:
```
STATUS: BLOCKED | NEEDS_CONTEXT
REASON: [1-2 sentences]
ATTEMPTED: [what you tried]
RECOMMENDATION: [what the user should do next]
```

## Telemetry (run last)

After the skill workflow completes (success, error, or abort), log the telemetry event.
Determine the skill name from the `name:` field in this file's YAML frontmatter.
Determine the outcome from the workflow result (success if completed normally, error
if it failed, abort if the user interrupted).

**PLAN MODE EXCEPTION — ALWAYS RUN:** This command writes telemetry to
`~/.gstack/analytics/` (user config directory, not project files). The skill
preamble already writes to the same directory — this is the same pattern.
Skipping this command loses session duration and outcome data.

Run this bash, substituting the `TEL_START` and `SESSION_ID` values printed by the preamble:

```bash
_TEL_START="{TEL_START value from preamble}"
_SESSION_ID="{SESSION_ID value from preamble}"
_TEL_END=$(date +%s)
_TEL_DUR=$(( _TEL_END - _TEL_START ))
rm -f ~/.gstack/analytics/.pending-"$_SESSION_ID" 2>/dev/null || true
~/.claude/skills/bin/telemetry-log \
  --skill "release-announce" --duration "$_TEL_DUR" --outcome "OUTCOME" \
  --used-browse "false" --session-id "$_SESSION_ID" 2>/dev/null &
```

Replace `OUTCOME` with success/error/abort. Substitute the actual `TEL_START` and
`SESSION_ID` values that were printed by the preamble bash block — these are agent-level
values, not shell variables (they don't persist across bash invocations).
If you cannot determine the outcome, use "unknown". This runs in the background and
never blocks the user.

---

# Release Announce: Platform-Specific Launch Copy

Generate platform-specific release announcements. Not marketing fluff — authentic,
technically honest copy that respects each platform's culture.

---

## Step 0: Detect base branch

Determine which branch this PR targets. Use the result as "the base branch" in all subsequent steps.

1. Check if a PR already exists for this branch:
   `gh pr view --json baseRefName -q .baseRefName`
   If this succeeds, use the printed branch name as the base branch.

2. If no PR exists (command fails), detect the repo's default branch:
   `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`

3. If both commands fail (e.g., `gh` not installed, not a GitHub repo), fall back to `main`.
   **Print a warning**: "Could not detect base branch via GitHub CLI — falling back to `main`. If your default branch is different, tell me."

Print the detected base branch name. In every subsequent `git diff`, `git log`,
and comparison command, substitute the detected branch name wherever the instructions
say "the base branch."

## Step 1: Gather Context

Before writing anything, collect the raw material.

Run in a single bash block, substituting the detected base branch:
```bash
_BASE="{detected base branch}"
echo "BASE: $_BASE"
git log --oneline --no-merges "$_BASE"..HEAD
echo "---"
git diff "$_BASE"...HEAD --stat
```

**Empty diff guard**: If `git log` returns no commits between base and HEAD, **abort**:
"No commits found between `{base}` and HEAD. Nothing to announce. Are you on the right branch?"

Then read (if they exist):
- `CHANGELOG.md`
- `VERSION`
- `README.md` first 100 lines (for project description)
- Any `release-notes*.md` files

If context is insufficient, use AskUserQuestion:
- What is the one-sentence summary of what shipped?
- Who is the target audience?
- What's the most impressive or novel part?
- Any live demo URL?

## Step 2: Extract the Core

From the gathered context, distill:

1. **What** — the concrete thing that shipped (feature, tool, fix, project)
2. **Why** — the problem it solves or the insight behind it
3. **How** — the interesting technical approach (if any)
4. **Impact** — what changes for the user/reader
5. **Demo** — URL, screenshot, or way to try it

## Step 3: Ask Which Platforms

Use AskUserQuestion with the standard format:

> **Re-ground:** On branch `{_BRANCH}`, generating release announcements for what just shipped.
>
> **Simplify:** I'll write the same launch announcement tailored for each platform's audience and culture — like translating the same news into different languages.
>
> RECOMMENDATION: Choose A (all platforms) because the marginal cost of each additional platform is near-zero. Completeness: 10/10 for A, 6/10 for single platform.

Options:
- A) All platforms (Show HN + LinkedIn + X + Internal + Changelog) (human: ~3 hours / CC: ~2 min)
- B) Pick specific platforms — I'll list them
- C) Just one: [show-hn | linkedin | x | internal | changelog]

## Platform Specifications

---

### Show HN

**Culture**: Technical depth over polish. Novelty over incremental. Honesty over hype.
HN readers are exhausted engineers who've seen everything — earn their attention with
substance, not superlatives.

**Title format**: `Show HN: [Name] – [specific description of what it does]`

**Title rules**:
- Under 80 characters, 6-10 words optimal
- No marketing language, no superlatives, no buzzwords
- Specific numbers over vague claims ("2min deploys" not "blazing fast deploys")
- State what it IS, not why it's great
- Ask: "Would an exhausted engineer at 11pm click this?"

**Body structure**:
1. One-paragraph summary: what it is, what problem it solves
2. What's technically interesting or novel about the approach
3. Honest limitations and trade-offs (HN rewards this heavily)
4. Link to live demo (required if possible) or repo
5. "Happy to answer questions" closing

**Anti-patterns** (will get you flagged/killed):
- Asking for upvotes (bannable)
- Marketing language ("revolutionary", "game-changing", "10x")
- Hiding that it's your project
- No demo or way to try it
- Defensive responses to criticism

**Self-check — Ethics gate**:
- [ ] No exaggerated claims
- [ ] Prior art acknowledged
- [ ] Provides standalone value (not just a signup funnel)
- [ ] Would you post this if you had no financial stake?

**Directional posting guidance** (approximate, based on historical HN analysis):
- Personal blogs tend to outperform corporate blogs for Show HN
- Live demos significantly increase engagement over text-only posts
- Weekend posts tend to have higher breakout rates (less competition)
- Early upvote momentum matters — the first hour is critical
- Best posting windows: 6-9 AM or 10 AM-12 PM PT

---

### LinkedIn

**Culture**: Professional but human. Personal narratives outperform corporate announcements.
Engineering managers, CTOs, and VPs are the primary audience.

**Structure**:
1. **Hook** (first 2-3 lines — this is all people see before "see more")
   - Personal statement, surprising result, or direct question
   - NO "I'm excited to announce..." (LinkedIn slop detector)
2. **Context paragraph** — the problem or situation
3. **3-5 bullet points** — key insights, results, or lessons
4. **Personal takeaway** — what you learned, what surprised you
5. **Call-to-action** — question to drive comments, or link
6. **3-5 hashtags** at the end

**Formatting rules**:
- Line break after every 1-2 sentences (mobile readability)
- Liberal white space — no walls of text
- 1,200-1,500 characters optimal
- Emojis: sparingly if at all (1-2 max, no emoji bullets)

**Content mix principle**: 40% personal insight, 30% technical, 20% team story, 10% promo.
This post is the 10% — so lead with insight, not announcement.

**Distribution tip**: Personal profiles get 10-20% organic reach vs 2-5% for company pages.

**Anti-patterns**:
- "I'm thrilled/excited/humbled to announce..."
- Tagging 20 people for engagement farming
- Corporate press release tone
- Hashtag spam (>5)

---

### X / Twitter

**Culture**: Authentic, concise, visual. Developers on X reward contrarian takes,
building-in-public narratives, and technical threads with real code/screenshots.

**Single tweet** (for minor releases):
- Hook-first: lead with the most interesting thing
- Under 280 characters
- No hashtags in the tweet body (algorithm deprioritizes)
- Include image/screenshot/video if possible (2x engagement)
- No external links in first tweet (algorithm penalty) — put link in reply

**Thread** (for major releases, 5-12 tweets):
1. **Hook tweet** — compelling opener, no links, no hashtags
2. **Context** — the problem or "why I built this"
3-8. **Core content** — one insight per tweet, code screenshots, demos
9. **Summary** with key takeaway
10. **CTA** — link, repo, or question

**Hook templates that work**:
- Contrarian: "Unpopular opinion: [X] is the wrong approach to [Y]. Here's why →"
- Result: "I cut [metric] by [amount] with [approach]. Here's the full breakdown →"
- Narrative: "6 months ago I started building [X]. Today it [milestone]. Thread 🧵"
- Listicle: "[N] things I learned building [X] →"

**Visual code**: Use screenshots (Carbon, Ray.so) over text blocks.

**Timing**: 6-8 AM, 10 AM-12 PM, or 4-6 PM PT. First 2 hours of engagement are critical.

**Algorithm factors** (ranked by impact): early replies > time-on-post > profile visits > bookmarks > retweets > likes > link clicks. External links are deprioritized.

**Anti-patterns**:
- Humble-brags
- "Like and RT if you agree"
- Engagement pod behavior
- Links in hook tweet
- Hashtag stuffing

---

### Internal Launch (Slack/Email)

**Culture**: Respect people's time. Be clear about what changed, why it matters to them,
and what action (if any) they need to take.

**Structure**:
1. **Subject/title**: `[Launch] Feature Name — one-line impact statement`
2. **TL;DR** (2-3 sentences max): what shipped, who it's for, one key metric
3. **What changed** — bullet list of concrete changes
4. **Why** — the problem this solves or opportunity it captures
5. **How to try it** — direct link, steps, or "it's already live"
6. **Known limitations** — what's NOT included yet (prevents support tickets)
7. **Questions?** — who to contact, relevant channel

**Tone**: Direct, helpful, slightly casual. Not a press release. Not a bragging post.
Write as if explaining to a smart colleague who has 30 seconds.

**Anti-patterns**:
- Burying the action item
- "As you may know..." preamble
- Overly long context that nobody will read
- Missing the "how to try it" section

---

### Changelog Entry (draft only)

**WARNING**: This is a **draft for review only**. `/document-release` is the canonical
owner of CHANGELOG.md content and voice. `/ship` generates the initial entries.
**NEVER write this output directly to CHANGELOG.md.** Present it as a suggestion
the user can reference when running `/document-release`.

**Culture**: Scannable, factual, user-centric.

**Format**:
```
## [version] - YYYY-MM-DD

### Added
- Feature description from user's perspective

### Changed
- What behavior is different now

### Fixed
- Bug description and resolution

### Breaking
- What will break and migration path
```

**Rules**:
- User-facing language (not implementation details)
- Link to docs/PR for each item
- Group by impact, not by file changed
- Filter out internal-only changes (refactors, test updates)

---

## Step 4: Generate & Self-Review

For each selected platform, generate the copy then run this checklist:

**Universal quality gate**:
- [ ] No superlatives unless backed by data
- [ ] No "we're excited" / "thrilled" / "humbled"
- [ ] Claims match what actually shipped (re-read the diff)
- [ ] Honest about limitations
- [ ] Passes the "would I respect this from someone else?" test
- [ ] Platform-specific length limits respected
- [ ] Has a clear CTA or next step

**Platform-specific gates**:
- Show HN: ethics checkpoint passed, demo link included
- LinkedIn: hook in first 2 lines, under 1,500 chars
- X: no links in hook tweet, visual included or suggested
- Internal: TL;DR present, action items clear
- Changelog: user-facing language, no jargon, marked as DRAFT

## Step 5: Output

Present each platform's copy in a clearly separated block:

```
━━━ SHOW HN ━━━
[title]
[body]

━━━ LINKEDIN ━━━
[post]

━━━ X/TWITTER ━━━
[tweet or thread]

━━━ INTERNAL ━━━
[announcement]

━━━ CHANGELOG (draft — use /document-release for canonical entry) ━━━
[entry]
```

After output, use AskUserQuestion:

> **Re-ground:** Generated release announcements for {N} platforms based on the diff on branch `{_BRANCH}`.
>
> RECOMMENDATION: Review and iterate — the first draft is a starting point.

Options:
- A) Ship it — all look good
- B) Adjust tone/length/emphasis for specific platforms
- C) Regenerate with different angle or focus
- D) Save drafts to file (writes to `release-announce-drafts.md`)

If D: write all drafts to `release-announce-drafts.md` in the project root.

**STATUS: DONE**
