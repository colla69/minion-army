# Prompt: dock a project onto minion-army

Open Claude Code in the checkout of the new project, on any machine, and paste the prompt below.
Replace `<engine>` first: either the path of a local minion-army checkout, or its GitHub repository as
`owner/minion-army`.

---

Dock this repository onto minion-army, the loop that takes my GitHub issues to merged pull requests.
The engine is `<engine>`: a local folder, or a GitHub repository. Before you start, read its
`README.md` (sections "Add a project" and "Labels"), `project.example/config.sh` and
`scripts/init-project.sh`. For a repository, read each file with
`gh api repos/<engine>/contents/<path> -H "Accept: application/vnd.github.raw"`.
The loop may run on another machine than this one.

Work in this order. Stop and ask me before each step that changes GitHub, and ask one question at a
time when something is not clear.

1. Check the ground, and report what is missing:
   - The repository has a `dev` branch. If not, ask me which branch to start it from.
   - CI runs on pull requests into `dev`.
   - `dev` has a rule that requires CI and stops direct pushes. Without the required checks, the
     review waits forever.
   - The repository has a `CLAUDE.md` that names the build, test and lint commands. If not, say so,
     because the agents read it.
2. Create the labels. With a local engine, run `<engine>/scripts/init-project.sh <owner>/<name>`.
   Otherwise run the same `gh label create ... --force` command for each label that the script
   lists, with its color and description.
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
   Each hook is an executable Bash script that starts with `set -euo pipefail`. The hooks run on
   the machine of the loop, so they must not depend on paths or tools of this machine. Ask me what
   that machine has.
5. List the plugins that this project enables in `.claude/settings.json`. The agents load them on
   the machine of the loop, so tell me to install them there, in a checkout of this project.
6. Commit the `.minion/` folder on a branch with a Conventional Commits message, push it, and open a
   pull request into `dev`. I merge it myself: the loop never merges a change to `.minion/`.
7. Tell me in a few lines what you set up, and what I still need to do. Once I merge the pull
   request, the loop finds the project within an hour. Then I add the label `agent-ready` to a first,
   small issue to try it.
