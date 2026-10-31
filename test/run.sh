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
git init -q -b main "$tmp/nix-os"
mkdir -p "$tmp/nix-os/docs"
printf '# AGENTS.md\n' >"$tmp/nix-os/AGENTS.md"
printf '{ ... }: { }\n' >"$tmp/nix-os/kubesolo.nix"
printf '{ "nodes": {} }\n' >"$tmp/nix-os/flake.lock"
printf '# X\n\nThe old text.\n' >"$tmp/nix-os/docs/X.md"
printf '# X\n\nO texto antigo.\n' >"$tmp/nix-os/docs/X.ptBR.md"
git -C "$tmp/nix-os" add .
git -C "$tmp/nix-os" -c user.name=t -c user.email=t@t commit -q -m one
sha=$(git -C "$tmp/nix-os" rev-parse HEAD)
# A pull request's branch: a doc changed without its mirror, stateVersion touched, an agent trailer.
git -C "$tmp/nix-os" checkout -q -b feature
printf '# X\n\nThe new text, longer.\n' >"$tmp/nix-os/docs/X.md"
printf '{ ... }: { system.stateVersion = "26.05"; }\n' >"$tmp/nix-os/kubesolo.nix"
git -C "$tmp/nix-os" -c user.name=t -c user.email=t@t commit -q -am $'feat: x\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
feature=$(git -C "$tmp/nix-os" rev-parse HEAD)
git -C "$tmp/nix-os" checkout -q main
export REPO_PUSH_URL=$tmp/nix-os

# The App's key, as the env file holds it.
openssl genrsa -out "$tmp/app.pem" 2048 2>/dev/null
openssl rsa -in "$tmp/app.pem" -pubout -out "$tmp/app.pub" 2>/dev/null

export GH_APP_ID=123456 GH_APP_PRIVATE_KEY_B64
GH_APP_PRIVATE_KEY_B64=$(base64 -w0 <"$tmp/app.pem")
export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-test CLAUDE_BIN=$root/test/fake-claude
export REPO=piabrota/nix-os REPO_GIT_URL=$tmp/nix-os
export AX_TASK_YAML=$'spec:\n  image: ghcr.io/piabrota/agents@sha256:0123'
# The doctor's fix pull requests have their own scenarios below.
export FIX_PRS=0
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
      {id: 555, head_sha: $sha, head_branch: ($extra.branch // "main"), display_title: "feat: something", html_url: "https://github.com/piabrota/nix-os/actions/runs/555",
       run_attempt: 1, created_at: "2026-10-31T00:00:00Z", event: ($extra.event // "push"), conclusion: "failure"},
      {id: 554, head_sha: $sha, display_title: "fix: earlier", html_url: "https://github.com/piabrota/nix-os/actions/runs/554",
       run_attempt: 1, created_at: "2026-10-30T23:00:00Z", event: "push", conclusion: "success"}],
    jobs: {"555": [
      {id: 9, name: "deploy", conclusion: "failure", steps: [
        {name: "Build", conclusion: "success"}, {name: "Build and deploy", conclusion: "failure"}]},
      {id: 8, name: "build", conclusion: "success", steps: []}]},
    logs: {"9": $log},
    commit_pulls: [{number: 42, merged_at: "2026-10-31T00:00:00Z"}]
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
  export AGENTS_DB_URL=file://$tmp/mem-$port FAKE_CLAUDE_EDIT=
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
check "the token is for nix-os alone, asking first for what fixes need" \
  "sent '.path == \"/app/installations/7/access_tokens\" and .body == {repositories: [\"nix-os\"], permissions: {actions: \"read\", contents: \"write\", issues: \"write\", pull_requests: \"write\"}}'"
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
  "grep -qF 'token for piabrota/nix-os: {\"actions\":\"read\",\"contents\":\"read\",\"issues\":\"write\"}' '$tmp/err' && [ \"\$(posted issues | wc -l)\" -eq 1 ] && [ -z \"\$(posted issues/42/comments)\" ]"

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

# pr_json NUMBER HEAD_REF SHA LABELS_JSON BODY: a pull request as the API shows it, its files and
# patches from the fixture repository's real diff, and its commits.
pr_json() {
  local files commits
  files=$(for f in $(git -C "$tmp/nix-os" diff --name-only "main...$2"); do
    jq -nc --arg f "$f" --arg p "$(git -C "$tmp/nix-os" diff "main...$2" -- "$f" | sed -n '/^@@/,$p')" \
      '{filename: $f, status: "modified", additions: 1, deletions: 1, patch: $p}'
  done | jq -s .)
  commits=$(git -C "$tmp/nix-os" log --format='%H%x00%B%x00' "main..$2" | jq -Rs '[split("\u0000")[:-1] | _nwise(2) | {sha: .[0] | ltrimstr("\n"), commit: {message: .[1], author: {name: "h0ffmann"}}}]')
  jq -nc --argjson n "$1" --arg ref "$2" --arg sha "$3" --argjson labels "$4" --arg body "$5" --argjson files "$files" --argjson commits "$commits" \
    '{number: $n, state: "open", title: "feat: x", body: $body, user: {login: "h0ffmann"}, draft: false, labels: $labels,
      head: {ref: $ref, sha: $sha, repo: {full_name: "piabrota/nix-os"}}, base: {ref: "main"},
      html_url: "https://github.com/piabrota/nix-os/pull/\($n)", files: $files, commits: $commits}'
}
human() { # human ID ISSUE LOGIN ASSOCIATION BODY: a comment by a person
  jq -nc --argjson id "$1" --arg n "$2" --arg l "$3" --arg a "$4" --arg b "$5" \
    '{id: $id, body: $b, user: {login: $l, type: "User"}, author_association: $a, created_at: "2026-10-31T10:00:00Z",
      issue_url: "https://api.github.com/repos/piabrota/nix-os/issues/\($n)", reactions: {}}'
}

echo "== memory"
export AGENTS_DB_URL=file://$tmp/mem-unit
(
  . lib/common.sh
  . lib/memory.sh
  mem_log deploy-doctor feedback issue#1 '{"report": "said the network failed", "said": "it was the CPU reservation"}'
  mem_log deploy-doctor diagnosis run#1 '{"verdict": "real"}'
)
check "memory keeps events and reads them back by agent and kind" \
  "[ \"\$(. lib/common.sh; . lib/memory.sh; mem_recent deploy-doctor feedback 5 | jq -r '.[0].subject')\" = issue#1 ]"
check "lessons quote the report and what the person said" \
  "(. lib/common.sh; . lib/memory.sh; lessons deploy-doctor) | grep -q 'They said: it was the CPU reservation'"
check "without a store, memory is empty and quiet" \
  "[ \"\$(AGENTS_DB_URL= bash -c '. lib/common.sh; . lib/memory.sh; mem_recent x y 3')\" = '[]' ]"

scenario "feedback: a report labelled report-wrong and a 👎 become lessons, once" "$real_log" "$(jq -nc \
  --argjson c1 "$(human 501 30 h0ffmann OWNER 'The real cause was the CPU reservation.')" '{
  issues: [{number: 30, title: "Deploy failed: run 1 (abc1234)", state: "closed", labels: ["deploy-failure", "report-wrong"],
    user: {login: "piabrota-ops[bot]"}, body: "## Verdict: transient\n\n<sub>deploy-doctor · claude-sonnet-5-5</sub>"}],
  comments: {"30": [$c1], "31": [{id: 502, body: "**2026-10-31: OK**\n\n<sub>health-digest · claude-haiku-5-5</sub>",
    user: {login: "piabrota-ops[bot]", type: "Bot"}, author_association: "NONE", reactions: {"-1": 1},
    issue_url: "https://api.github.com/repos/piabrota/nix-os/issues/31"}]},
  reactions: {"502": [{content: "-1", user: {login: "h0ffmann"}}]}}')"
bin/agent feedback 2>"$tmp/err" || bad "it exits 0 ($(cat "$tmp/err"))"
bin/agent feedback 2>/dev/null
mem=${AGENTS_DB_URL#file://}/events.jsonl
check "the labelled issue is a lesson for deploy-doctor, with what the person said" \
  "jq -s -e 'any(.[]; .agent == \"deploy-doctor\" and .kind == \"feedback\" and .subject == \"issue#30\" and (.data.said | contains(\"CPU reservation\")))' '$mem' >/dev/null"
check "the 👎 on a digest is a lesson for health-digest" \
  "jq -s -e 'any(.[]; .agent == \"health-digest\" and .subject == \"comment#502\")' '$mem' >/dev/null"
check "each is recorded once, however often it runs" "[ \"\$(jq -c 'select(.kind == \"feedback\")' '$mem' | wc -l)\" -eq 2 ]"

fixer=$(jq -nc '{title_pt: "tira a reserva de CPU do KubeSolo", summary_pt: "O KubeSolo arredonda a reserva de CPU para cima; kubesolo.nix deixa de pedi-la.",
  summary_en: "KubeSolo rounds the CPU reservation up; kubesolo.nix stops asking for one.", commit_message: "fix(kubesolo): drop the CPU reservation\n\nIt stops KubeSolo on one vCPU."}')
ansi_log=$'building the system\n\e[31merror\e[0m: kubesolo[812]: --system-reserved cpu=300m reserves 1 of this host\'s 1 CPUs\nactivation failed, rolling back'
good_ansi=$(jq -c '.evidence[0].text = "error: kubesolo[812]: --system-reserved cpu=300m reserves 1 of this host'"'"'s 1 CPUs"' <<<"$good")

scenario "deploy-doctor: a real failure gets a fix pull request" "$ansi_log"
export FIX_PRS=1 FAKE_CLAUDE_EDIT='sed -i "s/{ }/{ services.kubesolo.cpu = null; }/" repo/kubesolo.nix'
answers "$good_ansi" "$fixer"
bin/agent deploy-doctor 2>"$tmp/err" || bad "it exits 0 ($(cat "$tmp/err"))"
check "colour codes are stripped before Claude reads the log, so the quote holds" \
  "! grep -q \$'\\e\\\\[' '$FAKE_CLAUDE_LOG' && grep -q 'error: kubesolo\\[812\\]' '$FAKE_CLAUDE_LOG' && ! grep -q 'rejected' '$tmp/err'"
check "the fixer ran second, with Edit and its lessons" \
  "[ \"\$(calls)\" -eq 2 ] && [ \"\$(argval --tools 2)\" = Read,Grep,Glob,Edit ] && grep -q './lessons.md' '$FAKE_CLAUDE_LOG'"
fixpr=$(posted pulls)
fixbranch=$(jq -r .head <<<"$fixpr")
check "a pull request from agents/deploy-doctor-run-555-<time> into main, titled in pt-BR" \
  "jq -e '(.head | test(\"^agents/deploy-doctor-run-555-[0-9]{14}$\")) and .base == \"main\" and .title == \"fix: tira a reserva de CPU do KubeSolo\"' <<<\"\$fixpr\" >/dev/null"
check "its body is a bipr, links the issue, and carries no signature" \
  "jq -e '.body | (contains(\"\n---\n\") and contains(\"Diagnóstico: #1\") and contains(\"Diagnosis: #1\") and (contains(\"<sub>\") | not))' <<<\"\$fixpr\" >/dev/null"
check "the branch holds one commit by the App's bot user, changing kubesolo.nix only" \
  "[ \"\$(git -C '$tmp/nix-os' log -1 --format='%an <%ae>' '$fixbranch')\" = 'piabrota-ops[bot] <4242+piabrota-ops[bot]@users.noreply.github.com>' ] && [ \"\$(git -C '$tmp/nix-os' diff --name-only main '$fixbranch')\" = kubesolo.nix ]"
check "the signature goes on the pull request as a comment, and the issue links it" \
  "posted issues/2/comments | jq -e '.body | contains(\"<sub>deploy-doctor\")' >/dev/null && posted issues/1/comments | jq -e '.body | contains(\"A fix is proposed in #2\")' >/dev/null"
check "memory has the diagnosis and the fix" \
  "jq -s -e 'any(.[]; .kind == \"fix\" and .subject == \"run#555\")' '${AGENTS_DB_URL#file://}/events.jsonl' >/dev/null"

scenario "deploy-doctor: a fix that touches flake.lock is rejected" "$real_log"
export FIX_PRS=1 FAKE_CLAUDE_EDIT='echo "{}" >repo/flake.lock'
answers "$good" "$fixer"
bin/agent deploy-doctor 2>"$tmp/err" || bad "it exits 0 ($(cat "$tmp/err"))"
check "no pull request, and the issue says why" \
  "[ -z \"\$(posted pulls)\" ] && posted issues/1/comments | jq -e '.body | contains(\"a file the fixer may not touch: flake.lock\")' >/dev/null"

scenario "deploy-doctor: without contents:write, no fix, the issue still comes" "$real_log" '{"deny_contents": true}'
export FIX_PRS=1
answers "$good" "$fixer"
bin/agent deploy-doctor 2>"$tmp/err" || bad "it exits 0 ($(cat "$tmp/err"))"
check "one Claude run, one issue, no pull request" "[ \"\$(calls)\" -eq 1 ] && [ \"\$(posted issues | wc -l)\" -eq 1 ] && [ -z \"\$(posted pulls)\" ]"

scenario "deploy-doctor: a drill's failure gets its fix against the drill branch, and no PR comment" "$real_log" '{"branch": "drill/typo", "event": "workflow_dispatch"}'
export FIX_PRS=1 FAKE_CLAUDE_EDIT='sed -i "s/{ }/{ services.kubesolo.cpu = null; }/" repo/kubesolo.nix'
answers "$good" "$fixer"
bin/agent deploy-doctor 2>"$tmp/err" || bad "it exits 0 ($(cat "$tmp/err"))"
check "the fix pull request's base is the drill branch" "posted pulls | jq -e '.base == \"drill/typo\"' >/dev/null"
check "no comment on the merged pull request: a drill has none" "[ -z \"\$(posted issues/42/comments)\" ]"
export FIX_PRS=0

review=$(jq -nc '{verdict: "attention", summary: "Turns on a stateVersion in kubesolo.nix.", findings: [
  {severity: "medium", file: "kubesolo.nix", quote: "{ ... }: { system.stateVersion = \"26.05\"; }", comment: "stateVersion belongs in configuration.nix, and must never change."}]}')
bad_review=$(jq -c '.findings[0].quote = "a line that is nowhere"' <<<"$review")

scenario "pr-reviewer: rules, a grounded review, one comment per head" "$real_log" "$(jq -nc --argjson p "$(pr_json 50 feature "$feature" '[]' $'Muda o doc.\n\nChanges the doc.')" '{prs: [$p]}')"
answers "$bad_review" "$review"
bin/agent pr-reviewer 2>"$tmp/err" || bad "it exits 0 ($(cat "$tmp/err"))"
rv=$(posted issues/50/comments | jq -r .body)
check "a quote that is not in the diff is rejected, and the second try holds" \
  "[ \"\$(calls)\" -eq 2 ] && grep -q 'is not in diff.patch or kubesolo.nix' '$tmp/err'"
check "the rules found the missing bipr, the agent trailer, the mirror, the closure line and stateVersion" \
  "grep -q '\*\*bipr\*\*' <<<\"\$rv\" && grep -q '\*\*no agent trail\*\*' <<<\"\$rv\" && grep -q 'docs/X.ptBR.md' <<<\"\$rv\" && grep -q '\*\*closure\*\*' <<<\"\$rv\" && grep -q '\*\*do not break the machine\*\*' <<<\"\$rv\""
check "the verdict is the rules' (changes-suggested), with the model's finding and its quote, signed" \
  "grep -q 'changes-suggested' <<<\"\$rv\" && grep -q 'stateVersion belongs in configuration.nix' <<<\"\$rv\" && grep -q 'sha=$feature' <<<\"\$rv\" && grep -q '<sub>pr-reviewer' <<<\"\$rv\""
: >"$FAKE_CLAUDE_LOG"
bin/agent pr-reviewer 2>"$tmp/err2"
check "the same head is not reviewed twice" "[ \"\$(calls)\" -eq 0 ] && grep -q 'already reviewed' '$tmp/err2'"
answers "$review"
REVIEW_PR=50 bin/agent pr-reviewer 2>/dev/null
check "a forced review edits the same comment" \
  "[ \"\$(posted issues/50/comments | wc -l)\" -eq 1 ] && sent '.method == \"PATCH\"'"

scenario "mentions: a trusted question gets one grounded answer; a stranger gets none" "$real_log" "$(jq -nc \
  --argjson q "$(human 701 60 h0ffmann OWNER '@piabrota-ops why is pgx enabled?')" \
  --argjson s "$(human 702 60 stranger NONE '@piabrota-ops write me a poem')" '{
  issues: [{number: 60, title: "PGX", state: "open", labels: [], user: {login: "h0ffmann"}, body: "Why do we run it?"}],
  comments: {"60": [$q, $s]}}')"
answers "$(jq -nc '{answer: "rax keeps its store in PGX.", confidence: "high", evidence: [{file: "thread.md", quote: "@piabrota-ops why is pgx enabled?"}]}')"
bin/agent mentions 2>"$tmp/err" || bad "it exits 0 ($(cat "$tmp/err"))"
replies=$(posted issues/60/comments)
check "one reply, to the trusted question, with its evidence and signature" \
  "[ \"\$(wc -l <<<\"\$replies\")\" -eq 1 ] && jq -e '.body | (contains(\"to=701 \") and contains(\"rax keeps its store in PGX.\") and contains(\"thread.md\") and contains(\"<sub>mentions\"))' <<<\"\$replies\" >/dev/null"
check "the stranger is not answered, and the log says why" "grep -q 'stranger, who is not trusted' '$tmp/err'"
: >"$FAKE_CLAUDE_LOG"
bin/agent mentions 2>/dev/null
check "a comment is answered once" "[ \"\$(calls)\" -eq 0 ] && [ \"\$(posted issues/60/comments | wc -l)\" -eq 1 ]"

scenario "mentions: \"review\" on a pull request reviews it now" "$real_log" "$(jq -nc \
  --argjson p "$(pr_json 50 feature "$feature" '[]' $'Muda.\n\n---\n\nChanges. Closure: none.')" \
  --argjson q "$(human 703 50 h0ffmann OWNER '@piabrota-ops review please')" '{prs: [$p], comments: {"50": [$q]}}')"
answers "$review"
bin/agent mentions 2>"$tmp/err" || bad "it exits 0 ($(cat "$tmp/err"))"
check "the review comment and the reply are both there" \
  "posted issues/50/comments | jq -s -e 'any(.[]; .body | contains(\"piabrota-ops:review\")) and any(.[]; .body | contains(\"Reviewed: the review comment above is up to date.\"))' >/dev/null"

scenario "mirror-keeper: a doc without its mirror gets a pull request into its branch" "$real_log" "$(jq -nc --argjson p "$(pr_json 50 feature "$feature" '[]' 'x')" '{prs: [$p]}')"
export FAKE_CLAUDE_EDIT='printf "# X\n\nO texto novo, mais longo.\n" >repo/docs/X.ptBR.md'
answers "$(jq -nc '{summary_pt: "docs/X.ptBR.md acompanha o texto novo.", summary_en: "docs/X.ptBR.md follows the new text."}')"
bin/agent mirror-keeper 2>"$tmp/err" || bad "it exits 0 ($(cat "$tmp/err"))"
mpr=$(posted pulls)
check "a pull request from agents/mirror-for-pr-50-<sha> into the pull request's branch" \
  "jq -e '.head == \"agents/mirror-for-pr-50-${feature:0:7}\" and .base == \"feature\" and .title == \"docs: espelho de docs/X.ptBR.md para o #50\" and (.body | contains(\"\n---\n\"))' <<<\"\$mpr\" >/dev/null"
check "its branch changes the mirror only" \
  "[ \"\$(git -C '$tmp/nix-os' diff --name-only feature 'agents/mirror-for-pr-50-${feature:0:7}')\" = docs/X.ptBR.md ]"
check "the pull request is told" "posted issues/50/comments | jq -e '.body | contains(\"brought up to date in #\")' >/dev/null"

scenario "mirror-keeper: a change beyond the mirrors is rejected" "$real_log" "$(jq -nc --argjson p "$(pr_json 50 feature "$feature" '[]' 'x')" '{prs: [$p]}')"
export FAKE_CLAUDE_EDIT='echo x >>repo/docs/X.ptBR.md; echo x >>repo/AGENTS.md'
answers "$(jq -nc '{summary_pt: "x", summary_en: "x"}')"
bin/agent mirror-keeper 2>"$tmp/err" || bad "it exits 0 ($(cat "$tmp/err"))"
check "no pull request" "[ -z \"\$(posted pulls)\" ] && grep -q 'mirror change rejected (other files: AGENTS.md' '$tmp/err'"

scenario "flake-annotator: a flake-update pull request gets its risk, once per head" "$real_log" "$(jq -nc \
  --argjson p "$(pr_json 51 feature "$feature" '["flake-update"]' 'dix: linux 6.18.54 -> 6.18.60')" '{prs: [$p]}')"
answers "$(jq -nc '{risk: "low", summary: "A kernel patch release.", watch: ["systemctl status kubesolo"]}')"
bin/agent flake-annotator 2>"$tmp/err" || bad "it exits 0 ($(cat "$tmp/err"))"
check "the comment has the risk, what to watch and the signature" \
  "posted issues/51/comments | jq -e '.body | (contains(\"Update risk: low\") and contains(\"- systemctl status kubesolo\") and contains(\"<sub>flake-annotator\"))' >/dev/null"
: >"$FAKE_CLAUDE_LOG"
bin/agent flake-annotator 2>/dev/null
check "not twice for the same head" "[ \"\$(calls)\" -eq 0 ]"

scenario "tick: every agent in turn; one that fails does not stop the rest" "$real_log"
check "a failing agent fails the tick, and the others ran" \
  "! TICK_AGENTS='missing-agent flake-annotator' bin/agent tick 2>'$tmp/err' && grep -q 'failed: missing-agent' '$tmp/err' && grep -q 'no open flake-update pull request' '$tmp/err'"

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
