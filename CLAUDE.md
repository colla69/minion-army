# minion-army

A working loop that lets Claude Code agents take GitHub issues to merged pull requests, for every
repository of one GitHub account that opts in with a config file. The owner writes the issues, tries
the result and releases it. The loop was extracted from `makeMyTaxes`, and the non-obvious part is
its guards: the agents never merge, and a pull request can never change the loop that reviews it.

`docs/plan.md` holds the design and the phases. Read it before you change the design.

## Stack

- Bash, with `flock` for all locking
- `gh` for every call to GitHub, and `jq` to read the project config
- The `claude` CLI in print mode (`claude -p`) for each agent run
- A systemd user timer and `systemd-run` for the slots. Docker comes in a later phase

## Commands

No command exists yet. Phase 1 of the plan adds the test script of the loop, which needs no network
and never starts Claude. Add it here when it exists.

## Conventions

- Each script wraps its body in `{ ...; exit; }`, so Bash reads the whole file before it runs it. A
  change to the file during a run then cannot break the run.
- A step that finds no work must stop before any call to Claude, so an idle round costs nothing.
- Each script that starts an agent lists the tools the agent can use. Never start an agent with all
  tools.
- Texts for people follow the `simple-natural-language` standard. Commits follow Conventional Commits.

## Boundaries

- The agents never merge, and never push to the base branch or the release branch. A script does the
  merge, and only when the verdict names the exact commit that the review read.
- Read the project config and the hooks from the base branch only, never from a pull request branch.
- The loop accepts a repository only when the configured account owns it. It never accepts a fork.
- Nothing in this repository may name one project. A value that belongs to one project goes in that
  project's config file or hooks.
- Promotion to the release branch and the live deploy stay behind the owner.
