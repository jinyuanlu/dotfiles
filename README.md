# Dotfiles

## Claude Code Setup

### First-time setup

```bash
~/.claude/skills/setup        # builds browse CLI, creates ~/.gstack dirs
```

Requires [bun](https://bun.sh). The browse CLI compiles Playwright into a standalone binary at `~/.claude/skills/browse/dist/browse`.

### Dev clone (git hooks)

After cloning this repo for development, enable the version-controlled hooks once:

```bash
bin/setup-git-hooks        # sets core.hooksPath = .githooks
```

This installs a `post-checkout` hook that auto-links the git-crypt key into new worktrees, so `git worktree add` yields a clean, decrypted tree with no manual symlinking. (git-crypt 0.8.0 only finds its key in the common git-dir, not in worktree git-dirs.)

### cmux (custom binary starter)

cmux exec's the agent binary directly, so the `claude` alias in `.aliases.sh` never fires and MCP servers go missing. Point cmux at the wrapper instead:

```
Settings > Automation > Claude Code > Claude Binary Path
  -> ~/.claude/bin/claude-cmux
```

Equivalent via env: `export CMUX_CUSTOM_CLAUDE_PATH="$HOME/.claude/bin/claude-cmux"`.

`.claude/bin/claude-cmux` re-applies `--dangerously-skip-permissions --mcp-config ~/.claude/mcp.json` (matching the alias) and `exec`s the real binary. It walks `$PATH` by hand to skip cmux's own per-surface shim (`/tmp/cmux-cli-shims/…`) — a plain lookup finds the shim and loops. If `mcp.json` is still git-crypt locked it warns and starts without MCP rather than dying on a parse error.

| Env var | Effect |
|---|---|
| `CLAUDE_REAL_BIN` | Skip `$PATH` discovery, use this binary |
| `CLAUDE_MCP_CONFIG` | Use a different MCP config than `~/.claude/mcp.json` |

Subcommands (`claude mcp`, `claude update`, …) pass through unmodified — a global flag placed before a subcommand swallows it.

### How it works

```
                        YOU
                         │
              ┌──────────┴──────────┐
              │   Slash Commands    │   /commit /review /pr /explain ...
              │   (quick actions)   │   type in Claude Code prompt
              └──────────┬──────────┘
                         │
         ┌───────────────┼───────────────┐
         ▼               ▼               ▼
   ┌──────────┐   ┌──────────────┐   ┌──────────┐
   │  Skills  │   │    Agents    │   │  Rules   │
   │ (heavy   │   │ (sub-agents  │   │ (always  │
   │  flows)  │   │  for review) │   │  loaded) │
   └──────────┘   └──────────────┘   └──────────┘
```

**Rules** (`.claude/rules/`) — always-on directives: coding style, architecture principles, agent orchestration. Loaded every conversation.

**Commands** (`.claude/commands/`) — slash commands you type directly: `/commit`, `/review`, `/pr`, `/explain`, `/think`, `/five`, `/challenge`.

**Skills** (`.claude/skills/`) — rich, multi-step workflows invoked as slash commands. Each has a `SKILL.md` with frontmatter, preamble, and detailed instructions.

**Agents** (`.claude/agents/`) — specialized sub-agents spawned by the main agent for focused tasks: architecture review, security analysis, code review, etc.

### Workflow: idea to ship

```
/office-hours          brainstorm, validate idea, produce design doc
      │
      ▼
/plan-ceo-review       scope expansion / reduction, 10x thinking
/plan-eng-review       architecture, tests, edge cases, failure modes
/plan-design-review    UI/UX completeness, interaction states, AI slop
      │
      ▼
  implement            write code (agents auto-fire: code-reviewer, tdd-guide)
      │                (use /careful or /freeze to scope edits while debugging)
      ▼
/investigate           debug with root cause discipline (scope-locked edits)
      │
      ▼
/review                pre-landing diff review (SQL safety, race conditions, ...)
/design-review         live site visual QA with headless browser
      │
      ▼
/qa                    browser-based QA → fix → re-verify loop
/qa-only               browser-based QA → report only (no fixes)
      │
      ▼
/ship                  merge base, tests, review, version bump, PR
/document-release      post-ship docs sync (README, CHANGELOG, ARCHITECTURE)
/retro                 weekly engineering retrospective with trend tracking
```

### Skills reference

| Skill | Invoke | What it does |
|-------|--------|-------------|
| browse | `/browse` | Headless Chromium CLI (~100ms/cmd). Navigate, click, screenshot, diff pages |
| careful | `/careful` | Destructive command guardrails (rm -rf, DROP TABLE, force-push, etc.) |
| design-consultation | `/design-consultation` | Create DESIGN.md (typography, color, spacing, motion) |
| design-review | `/design-review` | Visual audit of live site → fix → re-verify |
| document-release | `/document-release` | Post-ship docs sync (README, CHANGELOG, ARCHITECTURE) |
| eval-harness | `/eval-harness` | Eval-driven development framework |
| freeze | `/freeze` | Restrict file edits to a specific directory for the session |
| guard | `/guard` | Full safety mode: /careful + /freeze combined |
| investigate | `/investigate` | Root cause debugging with scope-locked edits |
| jobs-review | `/jobs-review` | Steve Jobs product review (scores 0-10, coherence audit) |
| market-research | `/market-research` | Competitive analysis and market sizing |
| office-hours | `/office-hours` | YC-style product brainstorming → design doc |
| plan-ceo-review | `/plan-ceo-review` | CEO/founder plan review (4 modes: expand/selective/hold/reduce) |
| plan-design-review | `/plan-design-review` | Designer's eye plan review (7 passes, 0-10 ratings) |
| plan-eng-review | `/plan-eng-review` | Engineering plan review (architecture → tests → perf) |
| qa | `/qa` | Browser QA → fix bugs → commit each fix atomically |
| qa-only | `/qa-only` | Browser QA → report only, no fixes |
| retro | `/retro` | Weekly engineering retrospective with trend tracking |
| review | `/review` | Pre-landing diff review (SQL safety, race conditions, etc.) |
| setup-browser-cookies | `/setup-browser-cookies` | Import cookies from real browser into headless session |
| ship | `/ship` | Merge base, tests, review, version bump, PR, push |
| unfreeze | `/unfreeze` | Clear freeze boundary, allow edits everywhere again |
| worktree | `/worktree` | Git worktrees for parallel feature development |

### Agents reference

| Agent | Spawned by | Purpose |
|-------|-----------|---------|
| planner | Complex feature requests | Implementation planning |
| architect | Architectural decisions | System design analysis |
| code-reviewer | After writing code | Quality, security, maintainability |
| security-reviewer | Sensitive code changes | OWASP top 10, secrets, injection |
| tdd-guide | New features, bug fixes | Test-driven development |
| e2e-runner | Critical user flows | Playwright E2E tests |
| challenge | After planner/architect | Devil's advocate critique |
| jobs-review | After UI/UX decisions | Steve Jobs product critique |
| refactor-cleaner | Code maintenance | Dead code removal |
| doc-updater | After changes | Documentation sync |

### Commands reference

| Command | What it does |
|---------|-------------|
| `/commit` | Conventional commit with auto-generated message |
| `/review` | Quick diff review (lighter than the skill) |
| `/pr` | Create PR with structured description |
| `/explain` | Deep explanation of code or concepts |
| `/think` | Multi-angle structured reasoning |
| `/five` | Five whys root cause analysis |
| `/challenge` | Devil's advocate on current plan |

### Shared utilities

Scripts in `.claude/skills/bin/` used by skills internally:

| Script | Purpose |
|--------|---------|
| `slug` | Detect `SLUG` (owner-repo) and `BRANCH` from git remote |
| `config` | Read/write `~/.gstack/config.yaml` |
| `review-log` | Append review result to per-project JSONL |
| `review-read` | Read review dashboard data |
| `diff-scope` | Categorize diff as frontend/backend/tests/docs/config |
| `sync-gstack` | Pull latest gstack skills from GitHub into dotfiles |
| `telemetry-log` | No-op stub (skill activations logged via skill-usage.jsonl) |
| `update-check` | No-op stub (replaces gstack update check) |

### State directories

```
~/.gstack/
├── config.yaml              # global config (proactive, skip_eng_review, ...)
├── projects/{slug}/         # per-repo review logs, design docs, test plans
├── analytics/               # skill usage JSONL
└── sessions/                # active session tracking
```

---

## Karabiner Keyboard Shortcuts Cheatsheet

### Emacs-style Navigation
| Shortcut | Action | Notes |
|----------|--------|-------|
| `C-n` | Down arrow | Disabled in Terminal/Emacs |
| `C-p` | Up arrow | Disabled in Terminal/Emacs |
| `C-f` | Right arrow | Disabled in Terminal/Emacs |
| `C-b` | Left arrow | Disabled in Terminal/Emacs |
| `C-a` | Home (line start) | Disabled in Terminal/Emacs |
| `C-e` | End (line end) | Disabled in Terminal/Emacs |

### Emacs-style Scrolling
| Shortcut | Action | Notes |
|----------|--------|-------|
| `C-v` | Page Down | Disabled in Emacs |
| `M-v` | Page Up | Disabled in Emacs |
| `C-Shift-n` | Smooth scroll down | Mouse wheel simulation |
| `C-Shift-p` | Smooth scroll up | Mouse wheel simulation |

### Emacs-style Word Navigation
| Shortcut | Action | Notes |
|----------|--------|-------|
| `M-f` | Word forward | Option + right arrow |
| `M-b` | Word backward | Option + left arrow |

### Emacs-style Editing
| Shortcut | Action | Notes |
|----------|--------|-------|
| `C-d` | Delete forward | Disabled in Terminal/Emacs |
| `C-h` | Backspace | Disabled in Terminal/Emacs |
| `C-k` | Kill line | Delete to end of line |

### Tab + Mouse Control
| Shortcut | Action | Notes |
|----------|--------|-------|
| `Tab` (alone) | Tab | Normal tab key |
| `Tab+W` | Mouse up | Fast movement (2300px) |
| `Tab+A` | Mouse left | Fast movement (2300px) |
| `Tab+S` | Mouse down | Fast movement (2300px) |
| `Tab+D` | Mouse right | Fast movement (2300px) |
| `Tab+Shift+W` | Mouse up | Slow movement (256px) |
| `Tab+Shift+A` | Mouse left | Slow movement (256px) |
| `Tab+Shift+S` | Mouse down | Slow movement (256px) |
| `Tab+Shift+D` | Mouse right | Slow movement (256px) |
| `Tab+Space` | Left click | Mouse button 1 |
| `Tab+Return` | Left click | Mouse button 1 |
| `Tab+Shift+Space` | Middle click | Mouse button 2 |
| `Tab+Ctrl+Space` | Right click | Mouse button 3 |

### Tab Sublayer: Open Apps (Tab+O)
| Shortcut | Action | Application |
|----------|--------|-------------|
| `Tab+O, T` | Open Terminal | Terminal.app |
| `Tab+O, E` | Open Emacs | Emacs.app |
| `Tab+O, C` | Open Chrome | Google Chrome.app |
| `Tab+O, F` | Open Finder | Finder.app |
| `Tab+O, S` | Open Slack | Slack.app |
| `Tab+O, V` | Open VS Code | Visual Studio Code.app |

### Tab Sublayer: Window Management (Tab+R)
| Shortcut | Action | Notes |
|----------|--------|-------|
| `Tab+R, H` | Window left half | Rectangle integration |
| `Tab+R, L` | Window right half | Rectangle integration |
| `Tab+R, J` | Window bottom half | Rectangle integration |
| `Tab+R, K` | Window top half | Rectangle integration |
| `Tab+R, F` | Maximize window | Rectangle integration |
| `Tab+R, C` | Center window | Rectangle integration |
| `Tab+R, N` | Next display | Move to next monitor |
| `Tab+R, P` | Previous display | Move to previous monitor |

### Tab Sublayer: System Control (Tab+C)
| Shortcut | Action | Notes |
|----------|--------|-------|
| `Tab+C, U` | Volume up | System volume |
| `Tab+C, D` | Volume down | System volume |
| `Tab+C, M` | Mute | Toggle mute |
| `Tab+C, I` | Brightness up | Display brightness |
| `Tab+C, K` | Brightness down | Display brightness |
| `Tab+C, P` | Play/Pause | Media control |
| `Tab+C, N` | Next track | Media control |
| `Tab+C, B` | Previous track | Media control |
| `Tab+C, L` | Lock screen | Ctrl+Cmd+Q |

### Function Keys
| Key | Action |
|-----|--------|
| `F1` | Brightness down |
| `F2` | Brightness up |
| `F3` | Mission Control |
| `F4` | Spotlight |
| `F5` | Dictation |
| `F6` | F6 (passthrough) |
| `F7` | Rewind |
| `F8` | Play/Pause |
| `F9` | Fast Forward |
| `F10` | Mute |
| `F11` | Volume down |
| `F12` | Volume up |

## Usage Notes

- **Tab as modifier**: Hold Tab to activate mouse control or sublayers
- **Sublayers**: After pressing Tab+O/R/C, release Tab but keep holding the sublayer key, then press the action key
- **App exclusions**: Emacs-style bindings are disabled in Terminal and Emacs to avoid conflicts
- **Rectangle required**: Window management shortcuts require Rectangle app to be installed