#!/bin/bash
# validate-worktree-branch.sh
# PreToolUse hook to prevent commits to wrong branch in worktrees
#
# Validates that the current branch matches the expected branch
# based on the worktree directory path before allowing git commits.
#
# Uses git rev-parse --show-toplevel to get the actual git root,
# which works even when cd'd into subdirectories.

set -euo pipefail

# Read JSON input from stdin
INPUT=$(cat)

# Extract command and working directory
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Only intercept git commit commands (with various flags)
if ! echo "$COMMAND" | grep -qE '^\s*git\s+(commit|cherry-pick|revert|merge)'; then
  exit 0
fi

# Ensure CWD is set
if [[ -z "$CWD" ]]; then
  exit 0
fi

# Get git root directory (works even in subdirectories)
GIT_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || {
  # Not a git repo, let it proceed (will fail naturally)
  exit 0
}

# Get current branch name
BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null) || {
  exit 0
}

# Handle detached HEAD state
if [[ "$BRANCH" == "HEAD" ]]; then
  exit 0
fi

# Check if git root is inside a .worktrees/ directory
# Matches: /any/path/.worktrees/worktree-name
if [[ "$GIT_ROOT" =~ /\.worktrees/([^/]+)$ ]]; then
  WORKTREE_NAME="${BASH_REMATCH[1]}"

  # Expected branch pattern: feat/<worktree-name>
  # Adjust this pattern to match your naming convention
  EXPECTED_BRANCH="feat/${WORKTREE_NAME}"

  if [[ "$BRANCH" != "$EXPECTED_BRANCH" ]]; then
    cat >&2 <<EOF

══════════════════════════════════════════════════════════════
  WORKTREE BRANCH MISMATCH - COMMIT BLOCKED
══════════════════════════════════════════════════════════════

  Git root:         ${GIT_ROOT}
  Worktree name:    ${WORKTREE_NAME}

  Expected branch:  ${EXPECTED_BRANCH}
  Actual branch:    ${BRANCH}

──────────────────────────────────────────────────────────────
  The current branch does not match the worktree directory.

  This usually means you're about to commit to the WRONG branch.

  Please verify:
  1. You're in the correct worktree
  2. The branch is correct for this feature

  If this is intentional, ask the user to run git commit manually.
══════════════════════════════════════════════════════════════

EOF
    exit 2  # Block the action and send feedback to Claude
  fi
fi

# All checks passed
exit 0
