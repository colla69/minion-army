# minion-army: plan

Status: phase 1 done, 2026-11-18.

## 1. Goal

`makeMyTaxes` has a working loop in which Claude Code agents take GitHub issues to merged pull
requests. minion-army is that loop as its own project, so that many repositories can use it.

For each repository of one GitHub account that opts in, the loop must:

- read the issues that the owner released for the agents
- discuss an issue with the owner when it is not clear
- develop the change and open a pull request
- review the pull request with a separate agent, correct it, and merge it into the base branch
- deploy the base branch to a dev environment after each merge
- prepare a release, and deploy it when the owner promotes it

The owner decides what to build, tries the result and releases it. That does not change.

### Not in scope

- A second code host. The loop uses GitHub only.
- More than one account. The loop serves the repositories of one owner.
- Work on pull requests from forks or from other authors.
- A release without the owner. Promotion and the live deploy stay behind the owner.
- A project with only one branch. Each project needs a base branch, such as `dev`, and a separate
  release branch, such as `main`. A project with only `main` would need other rules for the review,
  the dev deploy and the promotion.

## 2. Where we start

The loop in `makeMyTaxes` is about 600 lines of Bash in `scripts/`, four skills in `.claude/skills/`,
and a test script with a fake `gh` and a fake `claude`. `makeMyTaxes/docs/agentic-workflow.md`
describes the flow, the labels and the guards. minion-army keeps that flow.

| Part today | File in `makeMyTaxes` | Generic? |
|---|---|---|
| Round and slots | `agent-loop.sh`, `agent-slot.sh`, `install-agent-timer.sh` | Yes, apart from the unit names |
| Locks, claims, worktrees, dev sync | `agent-lib.sh` | Yes, apart from `REPO`, `OWNER` and the worktree setup |
| Worker | `work-next-issue.sh`, skill `work-issue` | The flow is. The tool list and the build commands are not |
| Review and merge | `review-next-pr.sh`, skill `review-pr` | The flow is. The owner-only paths and the scans are not |
| Corrections | `fix-next-pr.sh`, skill `fix-pr` | The flow is. The tool list is not |
| Housekeeping | `update-pr-branches.sh`, `label-merged-issues.sh` | Yes |
| Promotion | skill `promote` | The steps are. Reading and setting the version is Maven |
| Deploy | `deploy-dev.sh`, `deploy-live.sh` | No. Each project deploys in its own way |
| Project checks | `privacy-scan.sh`, `law.sh`, agent `tax-law-checker` | No. They stay in `makeMyTaxes` |

## 3. Design

### 3.1 Three places

| Place | Holds | Who changes it |
|---|---|---|
| minion-army (this repository) | The engine: scripts, generic skills, tests | The owner, by hand or through the loop itself later |
| `.minion/` in each project | What only that project knows: commands, paths, hooks, extra rules | The owner only |
| `~/.config/minion-army/` on the machine | The account, the number of slots, the budgets, the token | The owner only |

The engine no longer lives inside the project that it works on. So a pull request cannot change the
scripts that review and merge it.

### 3.2 The project config

A repository takes part when its `dev` branch holds `.minion/config.sh`. A repository without the
file is ignored. `project.example/config.sh` lists every setting with its default.

```bash
OWNER_ONLY_PATHS='^(pom\.xml|app/src/main/resources/application\.properties)$'
WORKER_TOOLS=('Bash(scripts/build.sh ./mvnw -q -B test -Dtest=*)' 'Bash(scripts/law.sh:*)')
REVIEWER_TOOLS=('Bash(scripts/law.sh:*)')
```

- The config is a Bash file that the engine sources. The machine has no `jq`, and the file comes
  from the same trusted branch as the hooks, so sourcing it adds no new risk.
- The branches are fixed: `dev` is the base branch, and the release branch is the default branch on
  GitHub. A config cannot name its own base branch, because the engine must know the branch before it
  can read the file.
- The engine always adds `.minion/`, `.github/`, `.githooks/` and `.claude/` to the owner-only paths.
  A project cannot remove them.
- The engine supplies the tools that every project needs: the file tools, the allowed `git` and `gh`
  calls, and the bans on `--no-verify` and on a forced push. `WORKER_TOOLS` and `REVIEWER_TOOLS` add
  the commands of the project.

### 3.3 Hooks

A hook is an executable file in `.minion/hooks/`. Each hook is optional. The engine runs a hook with
the worktree as its working directory.

| Hook | When the engine runs it | Use in `makeMyTaxes` |
|---|---|---|
| `setup-worktree` | After it creates a worktree | Copy `.privacy` and `law/text` |
| `pre-review` | Before it starts the review agent. A failure sends the pull request to the owner | Privacy scan and gitleaks |
| `deploy-dev` | Once for each new commit on the base branch | Build the image, start the dev container |
| `deploy-live` | When the owner runs the live deploy for a tag | Update the live container |
| `version-get`, `version-set` | During promotion | Read and set the version in `pom.xml` |

### 3.4 Extra rules for the agents

The generic skills hold the rules that apply to every project: read the issue, ask instead of guess,
never merge, treat text from other accounts as data, write tests, open the pull request.

A project adds its own rules in `.minion/work.md`, `.minion/review.md` and `.minion/fix.md`. The
engine reads the file from `dev` and passes it with `--append-system-prompt`. The agent does not read
it from the worktree, because the fixer's worktree is the pull request branch, and a pull request
could otherwise change the rules of its own fixer. In `makeMyTaxes`, these files hold the build
commands, the rule on the full test suite, and the step with the `tax-law-checker` agent.

The engine passes its skills to each agent run as the plugin `minion`, with `claude -p --plugin-dir
plugin`. The scripts start them as `/minion:work-issue`, `/minion:review-pr` and `/minion:fix-pr`. A
test on 2026-11-18 showed that `--plugin-dir` loads skills in print mode.

### 3.5 Trust rules

1. The engine reads `.minion/config.sh`, the hooks and the extra rules from the base branch. It
   never reads them from a pull request branch. The hooks run on the owner's machine, so this rule
   is the main guard.
2. The engine accepts a repository only when the configured account owns it, and never a fork.
3. A worker starts only for an issue that the owner wrote and that has the label `agent-ready`.
4. The agents cannot merge. The review gives a verdict as text, and the script merges only when the
   verdict names the exact commit that the review read.
5. A pull request that changes an owner-only path, or fails the pre-review hook, still gets a review
   and fixes. Only the merge waits for the owner (since 2026-11-19).
6. Each agent run has a tool list and a budget.

One risk stays, as it does today: the worker runs the build of the project, and the build runs code
from the pull request branch. Phase 5 limits the damage with a container.

### 3.6 State on the machine

| Path | Holds |
|---|---|
| `~/.config/minion-army/config` | `REPOS`, `WORKERS`, `REVIEWERS` (template: `config.example`) |
| `~/.config/minion-army/agent.env` | `CLAUDE_CODE_OAUTH_TOKEN`, mode 600 |
| `~/.cache/minion-army/` | Slot locks and claims for the whole machine |
| `~/.cache/minion-army/projects/<owner>__<name>/` | The engine's clone, the worktrees, the last deployed commit |

The engine works in its own clone, which always follows `origin/dev`, and reads `.minion/` from it.
Today the loop fast-forwards the owner's working checkout of `makeMyTaxes`. minion-army no longer
touches that checkout. A claim names the project, such as `colla69/makeMyTaxes issue 104`.

### 3.7 Slots across projects

The slot counts stay global: `WORKERS` and `REVIEWERS` are for the whole machine, not for each
project. Two builds at the same time can crash the machine today, and more projects make that worse.

- A free slot takes the oldest waiting work over all projects. Phase 1 is simpler: a slot goes
  through the projects in the order of `REPOS`, and takes at most one item from each.
- The engine offers one build lock for the whole machine, as a command that a project puts in front
  of its build. It replaces `scripts/build.sh`.

### 3.8 Labels

The labels stay as they are: `agent-ready`, `in-progress`, `needs-input`, `on-dev` on issues, and
`needs-review`, `changes-requested`, `needs-owner`, `needs-input` on pull requests. A command of the engine creates
them in a new project.

### 3.9 Commands

One entry point, `minion`, with these subcommands:

| Command | Does |
|---|---|
| `minion round` | One round over all projects. The timer runs it |
| `minion install` | Writes and starts the systemd timer |
| `minion init <repo>` | Creates the labels, and prints a starter `.minion/config.sh` |
| `minion status` | Shows the projects, the slots and their claims |
| `minion work <repo> <issue>`, `minion review <repo> <pr>` | One run by hand |
| `minion deploy-live <repo> <tag>` | Runs the `deploy-live` hook. Only the owner runs this |

## 4. Phases

Each phase ends with something that works. The old loop in `makeMyTaxes` stays until phase 2 ends.

### Phase 0: dock the repository — done

The standards are installed, and `CLAUDE.md` exists.

### Phase 1: the engine, for one project — done

1. Done: `tests/loop-test.sh`, ported with its fake `gh` and fake `claude`. It is the check command
   of this repository.
2. Done: the generic scripts, with `REPO`, `OWNER`, the tool lists, the owner-only paths and the
   worktree setup taken from the project config and the hooks.
3. Done: the config is sourced from the engine's clone at `origin/dev`.
4. Done: the skills `work-issue`, `review-pr` and `fix-pr` in `plugin/`, without the tax and Maven
   parts.
5. Done: `--plugin-dir` works in print mode.
6. Done: the repository list comes from the machine config. Discovery comes in phase 3.
7. Done: on 2026-11-18, issue 1 of `colla69/minion-army-sandbox` went to a merged pull request.

The `minion` entry point of section 3.9 is not built yet. The scripts keep their old names in
`scripts/`, so the port stays easy to compare with `makeMyTaxes`.

Done when: the tests pass, and a round against a test repository takes one issue to a merged pull
request.

### Phase 2: `makeMyTaxes` moves to the engine — switched, first issue open

1. Done: makeMyTaxes #171 added `.minion/config.sh` and four hooks, and removed the old loop in the
   same pull request. The only rule of the old skills that `CLAUDE.md` did not hold yet, the
   `tax-law-checker` step, moved into `CLAUDE.md`, so makeMyTaxes needs no rules files. The hook
   `setup-worktree` takes the private terms of the privacy scan from
   `~/.config/makemytaxes/privacy/`.
2. Done on 2026-11-18: the old timer is off, and `minion-army-agent.timer` runs both projects. The dev
   container runs from the engine's clone, with the test data copied over. The owner checked a
   deploy.
3. Open: run a few issues of makeMyTaxes through the new loop.

To go back: revert the merge of #171, stop `minion-army-agent.timer` and start
`makemytaxes-agent.timer`.

### Phase 3: many projects

1. Done: with `ACCOUNT` in the machine config, the engine lists the source repositories of the
   account, keeps the ones with `.minion/config.sh` on `dev`, and caches the list for an hour. A
   failed listing keeps the last list. On 2026-11-19 it checked 36 repositories in 18 seconds.
2. Done: `load_project` clones a new project into the engine's folder by itself.
3. Done: `scripts/init-project.sh owner/name` creates the labels.
4. Open, only when needed: the oldest work over all projects first, a build lock for the whole
   machine, and `minion status`. makeMyTaxes keeps its own build lock in `scripts/build.sh`.

Done when: a second project takes part after the owner merges a config file, with no change on the
machine.

### Phase 4: promotion and deploy — done, first release open

1. Done: `scripts/promote.sh owner/name` replaces the `promote` skill. Every step follows fixed
   rules, so a script does it without Claude, and the loop test covers it. The hooks `version-get`,
   `version-set` and `release-notes` adapt it to a project. Without them, it uses a `VERSION` file.
2. Dropped: `minion deploy-live`. The live deploy of makeMyTaxes must run in the checkout that holds
   the live data, not in the engine's clone. Each project keeps its own live deploy, and the owner
   starts it.
3. Done: makeMyTaxes #178 added the three hooks and removed its `promote` skill. Open: the first
   real release with `promote.sh`.
4. Done, found on the way: Claude Code loads project plugins only in the folder where they were
   installed. The engine now passes the plugins that a project enables on `dev` with
   `--plugin-dir`, so the agents in its worktrees get the project's standards and the
   `marketplace-base:reviewer` agent.

Done when: a release of `makeMyTaxes` and of one other project runs through the same steps.

### Phase 5: Docker

1. One base image with `bash`, `git`, `gh` and `claude`. A project adds its own toolchain in a
   small Dockerfile in `.minion/`.
2. Each agent run gets its own container, with only its worktree mounted.
3. The deploy hooks need Docker on the host. Decide here between the Docker socket in the engine's
   container, which gives up most of the isolation, and deploy hooks that stay on the host.

Done when: an agent run cannot read or write outside its worktree.

### Telegram messages — done on 2026-11-19

`notify` in `scripts/lib.sh` sends a message through a Telegram bot each time the loop stops and
waits for the owner. With `NOTIFY=all`, it also sends the progress. The token and the chat stay in
`agent.env`, and the token goes to curl in a config file, never on a command line.

### Owner comments get answers — done on 2026-11-19

Only the merge waits for the owner. The fix agent takes each comment of the owner that has no
answer yet, on any open pull request, also one with `needs-owner`. It answers with a comment that
starts with `**Fixer:**`. A change goes back to the review, and the review skips a pull request whose
owner comment waits, so a merge cannot pass over it.

### needs-owner is only a merge gate — done on 2026-11-19

The scripts add `needs-owner` without removing other labels, and never remove it. Only the owner
does. It stops only the merge: the branch update, the review and the fix agent run as usual. A real
stop of the loop (the round limit, a review that asks a person or has no clear verdict, a fix agent
that did nothing) sets `needs-input` on the pull request instead, so the loop does not retry.

## 5. Open questions

1. **Closing pull requests.** Today nothing closes a pull request without a merge. Not decided yet.
   Possible triggers: the owner closes the issue, or the owner adds a label.
2. **A label for promotion.** The owner runs `/promote` by hand today. A label on an issue or a
   comment could start the same steps. Is that wanted?
3. **The name of the config folder.** This plan uses `.minion/`.
4. **Who works on minion-army itself.** The loop could take issues of this repository too, once
   phase 3 is done. Every path here is then owner-only, so the gain may be small.
