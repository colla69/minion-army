# Prompt: dock a project onto minion-army

Open Claude Code in the checkout of the new project, and paste the prompt below. Replace `<engine>`
with the path of your minion-army checkout first.

---

Dock this repository onto minion-army, the loop that takes my GitHub issues to merged pull requests.
The engine is in `<engine>`. Read `<engine>/README.md` (sections "Add a project" and "Labels") and
`<engine>/project.example/config.sh` before you start.

Work in this order. Stop and ask me before each step that changes GitHub, and ask one question at a
time when something is not clear.

1. Check the ground, and report what is missing:
   - The repository has a `dev` branch. If not, ask me which branch to start it from.
   - CI runs on pull requests into `dev`.
   - `dev` has a rule that requires CI and stops direct pushes. Without the required checks, the
     review waits forever.
   - The repository has a `CLAUDE.md` that names the build, test and lint commands. If not, say so,
     because the agents read it.
2. Run `<engine>/scripts/init-project.sh <owner>/<name>` to create the labels.
3. Write `.minion/config.sh` from `<engine>/project.example/config.sh`. Keep only the settings that
   differ from the defaults, and fill them from this repository:
   - `WORKER_TOOLS`: the exact commands the worker needs to build and test, as narrow `Bash(...)`
     patterns. Never `Bash(*)`.
   - `REVIEWER_TOOLS`: only read-only commands, if the review needs any.
   - `OWNER_ONLY_PATHS`: the files whose change I must merge myself, such as build files, deploy
     config or files with credentials. Propose a list and ask me.
4. Propose the hooks that this project needs, and write only the ones I agree to:
   - `hooks/setup-worktree`: when the tests need files that git ignores.
   - `hooks/pre-review`: a check the review agent cannot do, such as a secret scan.
   - `hooks/deploy-dev`: when a dev environment exists.
   Each hook is an executable Bash script that starts with `set -euo pipefail`.
5. Check that the plugins this project enables in `.claude/settings.json` are installed on this
   machine. List those that are missing.
6. Commit the `.minion/` folder on a branch with a Conventional Commits message, push it, and open a
   pull request into `dev`. I merge it myself: the loop never merges a change to `.minion/`.
7. Tell me in a few lines what you set up, and what I still need to do. Once I merge the pull
   request, the loop finds the project within an hour. Then I add the label `agent-ready` to a first,
   small issue to try it.
