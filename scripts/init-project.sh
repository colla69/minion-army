#!/usr/bin/env bash
# Creates the labels of the working loop in a project. An existing label keeps its name and gets the
# color and the description from here. It does not call Claude.
# Usage: scripts/init-project.sh owner/name
set -euo pipefail

repo=${1:?Usage: scripts/init-project.sh owner/name}

while IFS='|' read -r name color description; do
  gh label create "$name" --repo "$repo" --color "$color" --description "$description" --force >/dev/null
  echo "$repo: label $name"
done <<'LABELS'
agent-ready|0e8a16|The owner released the issue for the worker
in-progress|fbca04|A worker has the issue
needs-input|d93f0b|The loop stopped and waits for the owner
on-dev|5319e7|The change is on dev, and the owner can try it
needs-review|1d76db|The pull request waits for the review
changes-requested|e99695|The pull request waits for the fix agent
needs-owner|b60205|Only the owner merges. The scripts add it, and only the owner removes it
LABELS

echo "Next: add .minion/config.sh to dev (see project.example/config.sh), and a rule on dev that requires CI."
