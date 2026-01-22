---
name: worktree
description: Create git worktrees for parallel feature development. Use when working on multiple features simultaneously.
argument-hint: [branch-name]
---

# Worktree Management Skill

## Instructions

When the user invokes this skill:

1. **Fetch latest changes**
   ```bash
   git fetch origin
   ```

2. **Ensure .gitignore is configured**
   - Check if `.worktrees/` is in `.gitignore`
   - If not, append `.worktrees/` to `.gitignore`

3. **Determine branch type** - Check if the branch already exists:
   ```bash
   git branch -a | grep -E "(^|\s)feat/<name>$|origin/feat/<name>"
   ```

4. **Create the worktree**

   **If branch does NOT exist** → create new branch from latest develop:
   ```bash
   git worktree add .worktrees/<name> -b feat/<name> origin/develop
   ```

   **If branch EXISTS** → use existing branch:
   ```bash
   git worktree add .worktrees/<name> feat/<name>
   ```

5. **Report the result**
   - Show `git worktree list`
   - Provide the worktree path: `.worktrees/<name>`

## Examples

```
User: /worktree auth-refactor
→ Branch feat/auth-refactor doesn't exist
→ Creates .worktrees/auth-refactor on NEW branch feat/auth-refactor (from origin/develop)

User: /worktree metaknow_url_header
→ Branch feat/metaknow_url_header already exists
→ Creates .worktrees/metaknow_url_header using EXISTING branch
```

## Cleanup

```bash
git worktree remove .worktrees/<name>
git worktree list
```
