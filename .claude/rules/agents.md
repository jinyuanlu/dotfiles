# Agent Orchestration

## Available Agents

Located in `~/.claude/agents/`:

| Agent | Purpose | When to Use |
|-------|---------|-------------|
| planner | Implementation planning | Complex features, refactoring |
| architect | System design | Architectural decisions |
| tdd-guide | Test-driven development | New features, bug fixes |
| code-reviewer | Code review | After writing code |
| security-reviewer | Security analysis | Before commits |
| e2e-runner | E2E testing | Critical user flows |
| refactor-cleaner | Dead code cleanup | Code maintenance |
| doc-updater | Documentation | Updating docs |
| challenge | Technical devil's advocate | After planning, before committing to approach |
| jobs-review | Product/UX critique | After UI/UX/product decisions |

## Immediate Agent Usage

No user prompt needed:
1. Complex feature requests - Use **planner** agent
2. Code just written/modified - Use **code-reviewer** agent
3. Bug fix or new feature - Use **tdd-guide** agent
4. Architectural decision - Use **architect** agent
5. Plan or design proposed - Use **challenge** agent
6. UI/UX or product decision - Use **jobs-review** agent

## Agent Chaining

After an agent completes, route its output to reviewers. Which reviewers depends on what the work touches.

### Reviewer classification

- **challenge** — always applies. Technical correctness, simplicity, compositional integrity.
- **jobs-review** — applies when the work has **user-facing surface**: UI components, CLI output, API responses consumed by humans, error messages, onboarding flows, information architecture changes.

### Routing rules

Determine which reviewers apply, then run them in parallel:

```
  planner ──┬──→ challenge        (always)
            └──→ jobs-review      (if plan touches UI/UX)

  architect ─┬──→ challenge       (always)
             └──→ jobs-review     (if architecture affects user experience)

  code-reviewer ──→ challenge     (non-trivial findings only)
```

When both reviewers apply, launch them **in parallel** — they evaluate orthogonal concerns and do not depend on each other.

### How to decide if jobs-review applies

Ask one question: **will a person using the product see or feel this change?** If yes, route to `jobs-review`. Examples:

- New API endpoint returning JSON → no (machine consumer)
- New API endpoint powering a UI → yes (user sees the result)
- Database migration → no
- New settings page → yes
- Error handling refactor → yes (user sees error messages)
- Performance optimization → maybe (user feels faster load times)

## Parallel Task Execution

ALWAYS use parallel Task execution for independent operations:

```markdown
# GOOD: Parallel execution
Launch 3 agents in parallel:
1. Agent 1: Security analysis of auth.ts
2. Agent 2: Performance review of cache system
3. Agent 3: Type checking of utils.ts

# BAD: Sequential when unnecessary
First agent 1, then agent 2, then agent 3
```

## Multi-Perspective Analysis

For complex problems, use split role sub-agents:
- Factual reviewer
- Senior engineer
- Security expert
- Consistency reviewer
- Redundancy checker
