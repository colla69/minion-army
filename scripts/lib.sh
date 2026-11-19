# Shared parts of the engine scripts. Source this file, and do not run it.

engine=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
state=${XDG_CACHE_HOME:-$HOME/.cache}/minion-army
mkdir -p "$state/claims"

# A change to these paths can weaken the guards of the loop, so the owner reviews it in every project.
ENGINE_OWNER_ONLY='^(\.minion/|\.github/|\.githooks/|\.claude/)'

export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
export GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1='!gh auth git-credential'

# A slot is one place for an agent run. The loop starts the slots review-1, work-1 and so on, and a run
# by hand gets a slot of its own. A slot runs one script at a time.
AGENT_SLOT=${AGENT_SLOT:-manual-$$}

# Reads the settings of this machine: the projects and the number of slots.
load_machine_config() {
  REPOS=()
  WORKERS=2
  REVIEWERS=2
  ACCOUNT=
  NOTIFY=${NOTIFY:-owner}
  local config=${MINION_CONFIG:-$HOME/.config/minion-army/config}
  if [[ -f "$config" ]]; then
    # shellcheck source=/dev/null
    source "$config"
  fi
  # The slots and the scripts that they start send their messages at this level.
  export NOTIFY
  discover_repos
}

# Sends a message to the owner on Telegram. Level "owner" is for each stop that waits for the owner,
# and always goes out. Level "all" is for progress, and goes out only with NOTIFY=all. Without
# TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID, from agent.env, nothing is sent. A failed send never stops
# the loop. The token goes in a config file for curl, so it never shows in the list of processes.
notify() { # level, text, link
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || return 0
  [[ "$1" == owner || "${NOTIFY:-owner}" == all ]] || return 0
  curl -fsS --max-time 10 -o /dev/null \
    -K <(printf 'url = "%s/bot%s/sendMessage"\n' "${TELEGRAM_API:-https://api.telegram.org}" "$TELEGRAM_BOT_TOKEN") \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$2"$'\n'"$3" ||
    echo "The Telegram message did not go out." >&2
}
# A jq function for a pull request with .comments and .reviews: true when the newest comment or review
# of the owner has no answer yet. GitHub keeps the text of a review apart from the comments. The scripts and the agents write under the owner's account too, so only the start of a
# comment tells them apart from the owner. The skills list the same starts. "Keep going" only starts
# new review rounds, so it needs no answer. Run it with OWNER in the environment.
OWNER_COMMENT_WAITS='
def written_by_the_loop: .body | test("^\\s*(Automatic review|CI failed|This pull request has a merge conflict|The worker stopped|The review approved|\\*\\*Worker:\\*\\*|\\*\\*Fixer:\\*\\*)");
def keep_going: .body | ascii_downcase | test("^\\s*keep going\\W*$");
def answer: .body | test("^\\s*(\\*\\*Fixer:\\*\\*|The worker stopped)");
def messages: [.comments[], (.reviews[] | select(.body != "") | .createdAt = .submittedAt)];
def owner_comment_waits:
  ([messages[] | select(.author.login == env.OWNER and (written_by_the_loop | not) and (keep_going | not))
    | .createdAt] | max // "") as $asked
  | ([.comments[] | select(answer) | .createdAt] | max // "") as $answered
  | $asked > $answered;
'
issue_link() { echo "https://github.com/$REPO/issues/$1"; }
pr_link() { echo "https://github.com/$REPO/pull/$1"; }

# Adds to REPOS each source repository of ACCOUNT that has .minion/config.sh on dev, so that a project
# takes part once the owner merges its config. The list stays in a cache for an hour, so a round makes
# no call for the repositories that do not take part. A failed listing keeps the last list.
discover_repos() {
  [[ -n "$ACCOUNT" ]] || return 0
  local cache=$state/discovered-$ACCOUNT listed repo
  if [[ -z "$(find "$cache" -mmin -60 2>/dev/null)" ]] &&
    listed=$(gh repo list "$ACCOUNT" --source --no-archived --limit 1000 --json nameWithOwner \
      --jq '.[].nameWithOwner'); then
    for repo in $listed; do
      if gh api "repos/$repo/contents/.minion/config.sh?ref=dev" --silent 2>/dev/null; then echo "$repo"; fi
    done >"$cache.new"
    mv "$cache.new" "$cache"
  fi
  [[ -f "$cache" ]] || return 0
  while read -r repo; do
    [[ -n "$repo" && " ${REPOS[*]} " != *" $repo "* ]] && REPOS+=("$repo")
  done <"$cache"
}

# Sets up one project: its own clone at origin/dev, its folder for state, and its config.
# The config and the hooks come from dev only, never from a pull request branch, because they run here.
# Returns 1 when dev has no .minion/config.sh, so the project takes no part.
load_project() { # owner/name
  REPO=$1
  OWNER=${REPO%%/*}
  project=$state/projects/${REPO/\//__}
  root=$project/clone
  mkdir -p "$project"
  if [[ ! -d "$root/.git" ]]; then
    git_locked clone -q -b dev "${MINION_REMOTE_BASE:-https://github.com}/$REPO.git" "$root" || return 1
  fi
  git_locked -C "$root" fetch -q origin dev || { echo "The fetch of $REPO dev failed." >&2; return 1; }
  # Nobody works in this clone, so it can always follow origin/dev.
  git_locked -C "$root" reset -q --hard origin/dev || return 1
  [[ -f "$root/.minion/config.sh" ]] || return 1

  OWNER_ONLY_PATHS=
  WORKER_TOOLS=()
  REVIEWER_TOOLS=()
  WORKER_EFFORT=medium
  REVIEWER_EFFORT=high
  WORKER_BUDGET_USD=10
  REVIEWER_BUDGET_USD=10
  MAX_REVIEW_ROUNDS=10
  # shellcheck source=/dev/null
  source "$root/.minion/config.sh"
}

# Runs a hook of the project from dev, if the project has it. A missing hook counts as a success.
run_hook() { # name, working directory, arguments for the hook...
  has_hook "$1" || return 0
  (cd "$2" && MINION_REPO=$REPO "$root/.minion/hooks/$1" "${@:3}")
}
has_hook() { [[ -x "$root/.minion/hooks/$1" ]]; }

# Sets agent_args: the skills of the engine, the plugins that the project enables, and the rules of
# the project for this kind of run. The plugins and the rules come from dev, so a pull request cannot
# change what the agent that corrects it loads.
set_agent_args() { # work, review or fix
  agent_args=(--plugin-dir "$engine/plugin")
  local folder
  while read -r folder; do
    agent_args+=(--plugin-dir "$folder")
  done < <(python3 -I "$engine/scripts/plugin-dirs.py" "$root/.claude/settings.json" \
    "${MINION_INSTALLED_PLUGINS:-$HOME/.claude/plugins/installed_plugins.json}")
  local rules=$root/.minion/$1.md
  if [[ -f "$rules" ]]; then
    agent_args+=(--append-system-prompt "$(cat "$rules")")
  fi
}

take_lock() { # name
  exec 9>"$state/$1.lock"
  flock -n 9 || { echo "$1 is busy."; exit 0; }
}
take_slot() { take_lock "slot-$AGENT_SLOT"; }

# Runs git while no other agent run changes the shared refs and worktrees of a clone.
git_locked() { flock "$state/git.lock" git "$@"; }

# Only one slot chooses work at a time. The lock holds from the choice until claim, or until the script ends.
lock_choice() {
  exec 7>"$state/choice.lock"
  flock 7
}

# Notes the work of this slot, so that no other slot takes it. The note goes when the script ends.
claim() { # "issue N" or "pr N"
  echo "$REPO $1" >"$state/claims/$AGENT_SLOT"
  trap release EXIT
  flock -u 7
}
release() { rm -f "$state/claims/$AGENT_SLOT"; }
is_claimed() { cat "$state"/claims/* 2>/dev/null | grep -qx "$REPO $1"; }

# Removes the claim of a slot that stopped without its cleanup, for example after a kill.
# The slot lock is free only when no run of that slot is active.
release_stale_claims() {
  local note slot repo kind number
  for note in "$state"/claims/*; do
    [[ -e "$note" ]] || continue
    slot=${note##*/}
    flock -n "$state/slot-$slot.lock" true || continue
    read -r repo kind number <"$note"
    if [[ "$kind" == issue ]]; then
      gh issue edit "$number" --repo "$repo" --remove-label in-progress >/dev/null || continue
    fi
    rm -f "$note"
    echo "Slot $slot stopped during $repo $kind $number. Its claim is gone."
  done
}

# Creates a worktree of a ref, and lets the project add the files that git ignores and its checks need.
prepare_worktree() { # directory, git ref
  remove_worktree "$1"
  git_locked -C "$root" worktree add -q --detach "$1" "$2"
  if ! run_hook setup-worktree "$1"; then
    echo "The hook setup-worktree of $REPO failed." >&2
    notify owner "$REPO needs you: the hook setup-worktree failed, so no agent can start." \
      "Read the log: journalctl --user -u 'minion-army-*'"
    exit 1
  fi
}

remove_worktree() { # directory
  git_locked -C "$root" worktree remove --force "$1" 2>/dev/null || true
}

# Prints the number of blockers of an issue that are not done. A blocker is done when it is closed or
# has the label on-dev, because GitHub closes an issue only when its change reaches the release branch.
unfinished_blockers() { # issue
  gh api "repos/$REPO/issues/$1/dependencies/blocked_by?per_page=100" --jq \
    '[.[] | select(.state == "open" and ((.labels | map(.name) | index("on-dev")) | not))] | length'
}

# Prints the oldest issue with the label that has no unfinished blocker.
# A failed lookup prints no count, so the issue counts as blocked until the next round.
next_unblocked_issue() { # label
  local candidate
  for candidate in $(gh issue list --repo "$REPO" --state open --label "$1" --author "$OWNER" --limit 100 \
    --search "-label:in-progress -label:needs-input" --json number --jq 'sort_by(.number) | .[].number'); do
    is_claimed "issue $candidate" && continue
    if [[ "$(unfinished_blockers "$candidate")" == 0 ]]; then
      echo "$candidate"
      return
    fi
  done
}

set_pr_label() { # pull request, label to add, the rest are labels to remove
  local pull_request=$1 add=$2 label
  shift 2
  for label in "$@"; do
    gh pr edit "$pull_request" --repo "$REPO" --remove-label "$label" >/dev/null
  done
  gh pr edit "$pull_request" --repo "$REPO" --add-label "$add" >/dev/null
}

# Runs the hook deploy-dev once for each new commit on origin/dev. Call it after load_project.
# The commit is noted even when the deploy fails, so a broken deploy does not run every minute.
# Two slots can merge at the same time, so only one of them deploys. The other one skips it.
deploy_dev() {
  (
    flock -n 6 || exit 0
    target=$(git -C "$root" rev-parse origin/dev)
    if [[ "$(cat "$project/dev-deployed" 2>/dev/null)" != "$target" ]]; then
      echo "$target" >"$project/dev-deployed"
      if run_hook deploy-dev "$root"; then
        has_hook deploy-dev && notify all "$REPO: dev ${target:0:7} is deployed."
      else
        echo "The dev deploy of $REPO failed." >&2
        notify owner "$REPO needs you: the dev deploy of ${target:0:7} failed." \
          "Read the log: journalctl --user -u 'minion-army-*'"
      fi
    fi
  ) 6>"$project/dev.lock"
}
