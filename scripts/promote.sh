#!/usr/bin/env bash
# Does the next step of a release of one project, and stops. The owner runs it after each merge:
#   1. If the release branch holds a version without a tag, it tags that version.
#   2. If dev holds no version above the release branch, it opens a pull request into dev that sets it.
#   3. Then it opens the pull request from dev into the release branch.
# The owner merges each pull request and deploys the tag. This script never merges and never pushes
# to dev or to the release branch. It does not call Claude.
#
# The version comes from the file VERSION, or from the hooks version-get <ref> and version-set
# <version> of the project. A version with a suffix, such as 1.0.0-SNAPSHOT, is not released yet.
# The hook release-notes <range> can add a section to the pull request into the release branch.
# Usage: scripts/promote.sh owner/name
{ # Bash reads this block in full before it runs it, so a change to this file during a run cannot break the run.
set -euo pipefail

source "$(dirname "$0")/lib.sh"
repo=${1:?Usage: scripts/promote.sh owner/name}
if ! load_project "$repo"; then
  echo "$repo takes no part: its dev branch has no .minion/config.sh." >&2
  exit 1
fi
release=$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name)
git_locked -C "$root" fetch -q --tags origin "$release"

version_of() { # ref
  if has_hook version-get; then
    run_hook version-get "$root" "$1"
  else
    git -C "$root" show "$1:VERSION"
  fi
}
released() { [[ "$1" != *-* ]]; }
higher() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]; }

main_version=$(version_of "origin/$release")
dev_version=$(version_of origin/dev)

# 1. Tag a release that has no tag. Then the issues it closed lose on-dev.
if released "$main_version" && ! git -C "$root" rev-parse -q --verify "refs/tags/v$main_version" >/dev/null; then
  git -C "$root" tag -a "v$main_version" "origin/$release" -m "Release $main_version"
  git_locked -C "$root" push -q origin "v$main_version"
  for issue in $(gh issue list --repo "$REPO" --state closed --label on-dev --limit 500 --json number --jq '.[].number'); do
    gh issue edit "$issue" --repo "$REPO" --remove-label on-dev >/dev/null
  done
  echo "$REPO: tagged v$main_version. It is ready to deploy."
fi

range=origin/$release..origin/dev
subjects=$(git -C "$root" log "$range" --no-merges --format='%s (%h)' | grep -v '^chore(release):' || true)
if [[ -z "$subjects" ]]; then
  echo "$REPO: dev has nothing new for $release."
  exit 0
fi

# 2. Open the version pull request into dev, unless dev already holds a higher version.
if ! released "$dev_version" || { released "$main_version" && ! higher "$dev_version" "$main_version"; }; then
  if ! released "$dev_version"; then
    version=${dev_version%%-*}
    reason="the first release"
  else
    IFS=. read -r major minor patch <<<"$main_version"
    messages=$(git -C "$root" log "$range" --no-merges --format='%s%n%b')
    if grep -qE '^[a-z]+(\([^)]*\))?!:|^BREAKING CHANGE:' <<<"$messages"; then
      version=$((major + 1)).0.0 reason="a breaking change"
    elif grep -qE '^feat(\([^)]*\))?:' <<<"$messages"; then
      version=$major.$((minor + 1)).0 reason="a feature"
    else
      version=$major.$minor.$((patch + 1)) reason="fixes and other changes only"
    fi
  fi
  branch=release/$version
  worktree=$project/$branch
  git_locked -C "$root" worktree remove --force "$worktree" 2>/dev/null || true
  git_locked -C "$root" worktree add -q -B "$branch" "$worktree" origin/dev
  if has_hook version-set; then
    run_hook version-set "$worktree" "$version"
  else
    echo "$version" >"$worktree/VERSION"
  fi
  git -C "$worktree" commit -q -a -m "chore(release): $version"
  git_locked -C "$worktree" push -q origin "$branch"
  remove_worktree "$worktree"
  gh pr create --repo "$REPO" --base dev --head "$branch" --title "chore(release): $version" \
    --body "Sets the version to $version, because of $reason.

$subjects"
  echo "$REPO: merge the version pull request, then run this script again."
  exit 0
fi

# 3. Open the pull request into the release branch, with the commits by kind. GitHub closes an issue
# only when its change reaches the release branch, so the body closes each issue that is on dev.
section() { # title, grep options and pattern...
  local title=$1 lines
  shift
  lines=$(grep "$@" <<<"$subjects" || true)
  if [[ -n "$lines" ]]; then printf '## %s\n\n%s\n\n' "$title" "$(sed 's/^/- /' <<<"$lines")"; fi
}
body="$(section Features -E '^feat')$(section Fixes -E '^fix')$(section Other -vE '^(feat|fix)')"
if has_hook release-notes; then body+="$(run_hook release-notes "$root" "$range")"$'\n\n'; fi
body+=$(gh issue list --repo "$REPO" --state open --label on-dev --limit 500 --json number --jq '.[].number' |
  sed 's/^/Closes #/')
gh pr create --repo "$REPO" --base "$release" --head dev --title "release: $dev_version" --body "$body"
echo "$REPO: review and merge the pull request into $release, then run this script again to tag it."
exit
}
