# agents

piabrota's buddies: small agents that watch [piabrota/nix-os](https://github.com/piabrota/nix-os)
and its VPS, and report on GitHub as the App **piabrota-ops**. Each is a bash script that gathers
its inputs into a directory and asks [Claude Code](https://code.claude.com) headless, with
read-only tools, what they mean. They run on the VPS as [rax](https://github.com/piabrota/rax)
tasks, one pod per run (rax's pod runner), on a Claude subscription rather than an API key.

| Agent | Runs | Reads | Writes |
|---|---|---|---|
| `deploy-doctor` | often (every 15 minutes) | failed runs of nix-os' `deploy` workflow in the last day without an issue: the failed jobs' logs (last 400 lines) and the repository at that commit | one issue per failed run, labelled `deploy-failure`: transient or real, why, and what to do |
| `health-digest` | once a day | the box's health snapshot (the ConfigMap `ax-tasks/health-snapshot`, which the box writes), the last deploys, the previous digest | a comment on the open issue labelled `health-digest` (opened the first time) |

`deploy-doctor` calls Claude only when there is a new failure; otherwise it reads two lists and
exits.

## The image

`ghcr.io/piabrota/agents`, from `Dockerfile`: Debian slim, `curl`, `jq`, `openssl`, `git`, and
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

Optional: `REPO` (default `piabrota/nix-os`), `DEPLOY_DOCTOR_MODEL` (`sonnet`),
`HEALTH_DIGEST_MODEL` (`haiku`), `LOOKBACK_HOURS` (`24`), `LOG_LINES` (`400`),
`HEALTH_SNAPSHOT_FILE` (a file instead of the ConfigMap).

## The GitHub App, piabrota-ops

The agents act on GitHub only as this App, never as a person, following marola-dev's MIP-0086 and
its `bot-token` action. What they post shows as `piabrota-ops[bot]`, and says nothing about the
tool that wrote it.

- Created in the org's settings (Settings, Developer settings, GitHub Apps), with no webhook.
  Repository permissions: Actions read, Contents read, Issues read and write, Metadata read.
  Installed on `piabrota/nix-os` only.
- `lib/github-app.sh` mints each token from the App's key: for one named repository, with only
  the permissions that agent needs (`deploy-doctor`: actions read, contents read, issues write;
  `health-digest`: actions read, issues write), valid one hour. It refuses an empty repository or
  permission set, which GitHub would otherwise read as all of them.
- The key stays on the VPS. If a leak is suspected, revoke it in the App's settings, generate a
  new one, and replace `GH_APP_PRIVATE_KEY_B64` in `agents.env`.

## Claude Code here

`lib/common.sh` runs `claude -p` in the directory holding the agent's inputs, with
`--allowedTools` set to read-only tools (`Read,Grep,Glob` for the doctor, `Read` for the digest),
`--strict-mcp-config` (no MCP servers), `--no-session-persistence`, and the model set per agent.
The image turns off the auto-updater, telemetry and other non-essential traffic. The prompts are in
`prompts/`; each fixes the shape of the answer.

## Tests

```console
test/run.sh
```

Both agents against a fake GitHub API (`test/fake_github.py`, Python's standard library) and a fake
`claude` (`test/fake-claude`): the App's JWT and its signature, the token's repository and
permissions, which files Claude Code gets and with which flags, the issue and comment posted, one
issue per run, the digest issue reused. Needs bash, curl, jq, openssl, git and python3; no network,
no secrets. CI runs it with `shellcheck`.

## Licence

MPL-2.0.
