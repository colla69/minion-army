#!/usr/bin/env bash
# Tests the scripts of the working loop. Needs no network and never starts Claude.
# Each case runs a copy of the engine against a made-up project in a local origin, with a fake gh and a
# fake claude first on PATH. The fake gh answers from the rules of the case and logs each call.
# Usage: tests/loop-test.sh
set -uo pipefail

source_root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
REPO=colla69/demo

check() { # description, command...
  local description=$1
  shift
  if "$@"; then
    echo "ok: $description"
  else
    echo "FAILED: $description" >&2
    failures=$((failures + 1))
  fi
}
logged() { grep -qF -- "$1" "$case_dir/gh.log"; }
not_logged() { ! grep -qF -- "$1" "$case_dir/gh.log" 2>/dev/null; }
claude_ran() { grep -qF -- "$1" "$case_dir/claude.log" 2>/dev/null; }
claude_never_ran() { [[ ! -s "$case_dir/claude.log" ]]; }
not_claude_ran() { ! claude_ran "$1"; }

# Creates a copy of the engine, the fakes, and a project whose dev branch holds a .minion folder.
# Without "bare", the project gets a config and a deploy-dev hook. With "bare", it has no .minion folder.
new_case() { # name, [bare]
  case_dir=$work/$1
  engine=$case_dir/engine
  seed=$case_dir/seed
  origin=$case_dir/remote/$REPO.git
  project=$case_dir/cache/minion-army/projects/${REPO/\//__}
  mkdir -p "$case_dir/bin" "$engine" "$seed/.minion/hooks" "$project"
  : >"$case_dir/gh.log"
  cp -r "$source_root/scripts" "$source_root/plugin" "$engine/"

  cat >"$case_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/gh.log"
source "$FAKE/rules.sh"
respond "$@"
EOF
  cat >"$case_dir/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/claude.log"
if [[ -f "$FAKE/claude-action.sh" ]]; then source "$FAKE/claude-action.sh"; fi
EOF
  # Stands in for curl, which sends the Telegram messages. It logs the arguments and the config file.
  cat >"$case_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
{ echo "$*"; while [[ $# -gt 0 ]]; do [[ "$1" == -K ]] && cat "$2"; shift; done; } >>"$FAKE/curl.log"
EOF
  # Stands in for systemd-run: it notes the unit and runs the slot at once, with the given variables.
  cat >"$case_dir/bin/fake-start" <<'EOF'
#!/usr/bin/env bash
variables=()
while [[ "$1" == --* ]]; do
  case "$1" in
    --unit=*) echo "${1#--unit=}" >>"$FAKE/units.log" ;;
    --setenv=*) variables+=("${1#--setenv=}") ;;
  esac
  shift
done
env "${variables[@]}" "$@"
EOF
  chmod +x "$case_dir/bin/"*
  echo 'respond() { :; }' >"$case_dir/rules.sh"
  echo "REPOS=($REPO)" >"$case_dir/machine.conf"

  if [[ "${2:-}" == bare ]]; then
    echo "made-up project" >"$seed/README.md"
    rm -rf "$seed/.minion"
  else
    echo "WORKER_TOOLS=('Bash(make test)')" >"$seed/.minion/config.sh"
    printf '#!/usr/bin/env bash\necho deployed >>"$FAKE/deploy.log"\n' >"$seed/.minion/hooks/deploy-dev"
    chmod +x "$seed/.minion/hooks/deploy-dev"
  fi
  commit_seed "made-up start"
  git init -q --bare "$origin"
  git -C "$seed" remote add origin "$origin"
  git -C "$seed" push -q origin dev
  git -C "$seed" push -q origin dev:refs/pull/116/head
  sha=$(git -C "$seed" rev-parse dev)
  # The dev environment already runs this commit, so only a new commit deploys.
  echo "$sha" >"$project/dev-deployed"
}

# Commits the files of the seed to dev. A case that changes the project calls it again, then push_seed.
commit_seed() { # message
  [[ -d "$seed/.git" ]] || git init -q -b dev "$seed"
  git -C "$seed" add -A
  git -C "$seed" -c user.email=test@example.org -c user.name=Test commit -q --allow-empty -m "$1"
}
push_seed() { git -C "$seed" push -q origin dev; sha=$(git -C "$seed" rev-parse dev); }

run() { # script, arguments...
  local script=$1
  shift
  FAKE=$case_dir PATH="$case_dir/bin:$PATH" XDG_CACHE_HOME=$case_dir/cache \
    AGENT_START=$case_dir/bin/fake-start MINION_CONFIG=$case_dir/machine.conf \
    MINION_REMOTE_BASE=$case_dir/remote MINION_REPO=$REPO \
    "$engine/scripts/$script" "$@" >"$case_dir/out.log" 2>&1
}
units() { sort "$case_dir/units.log" 2>/dev/null | tr '\n' ' '; }
state() { echo "$case_dir/cache/minion-army"; }
# Holds the lock of a slot in the background, as a slot that runs.
hold_slot() { # slot
  mkdir -p "$(state)"
  flock "$(state)/slot-$1.lock" sleep 60 &
  holders+=($!)
  sleep 0.3
}
holders=()
stop_holders() { kill "${holders[@]}" 2>/dev/null; wait 2>/dev/null; holders=(); }

work_rules() { # issue, [pull request branch and url, as tab-separated lines]
  cat >"$case_dir/rules.sh" <<EOF
respond() {
  case "\$*" in
    "issue list"*) echo $1 ;;
    *dependencies/blocked_by*) echo 0 ;;
    "issue view $1"*) echo true ;;
    "pr list"*) printf '${2:-}' ;;
  esac
}
EOF
}

# A loop round with no work at all calls no Claude.
new_case idle
run agent-loop.sh
check "an idle round calls no Claude" claude_never_ran
check "an idle round deploys nothing" test ! -e "$case_dir/deploy.log"
check "an idle round clones the project" test -f "$project/clone/.minion/config.sh"
check "without a slot setting, 2 reviewers and 2 workers start" \
  test "$(units)" = "minion-army-review-1 minion-army-review-2 minion-army-work-1 minion-army-work-2 "

# The machine config sets how many slots start.
new_case settings
printf 'WORKERS=0\nREVIEWERS=1\n' >>"$case_dir/machine.conf"
run agent-loop.sh
check "the machine config sets the number of slots" test "$(units)" = "minion-army-review-1 "

# A project without .minion/config.sh on dev takes no part.
new_case no-config bare
work_rules 104
run agent-loop.sh
check "a project without a config gets no housekeeping" not_logged "pr list"
check "a project without a config gets no worker" claude_never_ran
check "a project without a config gets no deploy" test ! -e "$case_dir/deploy.log"

# With ACCOUNT, the loop finds the projects itself: each source repository with a config on dev.
new_case discovery
echo "ACCOUNT=colla69" >"$case_dir/machine.conf"
cat >"$case_dir/rules.sh" <<'EOF'
respond() {
  case "$*" in
    "repo list colla69"*) printf 'colla69/demo\ncolla69/other\n' ;;
    "api repos/colla69/demo/contents/.minion/config.sh?ref=dev"*) return 0 ;;
    "api repos/colla69/other/contents/.minion/config.sh?ref=dev"*) return 1 ;;
  esac
}
EOF
run agent-loop.sh
check "discovery takes a repository with a config on dev" logged "pr list --repo $REPO"
check "discovery leaves a repository without a config" not_logged "--repo colla69/other"
: >"$case_dir/gh.log"
run agent-loop.sh
check "discovery uses its cache in the next round" not_logged "repo list"
check "the cached project still takes part" logged "pr list --repo $REPO"

# A failed listing keeps the last list, so a GitHub outage does not drop the projects for an hour.
new_case discovery-fails
echo "ACCOUNT=colla69" >"$case_dir/machine.conf"
echo "colla69/demo" >"$(state)/discovered-colla69"
touch -d "2 hours ago" "$(state)/discovered-colla69"
echo 'respond() { case "$*" in "repo list"*) return 1 ;; esac; }' >"$case_dir/rules.sh"
run agent-loop.sh
check "a failed listing keeps the last list" logged "pr list --repo $REPO"

# init-project.sh creates the labels of the loop in a project.
new_case init
run init-project.sh "$REPO"
check "init creates the label agent-ready" logged "label create agent-ready --repo $REPO"
check "init creates the label needs-owner" logged "label create needs-owner --repo $REPO"

# A slot that still runs is not started again.
new_case busy-slot
hold_slot work-1
run agent-loop.sh
stop_holders
check "a slot that runs is not started again" \
  test "$(units)" = "minion-army-review-1 minion-army-review-2 minion-army-work-2 "

# A pull request that another slot reviews is not taken. The next one is.
new_case claimed-pr
cat >"$case_dir/rules.sh" <<'EOF'
respond() {
  case "$*" in
    "pr list"*) printf '116\n117\n' ;;
    "pr checks"*) echo pending ;;
  esac
}
EOF
mkdir -p "$(state)/claims"
echo "$REPO pr 116" >"$(state)/claims/review-9"
hold_slot review-9
run review-next-pr.sh
stop_holders
check "a review takes the pull request that no other slot has" logged "pr view 117"
check "a review leaves the pull request of another slot" not_logged "pr view 116"
check "a review removes its claim at the end" test "$(ls "$(state)/claims")" = review-9

# An issue that another slot works on is not taken.
new_case claimed-issue
cat >"$case_dir/rules.sh" <<'EOF'
respond() {
  case "$*" in
    "issue list"*) printf '119\n120\n' ;;
    *dependencies/blocked_by*) echo 0 ;;
    "issue view 120"*) echo true ;;
    "pr list"*) printf 'issue-120\thttps://example.org/pull/130\n' ;;
  esac
}
EOF
mkdir -p "$(state)/claims"
echo "$REPO issue 119" >"$(state)/claims/work-9"
hold_slot work-9
run work-next-issue.sh
stop_holders
check "a worker takes the issue that no other slot has" claude_ran "/minion:work-issue 120"

# A slot that stopped during its work leaves a claim. The next round removes it and its label.
new_case stale-claim
mkdir -p "$(state)/claims"
echo "$REPO issue 105" >"$(state)/claims/work-9"
echo "$REPO issue 106" >"$(state)/claims/work-8"
hold_slot work-8
run agent-loop.sh
stop_holders
check "the claim of a stopped slot goes" test ! -e "$(state)/claims/work-9"
check "the issue of a stopped slot loses in-progress" logged "issue edit 105 --repo $REPO --remove-label in-progress"
check "the claim of a slot that runs stays" test -e "$(state)/claims/work-8"

# The worker gets the skills of the engine, the tools and the rules of the project, and the hook runs.
new_case project-parts
echo "MADE-UP-RULE: say hello." >"$seed/.minion/work.md"
printf '#!/usr/bin/env bash\npwd >>"$FAKE/setup.log"\n' >"$seed/.minion/hooks/setup-worktree"
chmod +x "$seed/.minion/hooks/setup-worktree"
commit_seed "made-up project parts"
push_seed
echo "$sha" >"$project/dev-deployed"
work_rules 104 'issue-104\thttps://example.org/pull/116\n'
run work-next-issue.sh
check "the worker gets the skills of the engine" claude_ran "--plugin-dir $engine/plugin"
check "the worker gets the tools of the project" claude_ran "Bash(make test)"
check "the worker gets the rules of the project" claude_ran "MADE-UP-RULE: say hello."
check "the hook setup-worktree runs in the worktree" grep -q "/issue-104$" "$case_dir/setup.log"

# Claude Code loads project plugins only in the folder where they were installed, never in a worktree
# of the engine. So the engine hands each plugin that the project enables to the agent itself.
new_case project-plugins
mkdir -p "$seed/.claude" "$case_dir/plugins/standard" "$case_dir/plugins/everywhere"
cat >"$seed/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "standard@made-up": true,
    "everywhere@made-up": true,
    "switched-off@made-up": false,
    "not-installed@made-up": true
  }
}
EOF
cat >"$case_dir/installed.json" <<EOF
{"version": 2, "plugins": {
  "standard@made-up": [{"scope": "project", "projectPath": "/somewhere", "installPath": "$case_dir/plugins/standard", "lastUpdated": "2026-11-01T00:00:00Z"}],
  "everywhere@made-up": [{"scope": "user", "installPath": "$case_dir/plugins/everywhere", "lastUpdated": "2026-11-01T00:00:00Z"}],
  "switched-off@made-up": [{"scope": "project", "projectPath": "/somewhere", "installPath": "$case_dir/plugins/standard", "lastUpdated": "2026-11-01T00:00:00Z"}]
}}
EOF
commit_seed "made-up plugins"
push_seed
echo "$sha" >"$project/dev-deployed"
work_rules 104 'issue-104\thttps://example.org/pull/116\n'
MINION_INSTALLED_PLUGINS=$case_dir/installed.json run work-next-issue.sh
check "the worker gets a plugin that the project enables" claude_ran "--plugin-dir $case_dir/plugins/standard"
check "the worker does not get a plugin at user scope twice" not_claude_ran "$case_dir/plugins/everywhere"
check "a missing plugin does not stop the worker" claude_ran "/minion:work-issue 104"

# The worker names its branch issue-104-annexes. The script still finds the pull request.
new_case branch-suffix
work_rules 104 'issue-10-old\thttps://example.org/pull/10\nissue-104-annexes\thttps://example.org/pull/116\n'
run work-next-issue.sh
status=$?
check "a worker branch issue-N-suffix ends with exit code 0" test "$status" -eq 0
check "a worker branch issue-N-suffix gets needs-review" logged "pr edit https://example.org/pull/116 --repo $REPO --add-label needs-review"
check "a worker branch issue-N-suffix sets no needs-input" not_logged "--add-label needs-input"
check "the issue loses in-progress after the run" logged "issue edit 104 --repo $REPO --remove-label in-progress"

# A pull request of another issue that starts with the same digits is not taken.
new_case other-issue
work_rules 10 'issue-104\thttps://example.org/pull/116\n'
run work-next-issue.sh
check "the pull request of issue 104 does not count for issue 10" not_logged "pull/116 --repo $REPO --add-label needs-review"
check "issue 10 without its own pull request gets needs-input" logged "issue edit 10 --repo $REPO --add-label needs-input"

# A blocked issue waits, and the next unblocked one runs.
new_case blocked
cat >"$case_dir/rules.sh" <<'EOF'
respond() {
  case "$*" in
    "issue list"*) printf '107\n108\n' ;;
    *issues/107/dependencies/blocked_by*) echo 1 ;;
    *issues/108/dependencies/blocked_by*) echo 0 ;;
    "issue view 108"*) echo true ;;
    "pr list"*) printf 'issue-108\thttps://example.org/pull/120\n' ;;
  esac
}
EOF
run work-next-issue.sh
check "a blocked issue is skipped" claude_ran "/minion:work-issue 108"
check "a blocked issue gets no label" not_logged "issue edit 107"

# A failed lookup of the blockers counts as blocked.
new_case blocker-lookup-fails
cat >"$case_dir/rules.sh" <<'EOF'
respond() {
  case "$*" in
    "issue list"*) echo 107 ;;
    *dependencies/blocked_by*) return 1 ;;
  esac
}
EOF
run work-next-issue.sh
check "a failed lookup of the blockers starts no worker" claude_never_ran

# The worker fails without a pull request. No label stays behind except needs-input.
new_case worker-fails
work_rules 105
echo "exit 1" >"$case_dir/claude-action.sh"
run work-next-issue.sh
status=$?
check "a failed worker ends with exit code 1" test "$status" -eq 1
check "a failed worker removes in-progress" logged "issue edit 105 --repo $REPO --remove-label in-progress"
check "a failed worker sets needs-input" logged "issue edit 105 --repo $REPO --add-label needs-input"
check "a failed worker comments on the issue" logged "issue comment 105"

# A change to the script during a run does not break the run.
new_case edit-during-run
work_rules 106 'issue-106\thttps://example.org/pull/121\n'
cat >"$case_dir/claude-action.sh" <<'EOF'
script=$FAKE/engine/scripts/work-next-issue.sh
{ echo '#!/usr/bin/env bash'; echo 'echo "the new version must not run"; exit 7'; } >"$script.new"
mv "$script.new" "$script"
printf '\n%.0s' {1..200} >>"$script"
echo 'if then fi ((' >>"$script"
EOF
run work-next-issue.sh
status=$?
check "a script changed during a run ends with exit code 0" test "$status" -eq 0
check "a script changed during a run still labels the pull request" logged "pull/121 --repo $REPO --add-label needs-review"

# The review merges only an approval of the exact commit.
review_rules() { # head commit, [changed file]
  cat >"$case_dir/rules.sh" <<EOF
respond() {
  case "\$*" in
    "pr list"*) echo 116 ;;
    "pr view 116 --repo $REPO --json headRefOid,baseRefName"*) echo "dev $1" ;;
    "pr view 116 --repo $REPO --json headRefOid"*) echo $1 ;;
    "pr view 116 --repo $REPO --json mergeable"*) echo MERGEABLE ;;
    "pr view 116 --repo $REPO --json reviews,comments"*) echo 0 ;;
    "pr view 116 --repo $REPO --json labels"*) echo "\${LABELS:-needs-review}" ;;
    "pr checks"*) echo pass ;;
    "pr diff"*) echo ${2:-src/example.sh} ;;
  esac
}
EOF
}

new_case review-approves
review_rules "$sha"
echo "echo 'VERDICT: APPROVE $sha'" >"$case_dir/claude-action.sh"
run review-next-pr.sh
check "an approval of the exact commit merges" logged "pr merge 116 --repo $REPO --merge --match-head-commit $sha"
check "the review gets the skills of the engine" claude_ran "/minion:review-pr 116 $sha"

new_case review-approves-other-commit
review_rules "$sha"
echo "echo 'VERDICT: APPROVE 0000000000000000000000000000000000000000'" >"$case_dir/claude-action.sh"
run review-next-pr.sh
check "an approval of another commit does not merge" not_logged "pr merge"
check "an approval of another commit waits for the owner" logged "--add-label needs-input"
check "an approval of another commit does not add needs-owner" not_logged "--add-label needs-owner"

# A gate stops only the merge: the review still runs and posts its findings, and the owner merges.
approve() { echo "echo 'VERDICT: APPROVE $sha'" >"$case_dir/claude-action.sh"; }

new_case review-engine-guard
review_rules "$sha" .minion/config.sh
approve
run review-next-pr.sh
check "a change to .minion/ gets a review" claude_ran "/minion:review-pr 116 $sha"
check "an approved change to .minion/ is not merged" not_logged "pr merge"
check "an approved change to .minion/ gets needs-owner" logged "--add-label needs-owner"
check "the owner learns why the merge waits" grep -q "Only the owner merges.*\.minion/config.sh" "$case_dir/gh.log"

new_case review-guard-changes
review_rules "$sha" .minion/config.sh
echo "echo 'VERDICT: CHANGES'" >"$case_dir/claude-action.sh"
run review-next-pr.sh
check "a guarded change with findings goes to the fix agent" logged "--add-label changes-requested"
check "a guarded change with findings does not wait for the owner" not_logged "--add-label needs-owner"

new_case review-project-guard
echo "OWNER_ONLY_PATHS='^pom\.xml\$'" >>"$seed/.minion/config.sh"
commit_seed "made-up guard"
push_seed
echo "$sha" >"$project/dev-deployed"
review_rules "$sha" pom.xml
approve
run review-next-pr.sh
check "a change to an owner-only path of the project gets a review" claude_ran "/minion:review-pr"
check "an approved change to an owner-only path of the project is not merged" not_logged "pr merge"
check "an approved change to an owner-only path of the project gets needs-owner" logged "--add-label needs-owner"

new_case review-pre-review-fails
printf '#!/usr/bin/env bash\nexit 1\n' >"$seed/.minion/hooks/pre-review"
chmod +x "$seed/.minion/hooks/pre-review"
commit_seed "made-up check"
push_seed
echo "$sha" >"$project/dev-deployed"
review_rules "$sha"
approve
run review-next-pr.sh
check "a failed pre-review hook still gets a review" claude_ran "/minion:review-pr"
check "an approval after a failed pre-review hook is not merged" not_logged "pr merge"
check "an approval after a failed pre-review hook gets needs-owner" logged "--add-label needs-owner"

# With a Telegram bot, the owner gets a message each time the loop stops and waits for them.
notified() { grep -qF -- "$1" "$case_dir/curl.log" 2>/dev/null; }
not_notified() { ! notified "$1"; }
telegram() { TELEGRAM_BOT_TOKEN=made-up-token TELEGRAM_CHAT_ID=42 run "$@"; }

# The fix agent takes requested changes, and each comment of the owner that has no answer yet, also
# on a pull request that waits for the owner. The fake keeps the head commit and the count of
# answers in files, so the fake claude can push a commit or answer.
fix_rules() { # labels, whether an owner comment waits
  git -C "$seed" push -q origin dev:issue-116
  echo "$sha" >"$case_dir/head"
  echo 0 >"$case_dir/answers"
  cat >"$case_dir/rules.sh" <<EOF
respond() {
  case "\$*" in
    "pr list"*) echo 116 ;;
    "pr view 116 --repo $REPO --json headRefName"*) echo issue-116 ;;
    "pr view 116 --repo $REPO --json headRefOid"*) cat "\$FAKE/head" ;;
    "pr view 116 --repo $REPO --json body"*) echo "made-up body" ;;
    "pr view 116 --repo $REPO --json labels"*) echo "$1" ;;
    "pr view 116 --repo $REPO --json comments"*owner_comment_waits*) echo $2 ;;
    "pr view 116 --repo $REPO --json comments"*) cat "\$FAKE/answers" ;;
  esac
}
EOF
}
fix_pushes() { echo 'echo 0000000000000000000000000000000000000001 >"$FAKE/head"' >>"$case_dir/claude-action.sh"; }
fix_answers() { echo 'echo 1 >"$FAKE/answers"' >>"$case_dir/claude-action.sh"; }

new_case fix-findings
fix_rules changes-requested false
fix_pushes
run fix-next-pr.sh
check "a correction goes back to the review" logged "--add-label needs-review"
check "a correction removes changes-requested" logged "--remove-label changes-requested"
check "a correction posts no answer of the script" not_logged "**Fixer:** I pushed"

new_case fix-owner-question
fix_rules needs-owner true
fix_answers
telegram fix-next-pr.sh
check "a comment of the owner on a pull request for the owner starts the fix agent" claude_ran "/minion:fix-pr 116"
check "the fix agent may answer on the pull request" claude_ran "Bash(gh pr comment 116:*)"
check "an owner review counts as a comment" logged "number,isCrossRepository,labels,comments,reviews"
check "an answer alone keeps needs-owner" not_logged "--remove-label needs-owner"
check "an answer alone does not go back to the review" not_logged "--add-label needs-review"
check "an answer notifies the owner" notified "text=$REPO pull request 116: the fix agent answered your comment"

new_case fix-owner-change
fix_rules needs-owner true
fix_pushes
run fix-next-pr.sh
check "a change for the owner goes back to the review" logged "--add-label needs-review"
check "a change for the owner keeps needs-owner" not_logged "--remove-label needs-owner"
check "a change without an answer gets one from the script" logged "**Fixer:** I pushed"

new_case fix-owner-nothing
fix_rules needs-owner true
telegram fix-next-pr.sh
check "a run with no answer and no change tells the owner" logged "The worker stopped"
check "a run with no answer and no change notifies the owner" notified "needs you"
check "a run with no answer and no change waits with needs-input" logged "--add-label needs-input"
check "a run with no answer and no change keeps needs-owner" not_logged "--remove-label needs-owner"

new_case fix-findings-with-owner-label
fix_rules "changes-requested needs-owner" false
fix_pushes
run fix-next-pr.sh
check "the fix agent takes requested changes also with needs-owner" claude_ran "/minion:fix-pr 116"
check "the fix agent does not skip needs-owner" not_logged 'index("needs-owner")'
check "a correction with needs-owner keeps it" not_logged "--remove-label needs-owner"

new_case review-owner-label
review_rules "$sha"
approve
LABELS="needs-review needs-owner" run review-next-pr.sh
check "a pull request with needs-owner still gets a review" claude_ran "/minion:review-pr 116 $sha"
check "an approved pull request with needs-owner is not merged" not_logged "pr merge"
check "the review does not skip needs-owner" not_logged "-label:needs-owner"
removes_only_needs_review() { ! grep -o -- "--remove-label [a-z-]*" "$case_dir/gh.log" | grep -qv "needs-review$"; }
check "a gated approval removes no label but needs-review" removes_only_needs_review

new_case update-owner-label
cat >"$case_dir/rules.sh" <<EOF
respond() {
  case "\$*" in
    "pr list"*) printf '116\tissue-116\tMERGEABLE\tneeds-review,needs-owner\n' ;;
    "api repos/$REPO/compare/"*) echo 2 ;;
  esac
}
EOF
run update-pr-branches.sh
check "a branch with needs-owner still gets the new dev" logged "pr update-branch 116 --repo $REPO"
check "the branch update does not skip needs-owner" not_logged "-label:needs-owner"

new_case review-skips-owner-comment
review_rules "$sha"
approve
run review-next-pr.sh
check "the review leaves a pull request with an unanswered owner comment" logged "owner_comment_waits | not"

new_case notify-needs-input
work_rules 105
echo "exit 1" >"$case_dir/claude-action.sh"
telegram work-next-issue.sh
check "a question of the worker notifies the owner" notified "text=$REPO issue 105 needs you"
check "the message links the issue" notified "https://github.com/$REPO/issues/105"
check "the message goes to the chat of the owner" notified "chat_id=42"
check "the token stays off the command line" grep -q 'url = ".*made-up-token' "$case_dir/curl.log"
check "the token is not an argument" not_notified "made-up-token/sendMessage --"

new_case notify-gate
review_rules "$sha" .minion/config.sh
approve
telegram review-next-pr.sh
check "an approval that the owner merges notifies the owner" notified "text=$REPO pull request 116 needs you"

new_case notify-no-bot
work_rules 105
echo "exit 1" >"$case_dir/claude-action.sh"
run work-next-issue.sh
check "without a bot, nothing is sent" test ! -e "$case_dir/curl.log"

new_case notify-merge
review_rules "$sha"
approve
telegram review-next-pr.sh
check "a merge does not notify by default" test ! -e "$case_dir/curl.log"
NOTIFY=all telegram review-next-pr.sh
check "with NOTIFY=all, a merge notifies the owner" notified "merged into dev"

# promote.sh does the next step of a release each time the owner runs it. The release branch is main.
promote_case() { # name, version on main, then commits for dev as "subject|version" pairs
  new_case "$1"
  echo "$2" >"$seed/VERSION"
  commit_seed "chore: version $2"
  git -C "$seed" push -q origin dev:main
  shift 2
  local pair
  for pair in "$@"; do
    echo "${pair#*|}" >"$seed/VERSION"
    commit_seed "${pair%|*}"
  done
  push_seed
  cat >"$case_dir/rules.sh" <<'EOF'
respond() {
  case "$*" in
    "repo view"*) echo main ;;
    "issue list"*"--state open"*) echo 7 ;;
    "issue list"*"--state closed"*) echo 5 ;;
  esac
}
EOF
}
origin_tags() { git -C "$origin" tag; }
origin_file() { git -C "$origin" show "$1:VERSION" 2>/dev/null; }

promote_case promote-version 1.0.0 "feat: made-up feature|1.0.0" "fix: made-up fix|1.0.0"
git -C "$origin" tag v1.0.0 main
run promote.sh "$REPO"
check "promote bumps the minor version for a feat" test "$(origin_file release/1.1.0)" = 1.1.0
check "promote opens the version pull request into dev" logged "pr create --repo $REPO --base dev --head release/1.1.0"

promote_case promote-major 1.4.2 "feat!: made-up break|1.4.2"
git -C "$origin" tag v1.4.2 main
run promote.sh "$REPO"
check "promote bumps the major version for a breaking change" test "$(origin_file release/2.0.0)" = 2.0.0

promote_case promote-first 0.1.0-SNAPSHOT "fix: made-up fix|0.1.0-SNAPSHOT"
run promote.sh "$REPO"
check "promote makes the first release from a snapshot" test "$(origin_file release/0.1.0)" = 0.1.0

promote_case promote-main 1.0.0 "feat: made-up feature|1.0.0" "chore(release): 1.1.0|1.1.0"
git -C "$origin" tag v1.0.0 main
run promote.sh "$REPO"
check "promote opens the pull request into main" logged "pr create --repo $REPO --base main --head dev --title release: 1.1.0"
check "the pull request into main closes the issues on dev" grep -q "Closes #7" "$case_dir/gh.log"
check "the pull request into main lists the features" grep -q "made-up feature" "$case_dir/gh.log"

promote_case promote-tag 1.1.0
run promote.sh "$REPO"
check "promote tags a release that has no tag" test "$(origin_tags)" = v1.1.0
check "promote removes on-dev from the closed issues" logged "issue edit 5 --repo $REPO --remove-label on-dev"

promote_case promote-nothing 1.0.0
git -C "$origin" tag v1.0.0 main
run promote.sh "$REPO"
check "promote with nothing new opens no pull request" not_logged "pr create"
check "promote with nothing new says so" grep -q "nothing new" "$case_dir/out.log"

# The owner merges a pull request by hand. The next round deploys the new dev once.
new_case owner-merge
run agent-loop.sh
commit_seed "made-up merge"
push_seed
run agent-loop.sh
check "a merge by the owner reaches the clone" test "$(git -C "$project/clone" rev-parse HEAD)" = "$sha"
check "a merge by the owner deploys dev once" test "$(wc -l <"$case_dir/deploy.log")" -eq 1
run agent-loop.sh
check "the next round does not deploy again" test "$(wc -l <"$case_dir/deploy.log")" -eq 1

if [ "$failures" -ne 0 ]; then
  echo "loop-test: $failures failure(s)" >&2
  exit 1
fi
