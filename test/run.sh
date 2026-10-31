#!/usr/bin/env bash
# The checks are strings that check() evals, so shellcheck sees their variables as unused.
# shellcheck disable=SC2034
# The agents against a fake GitHub (test/fake_github.py) and a fake claude (test/fake-claude): what
# they ask GitHub for, what Claude Code is given and allowed, what the harness accepts, rejects and
# rewrites, and what is posted. Needs bash, curl, jq, openssl, git and python3; no network, no
# secrets. Each scenario has its own fake GitHub.
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
# posted PATH: the bodies POSTed to PATH, one JSON per line.
posted() { jq -c --arg p "/repos/piabrota/nix-os/$1" 'select(.method == "POST" and .path == $p) | .body' "$requests"; }
# argval FLAG [CALL]: the value the fake claude got for FLAG, on its CALLth run (default 1).
argval() {
  awk -v f="arg: $1" -v c="${2:-1}" '/^call$/ {n++} n == c && $0 == f {getline; sub(/^arg: /, ""); print; exit}' "$FAKE_CLAUDE_LOG"
}
calls() { grep -c '^call$' "$FAKE_CLAUDE_LOG" || true; }

# The repository at the commit that failed, served as a local git URL.
git init -q "$tmp/nix-os"
printf '# AGENTS.md\n' >"$tmp/nix-os/AGENTS.md"
printf '{ ... }: { }\n' >"$tmp/nix-os/kubesolo.nix"
git -C "$tmp/nix-os" add .
git -C "$tmp/nix-os" -c user.name=t -c user.email=t@t commit -q -m one
sha=$(git -C "$tmp/nix-os" rev-parse HEAD)

# The App's key, as the env file holds it.
openssl genrsa -out "$tmp/app.pem" 2048 2>/dev/null
openssl rsa -in "$tmp/app.pem" -pubout -out "$tmp/app.pub" 2>/dev/null

export GH_APP_ID=123456 GH_APP_PRIVATE_KEY_B64
GH_APP_PRIVATE_KEY_B64=$(base64 -w0 <"$tmp/app.pem")
export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-test CLAUDE_BIN=$root/test/fake-claude
export REPO=piabrota/nix-os REPO_GIT_URL=$tmp/nix-os
export AX_TASK_YAML=$'spec:\n  image: ghcr.io/piabrota/agents@sha256:0123'
real_log=$'building the system\nerror: kubesolo[812]: --system-reserved cpu=300m reserves 1 of this host\'s 1 CPUs\nactivation failed, rolling back'
ssh_log=$'line one\nssh: connect to host *** port 22: Connection timed out'

port=18760
# scenario NAME LOG [EXTRA_STATE_JSON]: a fresh fake GitHub with one failed deploy (run 555, job 9
# with LOG) from pull request 42, and an empty claude log.
scenario() {
  echo "== $1"
  port=$((port + 1))
  jq -n --arg sha "$sha" --arg log "$2" --argjson extra "${3:-{\}}" '{
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
    logs: {"9": $log},
    pulls: [{number: 42, merged_at: "2026-10-31T00:00:00Z"}]
  } + $extra' >"$tmp/state-$port.json"
  requests=$tmp/requests-$port.jsonl
  : >"$requests"
  python3 test/fake_github.py "$port" "$tmp/state-$port.json" "$requests" &
  pids+=($!)
  export GITHUB_API=http://127.0.0.1:$port
  for _ in $(seq 50); do
    curl -s "$GITHUB_API/" >/dev/null && break
    sleep 0.1
  done
  export FAKE_CLAUDE_LOG=$tmp/claude-$port.log FAKE_CLAUDE_ANSWERS=$tmp/answers-$port.jsonl
  : >"$FAKE_CLAUDE_LOG"
  : >"$FAKE_CLAUDE_ANSWERS"
}
answers() { printf '%s\n' "$@" >"$FAKE_CLAUDE_ANSWERS"; }

good=$(jq -nc '{verdict: "real", failed_step: "Build and deploy",
  error: "KubeSolo refused to start with a CPU reservation on one vCPU.",
  evidence: [{file: "logs/job-9.log", text: "error: kubesolo[812]: --system-reserved cpu=300m reserves 1 of this host'"'"'s 1 CPUs"}],
  cause: "systemReserved.cpu is rounded up to a whole CPU.", fix: "Drop the cpu entry in kubesolo.nix.", files: ["kubesolo.nix"]}')

scenario "deploy-doctor: a real failure, answered well the first time" "$real_log"
answers "$good"
bin/agent deploy-doctor 2>"$tmp/err" || bad "it exits 0 ($(cat "$tmp/err"))"
jwt=$(jq -r 'select(.path == "/repos/piabrota/nix-os/installation") | .auth' "$requests" | head -1 | sed 's/^Bearer //')
IFS=. read -r h p s <<<"$jwt"
unb64() {
  local x=$1
  x=$(tr '_-' '/+' <<<"$x")
  while [ $((${#x} % 4)) -ne 0 ]; do x+="="; done
  base64 -d <<<"$x"
}
unb64 "$s" >"$tmp/sig"
check "the App's JWT is signed with its key and issued by its ID" \
  "printf '%s.%s' '$h' '$p' | openssl dgst -sha256 -verify '$tmp/app.pub' -signature '$tmp/sig' >/dev/null && [ \"\$(unb64 '$p' | jq -r .iss)\" = 123456 ]"
check "the token is for nix-os alone, with what the doctor needs and pull requests to comment on" \
  "sent '.path == \"/app/installations/7/access_tokens\" and .body == {repositories: [\"nix-os\"], permissions: {actions: \"read\", contents: \"read\", issues: \"write\", pull_requests: \"write\"}}'"
check "later calls carry the installation token, not the JWT" \
  "jq -s -e 'map(select(.path | startswith(\"/repos/piabrota/nix-os/issues\"))) | length > 0 and all(.auth == \"Bearer ghs_fake\")' '$requests' >/dev/null"
check "layer 1: --restricted, only Read, Grep and Glob, no MCP, a pinned model" \
  "grep -qx 'arg: --restricted' '$FAKE_CLAUDE_LOG' && [ \"\$(argval --tools)\" = Read,Grep,Glob ] && grep -qx 'arg: --strict-mcp-config' '$FAKE_CLAUDE_LOG' && [ \"\$(argval --model)\" = claude-sonnet-5-5 ]"
check "layer 2: the schema and the house rules go with the run" \
  "[ \"\$(argval --json-schema)\" = \"\$(jq -c . prompts/deploy-doctor.schema.json)\" ] && argval --append-system-prompt | grep -q 'Rules for every piabrota agent'"
check "Claude Code got the run, only the failed job's log, and the repository" \
  "grep -q './run.json' '$FAKE_CLAUDE_LOG' && grep -q './logs/job-9.log' '$FAKE_CLAUDE_LOG' && ! grep -q './logs/job-8.log' '$FAKE_CLAUDE_LOG' && grep -q './repo/kubesolo.nix' '$FAKE_CLAUDE_LOG'"
issue=$(posted issues)
check "one issue, titled with the run and the commit" \
  "[ \"\$(wc -l <<<\"\$issue\")\" -eq 1 ] && jq -e '.title == \"Deploy failed: run 555 (${sha:0:7})\" and .labels == [\"deploy-failure\"]' <<<\"\$issue\" >/dev/null"
body=$(jq -r .body <<<"$issue")
check "its body is rendered from the answer: verdict, evidence as quoted, files" \
  "grep -qx '## Verdict: real' <<<\"\$body\" && grep -qF 'reserves 1 of this host' <<<\"\$body\" && grep -qF '**Files:** \`kubesolo.nix\`' <<<\"\$body\" && grep -qF 'actions/runs/555' <<<\"\$body\""
check "it is signed: agent, model, Claude Code's version, turns, user, OS, machine, image" \
  "grep -E '^<sub>deploy-doctor · claude-sonnet-5-5 via Claude Code 2.1.316 · 3 turns, 41s · as [^ ]+ \\(uid [0-9]+\\) in .* vCPU.* RAM.* · ghcr.io/piabrota/agents@sha256:0123</sub>$' <<<\"\$body\" >/dev/null"
pr=$(posted issues/42/comments)
check "the merged pull request gets a comment: verdict, what to do, the issue, the signature" \
  "jq -e '.body | (contains(\"Verdict: real\") and contains(\"Drop the cpu entry\") and contains(\"/issues/1\") and contains(\"<sub>deploy-doctor\"))' <<<\"\$pr\" >/dev/null"
: >"$FAKE_CLAUDE_LOG"
bin/agent deploy-doctor 2>"$tmp/err2"
check "run again: the run is not reported twice, and Claude Code is not called" \
  "[ \"\$(posted issues | wc -l)\" -eq 1 ] && [ \"\$(calls)\" -eq 0 ] && grep -q 'run 555: already reported' '$tmp/err2'"

scenario "deploy-doctor: evidence that is not in the log is rejected, and the second try holds" "$real_log"
answers "$(jq -c '.evidence[0].text = "error: something that never happened"' <<<"$good")" "$good"
bin/agent deploy-doctor 2>"$tmp/err" || bad "it exits 0 ($(cat "$tmp/err"))"
check "Claude Code ran twice" "[ \"\$(calls)\" -eq 2 ]"
check "the second try was told what the harness rejected" \
  "grep -q 'rejected by the harness' '$FAKE_CLAUDE_LOG' && grep -q 'is not in logs/job-9.log: copy lines exactly' '$FAKE_CLAUDE_LOG'"
check "the issue has the second, checked answer" "posted issues | jq -e '.body | contains(\"reserves 1 of this host\")' >/dev/null"

scenario "deploy-doctor: a file that does not exist, twice, gives the facts without the diagnosis" "$real_log"
bad_file=$(jq -c '.files = ["nope.nix"]' <<<"$good")
answers "$bad_file" "$bad_file"
bin/agent deploy-doctor 2>"$tmp/err" || bad "it exits 0 ($(cat "$tmp/err"))"
check "the harness named the missing file" "grep -q 'file nope.nix does not exist' '$tmp/err'"
fb=$(posted issues | jq -r .body)
check "the issue says unclear, that the checks failed, and quotes the log itself" \
  "grep -qx '## Verdict: unclear' <<<\"\$fb\" && grep -q 'did not pass the harness' <<<\"\$fb\" && grep -qF 'activation failed, rolling back' <<<\"\$fb\" && ! grep -q 'rounded up' <<<\"\$fb\""

scenario "deploy-doctor: a known transient failure keeps its verdict whatever Claude says" "$ssh_log"
answers "$(jq -c '.evidence = [{file: "logs/job-9.log", text: "ssh: connect to host *** port 22: Connection timed out"}] | .files = []' <<<"$good")"
bin/agent deploy-doctor 2>"$tmp/err" || bad "it exits 0 ($(cat "$tmp/err"))"
check "the rule matched before Claude ran" "grep -q 'transient by rule ssh-timeout' '$tmp/err'"
check "the verdict is transient, by rule, though the answer said real" \
  "posted issues | jq -r .body | grep -qx '## Verdict: transient (rule \`ssh-timeout\`)'"

scenario "deploy-doctor: credentials in the answer are scrubbed" "$real_log"
answers "$(jq -c '.cause = "It used ghs_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123 and sk-ant-oat01-abcdefghijklmnop to log in."' <<<"$good")"
bin/agent deploy-doctor 2>"$tmp/err" || bad "it exits 0 ($(cat "$tmp/err"))"
check "neither token reaches GitHub" \
  "! grep -qE 'ghs_ABCDEF|sk-ant-oat01-abcdef' '$requests' && posted issues | jq -r .body | grep -q 'It used \[redacted\] and \[redacted\] to log in.'"

scenario "deploy-doctor: without pull_requests on the App, the issue still comes" "$real_log" '{"deny_pull_requests": true}'
answers "$good"
bin/agent deploy-doctor 2>"$tmp/err" || bad "it exits 0 ($(cat "$tmp/err"))"
check "it says why, opens the issue, and comments on no pull request" \
  "grep -q 'no pull_requests:write' '$tmp/err' && [ \"\$(posted issues | wc -l)\" -eq 1 ] && [ -z \"\$(posted issues/42/comments)\" ]"

digest=$(jq -nc '{date: "2026-10-31", status: "OK", reason: "all active", services: "All active.",
  memory_and_disk: "965 MiB of 3.8 GiB; 5.1 GiB of 50 GiB.", kubernetes: "2 pods, no restarts.",
  deploys: "One, passed.", errors: "None.", watch: ""}')
printf '# snapshot 2026-10-31\nmemory: 965 MiB used\n' >"$tmp/snapshot.md"
export HEALTH_SNAPSHOT_FILE=$tmp/snapshot.md

scenario "health-digest: the first day, then the next" "$real_log"
answers "$digest" "$(jq -c '.date = "2026-11-01"' <<<"$digest")"
bin/agent health-digest 2>"$tmp/err" || bad "it exits 0 ($(cat "$tmp/err"))"
check "the token asks for actions:read and issues:write only" \
  "sent '.path == \"/app/installations/7/access_tokens\" and .body.permissions == {actions: \"read\", issues: \"write\"}'"
check "Claude Code ran with Read only, the digest's schema, on haiku" \
  "[ \"\$(argval --tools)\" = Read ] && [ \"\$(argval --json-schema)\" = \"\$(jq -c . prompts/health-digest.schema.json)\" ] && [ \"\$(argval --model)\" = claude-haiku-5-5 ]"
check "the digest issue is opened, labelled" \
  "posted issues | jq -e 'select(.title == \"VPS health digest\") | .labels == [\"health-digest\"]' >/dev/null"
c=$(posted issues/1/comments | jq -r .body)
check "the comment is rendered from the answer, without an empty Watch line, and signed" \
  "grep -qx '\*\*2026-10-31: OK\*\*, all active' <<<\"\$c\" && grep -qF -- '- **Memory and disk:** 965 MiB' <<<\"\$c\" && ! grep -q Watch <<<\"\$c\" && grep -q '^<sub>health-digest · ' <<<\"\$c\""
bin/agent health-digest 2>"$tmp/err2"
check "the next day reuses the issue and sees yesterday's digest" \
  "[ \"\$(posted issues | wc -l)\" -eq 1 ] && grep -q '2026-10-31: OK' '$FAKE_CLAUDE_LOG'"

scenario "health-digest: no answer that fits, twice, posts nothing" "$real_log"
answers error error
check "it fails, saying so" "! bin/agent health-digest 2>'$tmp/err' && grep -q 'no digest that fits the schema, twice' '$tmp/err'"
check "and no comment is posted" "[ -z \"\$(posted issues/1/comments)\" ]"

echo "== guards"
check "a token needs its permissions named" \
  "! (. lib/common.sh && . lib/github-app.sh && github_app_token piabrota/nix-os '{}') 2>/dev/null"
check "a missing Claude Code token is named, with where it comes from" \
  "{ CLAUDE_CODE_OAUTH_TOKEN= bin/agent health-digest 2>&1 || true; } | grep -q 'CLAUDE_CODE_OAUTH_TOKEN is not set (it comes from the Secret ax-tasks/agents'"
check "an unknown agent is refused" "! bin/agent nope 2>/dev/null"
bad_rules=0
while IFS=$'\t' read -r _ r; do
  rc=0
  grep -qE -- "$r" /dev/null || rc=$?
  [ "$rc" -le 1 ] || bad_rules=1
done < <(grep -v '^#' rules/transient.txt) || true
check "every rule in rules/transient.txt is a valid regular expression" "[ $bad_rules -eq 0 ]"

echo
if [ "$fails" -ne 0 ]; then
  echo "$fails failed"
  exit 1
fi
echo "all passed"
