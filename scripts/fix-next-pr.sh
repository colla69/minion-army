#!/usr/bin/env bash
# Gives the oldest pull request of one project with requested changes back to Claude, to make the
# corrections. With no such pull request, it stops before any call to Claude.
# Usage: MINION_REPO=owner/name scripts/fix-next-pr.sh
{ # Bash reads this block in full before it runs it, so a change to this file during a run cannot break the run.
set -euo pipefail

source "$(dirname "$0")/lib.sh"
take_slot
if ! load_project "${MINION_REPO:?Set MINION_REPO to owner/name.}"; then
  echo "$MINION_REPO takes no part."
  exit 0
fi

lock_choice
number=$(gh pr list --repo "$REPO" --state open --base dev --label changes-requested --author "$OWNER" \
  --search "-label:needs-owner" --json number,isCrossRepository \
  --jq '[.[] | select(.isCrossRepository | not)] | sort_by(.number) | .[].number' |
  while read -r candidate; do is_claimed "pr $candidate" || { echo "$candidate"; break; }; done || true)
if [[ -z "$number" ]]; then
  echo "$REPO: no pull request waits for corrections."
  exit 0
fi
claim "pr $number"

branch=$(gh pr view "$number" --repo "$REPO" --json headRefName --jq .headRefName)
head=$(gh pr view "$number" --repo "$REPO" --json headRefOid --jq .headRefOid)
body=$(gh pr view "$number" --repo "$REPO" --json body --jq .body)
worktree=$project/fix-$number
git_locked -C "$root" fetch -q origin "$branch"
prepare_worktree "$worktree" "origin/$branch"
git_locked -C "$worktree" switch -q -C "$branch" "origin/$branch"

# The fixer gets the same project commands as the worker, and the rules for fixes from dev.
set_agent_args fix
status=0
(
  cd "$worktree"
  claude -p "/minion:fix-pr $number" "${agent_args[@]}" \
    --effort "$WORKER_EFFORT" \
    --max-budget-usd "$WORKER_BUDGET_USD" \
    --permission-mode acceptEdits \
    --allowedTools "Read" "Edit" "Write" "Glob" "Grep" "Skill" \
    "Bash(git status:*)" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" \
    "Bash(git add:*)" "Bash(git rm:*)" "Bash(git mv:*)" "Bash(git commit:*)" \
    "Bash(git fetch origin dev)" "Bash(git merge origin/dev:*)" \
    "Bash(git push:*)" \
    "Bash(gh pr view:*)" "Bash(gh pr edit:*)" "Bash(gh pr diff:*)" "Bash(gh pr checks:*)" "Bash(gh issue view:*)" \
    "${WORKER_TOOLS[@]}" \
    --disallowedTools "Bash(*--no-verify*)" "Bash(git push*--force*)" "Bash(git push*-f*)" "Bash(git push*+*)"
) || status=$?

now=$(gh pr view "$number" --repo "$REPO" --json headRefOid --jq .headRefOid)
now_body=$(gh pr view "$number" --repo "$REPO" --json body --jq .body)
# A new commit or a new pull request body counts as a correction.
if [[ "$now" != "$head" || "$now_body" != "$body" ]]; then
  set_pr_label "$number" needs-review changes-requested
  remove_worktree "$worktree"
  echo "$REPO: pull request $number: corrected, and back in the review queue."
else
  set_pr_label "$number" needs-owner changes-requested
  gh pr comment "$number" --repo "$REPO" \
    --body "The worker stopped without a correction (exit code $status)." >/dev/null
  echo "$REPO: pull request $number: no correction. The worktree stays at $worktree." >&2
  exit 1
fi
exit
}
