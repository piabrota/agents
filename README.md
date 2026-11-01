# agents

piabrota's buddies: small agents that watch [piabrota/nix-os](https://github.com/piabrota/nix-os)
and its VPS, and report on GitHub as the App **piabrota-ops**. Each is a bash script that gathers
its inputs into a directory and asks [Claude Code](https://code.claude.com) headless, with
read-only tools, what they mean. They run on the VPS as [rax](https://github.com/piabrota/rax)
tasks, one pod per run (rax's pod runner), on a Claude subscription rather than an API key.

| Agent | Runs | Reads | Writes |
|---|---|---|---|
| `deploy-doctor` | in `tick` | failed runs of nix-os' `deploy` workflow in the last day without an issue: the failed jobs' logs (last 400 lines, colour codes stripped) and the repository at that commit | one issue per failed run, labelled `deploy-failure`: verdict, what failed, why, the evidence, what to do; a short comment on the merged pull request the deploy came from; and, when the verdict is `real`, **a fix pull request** against the branch that failed |
| `pr-reviewer` | in `tick` | each open pull request whose head it has not reviewed: its diff, commits, body, and the repository at its head | one review comment, edited on each push: the rules the harness checks itself, and Claude's findings, each quoting a line of the diff |
| `mentions` | in `tick` | comments naming `@piabrota-ops` in the last hour, from trusted people only | one reply each: an answer from the thread and the repository, with its evidence; or `try a fix` (a deploy-failure issue) and `review` (a pull request) as commands |
| `mirror-keeper` | in `tick` | open pull requests that change a doc but not its mirror (pt-BR and English) | a pull request into that pull request's branch that brings the mirrors up to date |
| `flake-annotator` | in `tick` | open pull requests labelled `flake-update` (nix-os' weekly workflow opens them with the closure difference) | one comment per head: the update's risk and what to watch after it deploys |
| `feedback` | in `tick` | the agents' issues labelled `report-wrong`, and their comments with a 👎 from a trusted person | lessons in memory, which each agent reads before it writes again |
| `issue-worker` | on its own schedule, one issue per run | the oldest open issue labelled `agent-ready` by someone who can write to the repository, and the repository at `main` | **a pull request** that closes it, on `agents/issue-<n>`; or, when it cannot, a comment on the issue saying why, and the label `agent-blocked` |
| `health-digest` | once a day | the box's health snapshot (the ConfigMap `ax-tasks/health-snapshot`, which the box writes), the last deploys, the previous digest and the last week's from memory | a comment on the open issue labelled `health-digest` (opened the first time) |

`agent tick` runs the agents that watch GitHub one after the other in one pod, every few minutes:
each exits in seconds when there is nothing new, without calling Claude, and one that fails does
not stop the rest. Every report ends with a small signature: the agent, the model and Claude Code's
version, the turns and time it took, and where it ran (user, pod, OS, kernel, CPUs, RAM, its
memory limit, the image).

## Memory and feedback

`lib/memory.sh` keeps what the agents did (diagnoses, reviews, digests, replies, fixes) and what
people said about it, in PGX on the box (`AGENTS_DB_URL`, the Secret `ax-tasks/agents-memory`; a
`file://` directory in the tests; without it, no memory). Two ways to say a report was wrong: the
label `report-wrong` on an issue the App opened, with a comment saying why, or a 👎 on a comment it
posted. `feedback` turns each into a lesson for the agent that wrote it, and that agent reads its
last lessons before it writes again. They are also the cases to check a prompt change against.

## Agents that write

`deploy-doctor`'s fixes and `mirror-keeper` push branches (`agents/...`) and open pull requests;
they never merge: a merge to nix-os' main is a deploy, and that stays a person's call. The harness
checks a diff before it pushes: at most 5 files and 200 lines for a fix, nothing under
`.github/workflows/` or `keys/`, not `flake.lock`, a key file or `system.stateVersion`, nothing
shaped like a credential; the mirror keeper may change only the mirrors. Pull requests are bipr
(pt-BR, then English) and carry no signature; the signature goes in a comment. They need Contents
read and write on the App; without it, these two do nothing and the rest work as before.

## The issue worker

`issue-worker` runs a session of [Agent Orchestrator](https://github.com/OrchestratorInc/agent-orchestrator)
(`ao`, built from a pinned commit into the image) in its pod. The daemon lives only as long as the
run: it makes the worktree, starts Claude Code in `tmux` and watches the session. A pod has one
session, so nothing here routes CI failures or review comments back to a worker: a failing pull
request stays a person's, or a new issue's.

A worker edits files and nothing else, because the pod's environment holds the App's key, and with
it a merge, which on nix-os is a deploy:

1. **No shell, no network, no git.** `rules/worker-settings.json`, installed as Claude Code's
   managed settings, denies `Bash`, the web tools, sub-agents, reading `/proc` and writing `.claude/` or
   `.git/`; it runs above every other setting and the agents' user cannot change it. Without it, the
   worker does not start.
2. **No credential but Claude's.** `ao` starts from an empty environment with Claude's token only.
3. **The harness does the rest.** It reads `.agent-result.json`, checks the diff (at most 12 files
   and 400 lines, as `MAX_WORK_FILES` and `MAX_WORK_LINES`, nothing under `.github/`, `.claude/` or `keys/`, not
   `flake.lock`, a key file or `system.stateVersion`, nothing shaped like a credential), and only then mints a
   write token, commits with the repository's hooks off, pushes and opens the pull request.

Labels are the controls. `agent-ready` is the go-ahead, and counts only from someone who can write
to the repository; the worker reads the issue's title and body, never its comments. The run moves
it to `agent-working` before it starts, so a run that dies is not paid for twice, and to
`agent-blocked` when a person has to step in. Optional keys: `ISSUE_WORKER_MODEL`
(`claude-sonnet-5-5`), `ISSUE_WORKER_LABEL`, `WORK_TIMEOUT` (`2400` seconds), `IDLE_GRACE` (`180`).

`test/ao-smoke.sh` runs the real `ao` from the image in a pod's limits, with a stand-in for Claude
Code; run it by hand when `AO_COMMIT` changes.

## The image

`ghcr.io/piabrota/agents`, from `Dockerfile`: Debian slim, `curl`, `jq`, `openssl`, `git`, `tmux`, `psql` (for memory),
`ao` (built from a pinned commit, for `issue-worker`), and
Claude Code's standalone binary (2.1.316, its checksum pinned), as user 10001. About 525 MB, most
of it Claude Code. `.github/workflows/image.yml` publishes it on every push to `main` that changes
it; the run summary prints the digest that nix-os pins. A task's command picks the agent:

```console
agent deploy-doctor
agent health-digest
```

## What the agents need

Environment variables, which the VPS gives every task pod from the Secret `ax-tasks/agents`,
written from `/var/lib/kubesolo-secrets/agents.env` on the box (nix-os' `docs/KUBESOLO.md`,
"Agents"). One `KEY=VALUE` per line, no quotes, never in a repository:

| Key | What |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | From `claude setup-token` on your machine: a year-long token for your Claude subscription. The agents' use counts against its limits |
| `GH_APP_ID` | piabrota-ops' App ID |
| `GH_APP_PRIVATE_KEY_B64` | Its private key, the `.pem` file in base64 on one line: `base64 -w0 piabrota-ops.*.pem` (on macOS, `base64 -i <file>`) |

Optional: `AGENTS_DB_URL` (memory; nix-os writes it as its own Secret), `REPO` (default
`piabrota/nix-os`), `TRUSTED_USERS` (`h0ffmann`; beyond the repository's owners, members and
collaborators), the models (`DEPLOY_DOCTOR_MODEL`, `PR_REVIEWER_MODEL`, `MENTIONS_MODEL`,
`MIRROR_KEEPER_MODEL`, `FLAKE_ANNOTATOR_MODEL`, `ISSUE_WORKER_MODEL`: `claude-sonnet-5-5`; `HEALTH_DIGEST_MODEL`:
`claude-haiku-5-5`), `FIX_PRS` (`1`), `TICK_AGENTS`, `LOOKBACK_HOURS` (`24`), `LOG_LINES` (`400`),
`HEALTH_SNAPSHOT_FILE` (a file instead of the ConfigMap).

## The GitHub App, piabrota-ops

The agents act on GitHub only as this App, never as a person, following marola-dev's MIP-0086 and
its `bot-token` action. What they post shows as `piabrota-ops[bot]`, and says nothing about the
tool that wrote it.

- Created in the org's settings (Settings, Developer settings, GitHub Apps), with no webhook.
  Repository permissions: Actions read, Contents read and write (for fix and mirror pull
  requests), Issues read and write, Pull requests read and write, Metadata read. Each agent asks
  for the most it can use and falls back to less: without Contents write there are no fix or
  mirror pull requests, without Pull requests write no comments on pull requests.
  Installed on `piabrota/nix-os` only.
- `lib/github-app.sh` mints each token from the App's key: for one named repository, with only
  the permissions that agent needs (`lib/common.sh`'s `mint_token` takes them from the most to the
  least), valid one hour. It refuses an empty repository or
  permission set, which GitHub would otherwise read as all of them.
- The key stays on the VPS. If a leak is suspected, revoke it in the App's settings, generate a
  new one, and replace `GH_APP_PRIVATE_KEY_B64` in `agents.env`.

## How strict the harness is

The rules that matter are enforced by the scripts and Claude Code's flags, not asked for in the
prompts:

1. **What Claude can do.** `--restricted` (no Bash or other code-running tool, no WebFetch, no
   settings files, the file tools confined to the agent's directory), `--tools` with read-only
   tools only (`Read,Grep,Glob` for the doctor, `Read` for the digest), `--strict-mcp-config` (no
   MCP servers), a pinned model ID (`claude-sonnet-5-5`, `claude-haiku-5-5`), a time limit.
2. **What it returns.** `--json-schema` with `prompts/<agent>.schema.json`: enums for the verdict
   and the status, required fields, lengths. Claude Code validates and retries; the harness renders
   the Markdown from the JSON, so the format cannot drift. `prompts/_rules.md`, the house rules,
   goes with every run (`--append-system-prompt`).
3. **What gets posted.** The doctor checks that every quoted line is in the file it names and that
   every file exists; a failing answer is retried once, told what failed, and after that the issue
   carries the facts the harness has (the failed steps, the log's last lines) and verdict
   `unclear`, without the model's text. Known transient failures (`rules/transient.txt`: SSH
   timeouts, cache errors, a lost runner) are matched before Claude runs and fix the verdict at
   `transient`. Anything shaped like a credential is scrubbed before posting. A digest that does
   not fit its schema twice is not posted; the run fails.

## Tests

```console
test/run.sh
```

Both agents against a fake GitHub API (`test/fake_github.py`, Python's standard library) and a fake
`claude` (`test/fake-claude`): the App's JWT and its signature, the token's repository and
permissions, which files Claude Code gets and with which flags, the issue and comment posted, one
issue per run, the digest issue reused. Needs bash, curl, jq, openssl, git and python3; no network,
no secrets. CI runs it with `shellcheck`. `.github/workflows/code-smell.yml` adds the strict
checks: `ruff` with every rule (`ruff.toml`) and radon's complexity (rank C fails) on the Python,
and `shfmt` on the bash.

## Licence

MPL-2.0.
