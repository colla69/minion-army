# The config of one project for minion-army. It lives in .minion/config.sh on the dev branch.
# The engine sources it from dev, never from a pull request branch, and every change to .minion/ goes to
# the owner. Each setting is optional: the values below are the defaults.

# A regular expression for the paths that only the owner reviews, in addition to .minion/, .github/,
# .githooks/ and .claude/. Example: '^(pom\.xml|src/main/resources/application\.properties)$'
OWNER_ONLY_PATHS=

# The commands that the worker and the fixer can run, beyond the file tools, git and gh.
# Example: WORKER_TOOLS=('Bash(./mvnw -q -B test -Dtest=*)' 'WebFetch')
WORKER_TOOLS=()

# The commands that the review agent can run, beyond reading files, git and gh.
REVIEWER_TOOLS=()

WORKER_EFFORT=medium
REVIEWER_EFFORT=high
WORKER_BUDGET_USD=10
REVIEWER_BUDGET_USD=10

# After this many review rounds without an approval, the pull request goes to the owner.
MAX_REVIEW_ROUNDS=10

# Optional files beside this one:
#   work.md, review.md, fix.md   Rules that the engine adds to the system prompt of that kind of run.
#   hooks/setup-worktree          Runs in each new worktree, for files that git ignores.
#   hooks/pre-review              Runs in the review worktree. A failure sends the pull request to the owner.
#   hooks/deploy-dev              Runs in the engine's clone once for each new commit on dev.
#   hooks/version-get <ref>       Prints the version on a ref. Without it, promote.sh reads the file VERSION.
#   hooks/version-set <version>   Writes the version in a worktree. Without it, promote.sh writes VERSION.
#   hooks/release-notes <range>   Prints a section for the pull request into the release branch.
