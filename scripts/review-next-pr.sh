#!/usr/bin/env bash
# Reviews the oldest waiting pull request into dev of one project in a new session, and merges it if the
# review approves. This script does the merge, so a review cannot reach the release branch or merge other
# work. It runs the review from dev and not from the pull request, so a pull request cannot change its
# own reviewer. With no waiting pull request, it stops before any call to Claude.
# Usage: MINION_REPO=owner/name scripts/review-next-pr.sh
{ # Bash reads this block in full before it runs it, so a change to this file during a run cannot break the run.
set -euo pipefail

source "$(dirname "$0")/lib.sh"
take_slot
if ! load_project "${MINION_REPO:?Set MINION_REPO to owner/name.}"; then
  echo "$MINION_REPO takes no part."
  exit 0
fi

# The worker script adds needs-review to each new pull request, so needs-owner must also stop the review.
lock_choice
number=$(gh pr list --repo "$REPO" --state open --base dev --label needs-review --author "$OWNER" \
  --search "-label:needs-owner" --json number,isCrossRepository \
  --jq '[.[] | select(.isCrossRepository | not)] | sort_by(.number) | .[].number' |
  while read -r candidate; do is_claimed "pr $candidate" || { echo "$candidate"; break; }; done || true)
if [[ -z "$number" ]]; then
  echo "$REPO: no pull request waits for a review."
  exit 0
fi
claim "pr $number"

head=$(gh pr view "$number" --repo "$REPO" --json headRefOid --jq .headRefOid)

hand_to_owner() { # message
  set_pr_label "$number" needs-owner needs-review
  gh pr comment "$number" --repo "$REPO" --body "Automatic review stopped: $1" >/dev/null
  echo "$REPO: pull request $number: for the owner. $1"
  exit 0
}

send_back() { # message
  set_pr_label "$number" changes-requested needs-review
  gh pr comment "$number" --repo "$REPO" --body "$1" >/dev/null
  echo "$REPO: pull request $number: sent back."
  exit 0
}

checks=$(gh pr checks "$number" --repo "$REPO" --required --json bucket --jq '[.[].bucket] | unique | join(" ")' || true)
if [[ -z "$checks" || "$checks" == *pending* ]]; then
  echo "$REPO: pull request $number: CI is still running."
  exit 0
fi
if [[ "$checks" != "pass" ]]; then
  send_back "CI failed. Fix the failure, and the review follows."
fi

if [[ "$(gh pr view "$number" --repo "$REPO" --json mergeable --jq .mergeable)" == "CONFLICTING" ]]; then
  send_back "This pull request has a merge conflict with dev. Merge dev into the branch."
fi

# The comment "Keep going" from the owner starts a new count of rounds.
rounds=$(OWNER=$OWNER gh pr view "$number" --repo "$REPO" --json reviews,comments --jq '
  ([.comments[] | select(.author.login == env.OWNER)
    | select(.body | ascii_downcase | test("^\\s*keep going\\W*$")) | .createdAt] | max // "") as $since
  | [.reviews[] | select(.body | startswith("Automatic review")) | select(.submittedAt > $since)]
  | length')
if ((rounds >= MAX_REVIEW_ROUNDS)); then
  hand_to_owner "$MAX_REVIEW_ROUNDS review rounds did not end in an approval. For $MAX_REVIEW_ROUNDS more rounds, comment \`Keep going\` and add the label \`needs-review\`."
fi

guards=(-e "$ENGINE_OWNER_ONLY")
if [[ -n "$OWNER_ONLY_PATHS" ]]; then guards+=(-e "$OWNER_ONLY_PATHS"); fi
changed=$(gh pr diff "$number" --repo "$REPO" --name-only | grep -E "${guards[@]}" || true)
if [[ -n "$changed" ]]; then
  hand_to_owner "the owner reviews changes to these files: $(tr '\n' ' ' <<<"$changed")"
fi

worktree=$project/review-$number
git_locked -C "$root" fetch -q origin dev "pull/$number/head"
prepare_worktree "$worktree" origin/dev
trap 'remove_worktree "$worktree"; release' EXIT

# The project checks what the review agent cannot, such as secrets or personal data in the history.
if ! run_hook pre-review "$worktree" >/dev/null 2>&1; then
  hand_to_owner "the pre-review hook of the project found something. Run it locally."
fi

set_agent_args review
verdict=$(
  cd "$worktree"
  claude -p "/minion:review-pr $number $head" "${agent_args[@]}" \
    --effort "$REVIEWER_EFFORT" \
    --max-budget-usd "$REVIEWER_BUDGET_USD" \
    --permission-mode default \
    --allowedTools "Read" "Glob" "Grep" "Agent" "Skill" \
    "Bash(git show:*)" "Bash(git diff:*)" "Bash(git log:*)" \
    "Bash(gh issue view:*)" "Bash(gh pr view:*)" "Bash(gh pr diff:*)" \
    "Bash(gh pr review $number --comment:*)" \
    "${REVIEWER_TOOLS[@]}" \
    | tail -n 1
) || verdict=""

# Only an exact approval of the commit that the review read can merge.
case "$verdict" in
  "VERDICT: APPROVE $head")
    current=$(gh pr view "$number" --repo "$REPO" --json headRefOid,baseRefName --jq '.baseRefName + " " + .headRefOid')
    if [[ "$current" != "dev $head" ]]; then
      echo "$REPO: pull request $number changed during the review. It stays in the queue."
      exit 0
    fi
    gh pr merge "$number" --repo "$REPO" --merge --match-head-commit "$head"
    gh pr edit "$number" --repo "$REPO" --remove-label needs-review >/dev/null
    echo "$REPO: pull request $number: merged into dev."
    if load_project "$REPO"; then deploy_dev; fi
    ;;
  "VERDICT: CHANGES")
    set_pr_label "$number" changes-requested needs-review
    echo "$REPO: pull request $number: changes requested."
    ;;
  "VERDICT: OWNER")
    set_pr_label "$number" needs-owner needs-review
    echo "$REPO: pull request $number: for the owner."
    ;;
  *)
    hand_to_owner "the review ended without a clear verdict."
    ;;
esac
exit
}
