#!/usr/bin/env bash
# The agents against a fake GitHub (test/fake_github.py) and a fake claude (test/fake-claude): what
# they ask GitHub for, what Claude Code is given, and what they post. Needs bash, curl, jq, openssl,
# git and python3; no network, no secrets.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
tmp=$(mktemp -d)
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT

fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() {
  printf 'FAIL %s\n' "$1"
  fails=$((fails + 1))
}
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# sent COND: some recorded request matches the jq condition.
sent() { jq -s -e "any(.[]; $1)" "$requests" >/dev/null; }

# The repository at the commit that failed, served as a local git URL.
git init -q "$tmp/nix-os"
printf '# AGENTS.md\n' >"$tmp/nix-os/AGENTS.md"
git -C "$tmp/nix-os" add AGENTS.md
git -C "$tmp/nix-os" -c user.name=t -c user.email=t@t commit -q -m one
sha=$(git -C "$tmp/nix-os" rev-parse HEAD)

# The App's key, as the env file holds it.
openssl genrsa -out "$tmp/app.pem" 2048 2>/dev/null
openssl rsa -in "$tmp/app.pem" -pubout -out "$tmp/app.pub" 2>/dev/null

start_github() {
  local port=$1
  jq -n --arg sha "$sha" '{
    repo: "piabrota/nix-os",
    runs: [
      {id: 555, head_sha: $sha, display_title: "feat: something", html_url: "https://github.com/piabrota/nix-os/actions/runs/555",
       run_attempt: 1, created_at: "2026-10-31T00:00:00Z", event: "push", conclusion: "failure"},
      {id: 554, head_sha: $sha, display_title: "fix: earlier", html_url: "https://github.com/piabrota/nix-os/actions/runs/554",
       run_attempt: 1, created_at: "2026-10-30T23:00:00Z", event: "push", conclusion: "success"}],
    jobs: {"555": [
      {id: 9, name: "deploy", conclusion: "failure", steps: [
        {name: "Build", conclusion: "success"}, {name: "Build and deploy", conclusion: "failure"}]},
      {id: 8, name: "build", conclusion: "success", steps: []}]},
    logs: {"9": "line one\nssh: connect to host *** port 22: Connection timed out\n"}
  }' >"$tmp/state-$port.json"
  : >"$tmp/requests-$port.jsonl"
  python3 test/fake_github.py "$port" "$tmp/state-$port.json" "$tmp/requests-$port.jsonl" &
  pids+=($!)
  for _ in $(seq 50); do curl -s "http://127.0.0.1:$port/" >/dev/null && return; sleep 0.1; done
  echo "the fake GitHub did not start" >&2
  exit 1
}

port=18765
start_github $port
export GITHUB_API=http://127.0.0.1:$port REPO=piabrota/nix-os REPO_GIT_URL=$tmp/nix-os
export GH_APP_ID=123456 GH_APP_PRIVATE_KEY_B64
GH_APP_PRIVATE_KEY_B64=$(base64 -w0 <"$tmp/app.pem")
export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-test CLAUDE_BIN=$root/test/fake-claude
export FAKE_CLAUDE_LOG=$tmp/claude.log
requests=$tmp/requests-$port.jsonl
: >"$FAKE_CLAUDE_LOG"

echo "== deploy-doctor"
FAKE_CLAUDE_ANSWER=$'## Verdict: transient\n\n**What failed:** ssh timed out.' bin/agent deploy-doctor 2>"$tmp/doctor.err" ||
  bad "deploy-doctor exits 0 ($(cat "$tmp/doctor.err"))"

jwt=$(jq -r 'select(.path == "/repos/piabrota/nix-os/installation") | .auth' "$requests" | head -1 | sed 's/^Bearer //')
IFS=. read -r h p s <<<"$jwt"
unb64() {
  local x=$1
  x=$(tr '_-' '/+' <<<"$x")
  while [ $((${#x} % 4)) -ne 0 ]; do x+="="; done
  base64 -d <<<"$x"
}
unb64 "$s" >"$tmp/sig"
check "the App's JWT is signed with its key" \
  "printf '%s.%s' '$h' '$p' | openssl dgst -sha256 -verify '$tmp/app.pub' -signature '$tmp/sig' >/dev/null"
check "the JWT is issued by the App" "[ \"\$(unb64 '$p' | jq -r .iss)\" = 123456 ]"
check "the token is for nix-os alone, with only what the doctor needs" \
  "sent '.path == \"/app/installations/7/access_tokens\" and .body == {repositories: [\"nix-os\"], permissions: {actions: \"read\", contents: \"read\", issues: \"write\"}}'"
check "GitHub calls after the mint carry the installation token, not the JWT" \
  "jq -s -e 'map(select(.path | startswith(\"/repos/piabrota/nix-os/issues\"))) | length > 0 and all(.auth == \"Bearer ghs_fake\")' '$requests' >/dev/null"
check "Claude Code got the run, the failed job's log and the repository" \
  "grep -q './run.json' '$FAKE_CLAUDE_LOG' && grep -q './logs/job-9.log' '$FAKE_CLAUDE_LOG' && grep -q './repo/AGENTS.md' '$FAKE_CLAUDE_LOG'"
check "only the failed job's log was read" "! grep -q './logs/job-8.log' '$FAKE_CLAUDE_LOG'"
check "Claude Code runs read-only, on sonnet, without MCP" \
  "grep -q -- '--allowedTools Read,Grep,Glob' '$FAKE_CLAUDE_LOG' && grep -q -- '--model sonnet' '$FAKE_CLAUDE_LOG' && grep -q -- '--strict-mcp-config' '$FAKE_CLAUDE_LOG'"
issue=$(jq -c 'select(.method == "POST" and .path == "/repos/piabrota/nix-os/issues") | .body' "$requests")
check "one issue, for the failed run only" "[ \"\$(wc -l <<<'$issue')\" -eq 1 ]"
check "its title names the run and the commit" "jq -e '.title == \"Deploy failed: run 555 (${sha:0:7})\"' <<<'$issue' >/dev/null"
check "its body is the diagnosis, then the run's link" \
  "jq -e '(.body | startswith(\"## Verdict: transient\")) and (.body | contains(\"actions/runs/555\")) and .labels == [\"deploy-failure\"]' <<<'$issue' >/dev/null"
check "the label was created" "sent '.method == \"POST\" and .path == \"/repos/piabrota/nix-os/labels\" and .body.name == \"deploy-failure\"'"

: >"$FAKE_CLAUDE_LOG"
FAKE_CLAUDE_ANSWER=x bin/agent deploy-doctor 2>"$tmp/doctor2.err"
check "a run already reported is not reported again" \
  "[ \"\$(jq -c 'select(.method == \"POST\" and .path == \"/repos/piabrota/nix-os/issues\")' '$requests' | wc -l)\" -eq 1 ]"
check "and Claude Code is not called" "[ ! -s '$FAKE_CLAUDE_LOG' ]"
check "it says so" "grep -q 'run 555: already reported' '$tmp/doctor2.err'"

echo "== health-digest"
printf '# snapshot 2026-10-31\nmemory: 965 MiB used\n' >"$tmp/snapshot.md"
export HEALTH_SNAPSHOT_FILE=$tmp/snapshot.md
: >"$FAKE_CLAUDE_LOG"
FAKE_CLAUDE_ANSWER='**2026-10-31: OK**, all active' bin/agent health-digest 2>"$tmp/digest.err" ||
  bad "health-digest exits 0 ($(cat "$tmp/digest.err"))"
check "the token asks for actions:read and issues:write only" \
  "sent '.path == \"/app/installations/7/access_tokens\" and .body.permissions == {actions: \"read\", issues: \"write\"}'"
check "the digest issue is opened the first time" \
  "sent '.method == \"POST\" and .path == \"/repos/piabrota/nix-os/issues\" and .body.title == \"VPS health digest\" and .body.labels == [\"health-digest\"]'"
check "Claude Code got the snapshot, the deploys and the previous digest, read-only, on haiku" \
  "grep -q './snapshot.md' '$FAKE_CLAUDE_LOG' && grep -q './deploys.json' '$FAKE_CLAUDE_LOG' && grep -q 'this is the first' '$FAKE_CLAUDE_LOG' && grep -q -- '--allowedTools Read ' '$FAKE_CLAUDE_LOG' && grep -q -- '--model haiku' '$FAKE_CLAUDE_LOG'"
check "the digest is a comment on that issue" \
  "sent '.method == \"POST\" and .path == \"/repos/piabrota/nix-os/issues/2/comments\" and (.body.body | startswith(\"**2026-10-31: OK**\"))'"

: >"$FAKE_CLAUDE_LOG"
FAKE_CLAUDE_ANSWER='**2026-11-01: OK**' bin/agent health-digest 2>"$tmp/digest2.err"
check "the next day reuses the issue" \
  "[ \"\$(jq -c 'select(.method == \"POST\" and .body.title == \"VPS health digest\")' '$requests' | wc -l)\" -eq 1 ]"
check "and gives Claude Code yesterday's digest" "grep -q '2026-10-31: OK' '$FAKE_CLAUDE_LOG'"

echo "== guards"
check "a token needs its permissions named" \
  "! (. lib/common.sh && . lib/github-app.sh && github_app_token piabrota/nix-os '{}') 2>/dev/null"
check "a missing Claude Code token is named, with where it comes from" \
  "{ CLAUDE_CODE_OAUTH_TOKEN= bin/agent health-digest 2>&1 || true; } | grep -q 'CLAUDE_CODE_OAUTH_TOKEN is not set (it comes from the Secret ax-tasks/agents'"
check "an unknown agent is refused" "! bin/agent nope 2>/dev/null"

echo
if [ "$fails" -ne 0 ]; then
  echo "$fails failed"
  exit 1
fi
echo "all passed"
