# minion-army

A working loop that lets Claude Code agents take GitHub issues to merged pull requests, for every
repository of one GitHub account that opts in with a config file. The owner writes the issues, tries
the result and releases it. The loop was extracted from `makeMyTaxes`, and the non-obvious part is
its guards: the agents never merge, and a pull request can never change the loop that reviews it.

`docs/plan.md` holds the design and the phases. Read it before you change the design.

## Stack

- Bash, with `flock` for all locking. No `jq`: `gh --jq` reads GitHub, and the project config is Bash
- `gh` for every call to GitHub
- The `claude` CLI in print mode (`claude -p`) for each agent run, with `plugin/` and the project's
  plugins as `--plugin-dir`. `python3` reads the plugin lists in `scripts/plugin-dirs.py`
- A systemd user timer and `systemd-run` for the slots. Docker comes in a later phase

## Commands

| Task | Command |
|---|---|
| Test the loop (no network, no Claude) | `tests/loop-test.sh` |
| One round by hand | `scripts/agent-loop.sh` |
| One script for one project | `MINION_REPO=owner/name scripts/work-next-issue.sh [issue]` |
| Install the timer | `scripts/install-agent-timer.sh` |
| Create the labels in a new project | `scripts/init-project.sh owner/name` |
| Next step of a release (the owner runs it) | `scripts/promote.sh owner/name` |

Run the loop test through the `marketplace-base:test-runner` agent, so that only the failures reach
the session.

The machine config is `~/.config/minion-army/config` (template: `config.example`). A project opts in
with `.minion/config.sh` on its `dev` branch (template: `project.example/config.sh`).

## Map

| What | Where |
|---|---|
| Clone, config and hooks of a project | `load_project` and `run_hook` in `scripts/lib.sh` |
| Claims and locks between slots | `scripts/lib.sh` |
| The merge and its guards | `scripts/review-next-pr.sh` |
| The skills the agents run | `plugin/skills/` |

## Conventions

- Each script wraps its body in `{ ...; exit; }`, so Bash reads the whole file before it runs it. A
  change to the file during a run then cannot break the run.
- A step that finds no work must stop before any call to Claude, so an idle round costs nothing.
- Each script that starts an agent lists the tools the agent can use. Never start an agent with all
  tools.

## Boundaries

- The agents never merge, and never push to the base branch or the release branch. A script does the
  merge, and only when the verdict names the exact commit that the review read.
- Read the project config and the hooks from the base branch only, never from a pull request branch.
- The loop works only on the source repositories of `ACCOUNT` and on `REPOS` from the machine config,
  and only on issues and pull requests that the owner of the repository wrote. It never takes a
  fork, or a pull request from a fork.
- Nothing in this repository may name one project. A value that belongs to one project goes in that
  project's config file or hooks.
- Promotion to the release branch and the live deploy stay behind the owner.
