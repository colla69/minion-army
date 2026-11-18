#!/usr/bin/env bash
# Runs the work of one slot of the working loop, for each project in turn. scripts/agent-loop.sh starts
# each slot as its own systemd unit, so a long run of one slot does not hold up the others.
# Usage: scripts/agent-slot.sh review|work
{ # Bash reads this block in full before it runs it, so a change to this file during a run cannot break the run.
set -uo pipefail

scripts=$(cd "$(dirname "$0")" && pwd)
source "$scripts/lib.sh"
load_machine_config

case "${1:-}" in
  review)
    for repo in "${REPOS[@]}"; do MINION_REPO=$repo "$scripts/review-next-pr.sh"; done
    ;;
  # Corrections come first, so open pull requests finish before new work starts.
  work)
    for repo in "${REPOS[@]}"; do MINION_REPO=$repo "$scripts/fix-next-pr.sh"; done
    for repo in "${REPOS[@]}"; do MINION_REPO=$repo "$scripts/work-next-issue.sh"; done
    ;;
  *)
    echo "Usage: scripts/agent-slot.sh review|work" >&2
    exit 2
    ;;
esac
exit
}
