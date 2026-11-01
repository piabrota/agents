#!/usr/bin/env bash
# The real `ao` from the image, in a pod's limits (768 MiB, half a CPU), with a stand-in for Claude
# Code: the calls issue-worker makes and test/fake-ao fakes. Needs Docker; no secrets and no Claude
# usage. It builds and runs Agent Orchestrator's code, so CI does not run it: run it by hand when
# AO_COMMIT changes.
#
#   test/ao-smoke.sh
set -euo pipefail
cd "$(dirname "$0")/.."
image=agents-ao-smoke
docker build -q -t "$image" . >/dev/null
docker run --rm -i --memory=768m --cpus=0.5 --user 10001 --entrypoint bash "$image" -s <<'SMOKE'
set -uo pipefail
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
root=$(mktemp -d)
export AO_DATA_DIR=$root/ao/data AO_RUN_FILE=$root/ao/running.json AO_PORT=3037
export CLAUDE_CODE_OAUTH_TOKEN=not-a-token CLAUDE_CONFIG_DIR=$root/claude PATH=$root/bin:$PATH
mkdir -p "$root/ao" "$root/claude" "$root/bin"
printf '{"hasCompletedOnboarding": true}\n' >"$root/claude/.claude.json"
cat >"$root/bin/claude" <<'FAKE'
#!/bin/bash
case "${1:-}" in
  --version) echo "2.1.316 (Claude Code)"; exit 0 ;;
  auth) echo '{"loggedIn": true, "authMethod": "claude.ai"}'; exit 0 ;;
esac
printf 'arg: %s\n' "$@" >>"$ROOT_LOG"
pwd >>"$ROOT_LOG"
echo done >.agent-result.json
exec sleep 300
FAKE
chmod +x "$root/bin/claude"
export ROOT_LOG=$root/claude-launch.log
git init -q -b main "$root/repo"
git -C "$root/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
ao daemon >"$root/ao/daemon.log" 2>&1 &
for _ in $(seq 60); do ao project ls --json >/dev/null 2>&1 && break; sleep 0.5; done
check "the daemon answers" "ao project ls --json >/dev/null"
ao project add --path "$root/repo" --id worker --worker-agent claude-code
out=$(ao spawn --project worker --mode tui --branch agents/issue-1 --name agents/issue-1 --model claude-sonnet-5-5 --prompt 'do it' 2>&1)
echo "$out"
session=$(sed -nE 's/^spawned session ([^ ]+).*/\1/p' <<<"$out" | head -1)
check "spawn prints the session" "[ -n '$session' ]"
tree=$(git -C "$root/repo" worktree list --porcelain | awk '/^worktree / {t = substr($0, 10)} $0 == "branch refs/heads/agents/issue-1" {print t}')
check "git knows the worktree" "[ -n '$tree' ]"
for _ in $(seq 40); do [ -s "$tree/.agent-result.json" ] && break; sleep 0.5; done
check "the session ran in it and wrote its result" "[ -s '$tree/.agent-result.json' ]"
ao session get "$session" --json | tee "$root/session.json"
check "session get has a status and an activity" "jq -e '(.session // .) | .status and .activity.state' '$root/session.json' >/dev/null"
echo "how claude was launched:"; cat "$ROOT_LOG"
echo "memory (RSS in KiB):"; ps -eo rss,comm --sort=-rss | head -6
check "exit-agent answers and keeps the worktree" "ao session exit-agent '$session' >/dev/null && [ -s '$tree/.agent-result.json' ]"
ao stop >/dev/null 2>&1
[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed; the daemon's log:"; tail -20 "$root/ao/daemon.log"; exit 1; }
SMOKE
