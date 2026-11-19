#!/usr/bin/env bash
# Gives the oldest pull request of one project back to Claude when the review requested changes, or
# when a comment of the owner has no answer yet. The second holds also for a pull request that waits
# for the owner, because only the merge waits for the owner. With no such pull request, it stops before
# any call to Claude.
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
number=$(OWNER=$OWNER gh pr list --repo "$REPO" --state open --base dev --author "$OWNER" \
  --json number,isCrossRepository,labels,comments \
  --jq "$OWNER_COMMENT_WAITS"'[.[] | select(.isCrossRepository | not)
    | select(([.labels[].name] | index("changes-requested") and (index("needs-owner") | not))
      or owner_comment_waits)]
    | sort_by(.number) | .[].number' |
  while read -r candidate; do is_claimed "pr $candidate" || { echo "$candidate"; break; }; done || true)
if [[ -z "$number" ]]; then
  echo "$REPO: no pull request waits for corrections or an answer."
  exit 0
fi
claim "pr $number"

count_answers() {
  gh pr view "$number" --repo "$REPO" --json comments --jq '[.comments[] | select(.body | startswith("**Fixer:**"))] | length'
}

branch=$(gh pr view "$number" --repo "$REPO" --json headRefName --jq .headRefName)
head=$(gh pr view "$number" --repo "$REPO" --json headRefOid --jq .headRefOid)
body=$(gh pr view "$number" --repo "$REPO" --json body --jq .body)
labels=" $(gh pr view "$number" --repo "$REPO" --json labels --jq '[.labels[].name] | join(" ")') "
asked=$(OWNER=$OWNER gh pr view "$number" --repo "$REPO" --json comments --jq "$OWNER_COMMENT_WAITS owner_comment_waits")
answers=$(count_answers)
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
    "Bash(gh pr view:*)" "Bash(gh pr edit:*)" "Bash(gh pr comment $number:*)" "Bash(gh pr diff:*)" "Bash(gh pr checks:*)" "Bash(gh issue view:*)" \
    "${WORKER_TOOLS[@]}" \
    --disallowedTools "Bash(*--no-verify*)" "Bash(git push*--force*)" "Bash(git push*-f*)" "Bash(git push*+*)"
) || status=$?

now=$(gh pr view "$number" --repo "$REPO" --json headRefOid --jq .headRefOid)
now_body=$(gh pr view "$number" --repo "$REPO" --json body --jq .body)
answered=false
if (($(count_answers) > answers)); then answered=true; fi
# Removes only the labels that the pull request has.
present() { local label; for label in "$@"; do [[ "$labels" != *" $label "* ]] || echo "$label"; done; }

# A new commit or a new pull request body counts as a correction.
if [[ "$now" != "$head" || "$now_body" != "$body" ]]; then
  if [[ "$asked" == true && "$answered" == false ]]; then
    gh pr comment "$number" --repo "$REPO" --body "**Fixer:** I pushed $now for your comment." >/dev/null
  fi
  mapfile -t old < <(present changes-requested needs-owner)
  set_pr_label "$number" needs-review "${old[@]}"
  remove_worktree "$worktree"
  echo "$REPO: pull request $number: corrected, and back in the review queue."
  notify all "$REPO pull request $number: the fix agent pushed corrections." "$(pr_link "$number")"
elif [[ "$asked" == true && "$answered" == true && "$labels" != *" changes-requested "* ]]; then
  remove_worktree "$worktree"
  echo "$REPO: pull request $number: answered the comment of the owner."
  notify owner "$REPO pull request $number: the fix agent answered your comment." "$(pr_link "$number")"
else
  mapfile -t old < <(present changes-requested)
  set_pr_label "$number" needs-owner "${old[@]}"
  gh pr comment "$number" --repo "$REPO" \
    --body "The worker stopped without a correction or an answer (exit code $status)." >/dev/null
  echo "$REPO: pull request $number: no correction. The worktree stays at $worktree." >&2
  notify owner "$REPO pull request $number needs you: the fix agent stopped without a correction or an answer." "$(pr_link "$number")"
  exit 1
fi
exit
}
