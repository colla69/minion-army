#!/usr/bin/env bash
# One round of the working loop: the housekeeping of each project, then a start of each free slot.
# The machine config sets the projects and how many slots run: WORKERS for new issues and corrections,
# REVIEWERS for reviews. A change takes effect in the next round. A slot that runs finishes its work,
# also when its number is lowered. Each slot stops before any call to Claude if it has no work.
# Usage: scripts/agent-loop.sh
{ # Bash reads this block in full before it runs it, so a change to this file during a run cannot break the run.
set -uo pipefail

scripts=$(cd "$(dirname "$0")" && pwd)
source "$scripts/lib.sh"
load_machine_config

# A merge by the owner reaches the clone and the dev environment here.
for repo in "${REPOS[@]}"; do
  if ! load_project "$repo"; then
    echo "$repo takes no part: its dev branch has no .minion/config.sh."
    continue
  fi
  deploy_dev
  MINION_REPO=$repo "$scripts/update-pr-branches.sh"
  MINION_REPO=$repo "$scripts/label-merged-issues.sh"
done
release_stale_claims

# Starts a slot as its own systemd unit, unless a run of that slot is still active.
# The unit reads the token from a private file. It never goes on a command line.
start_slot() { # kind, number
  local slot=$1-$2
  flock -n "$state/slot-$slot.lock" true || return 0
  ${AGENT_START:-systemd-run} --user --quiet --collect --unit="minion-army-$slot" \
    --working-directory="$engine" \
    --property=EnvironmentFile=-"$HOME/.config/minion-army/agent.env" \
    --setenv=PATH="$PATH" --setenv=AGENT_SLOT="$slot" \
    "$scripts/agent-slot.sh" "$1" || echo "Slot $slot did not start." >&2
}

for ((i = 1; i <= REVIEWERS; i++)); do start_slot review "$i"; done
for ((i = 1; i <= WORKERS; i++)); do start_slot work "$i"; done
exit
}
