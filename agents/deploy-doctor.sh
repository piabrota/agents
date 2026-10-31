#!/usr/bin/env bash
# deploy-doctor: every failed run of $REPO's deploy workflow in the last $LOOKBACK_HOURS that has no
# issue yet gets one; the pull request the deploy came from (a push to main) gets a short comment;
# and when the failure is in the change itself (verdict real), a fix pull request against the branch
# that failed. Claude Code reads the failed jobs' logs and the repository at that commit and says
# what broke; the harness holds it to rules: known transient failures matched first
# (rules/transient.txt), the answer in prompts/deploy-doctor.schema.json, every quoted line in the
# file it names, every file present, credentials scrubbed. A fix is a second run that may edit the
# repository; the harness checks its diff (size, paths, no secrets) before it pushes a branch, and
# never merges. FIX_RUN=<run id> runs only the fix for that run, as a mention asks. Deploys from a
# branch other than main (drills) build only and get no pull request comment.
# shellcheck source=lib/common.sh
. "$AGENTS_HOME/lib/common.sh"
# shellcheck source=lib/github-app.sh
. "$AGENTS_HOME/lib/github-app.sh"
# shellcheck source=lib/memory.sh
. "$AGENTS_HOME/lib/memory.sh"

WORKFLOW=${WORKFLOW:-deploy.yml}
LOOKBACK_HOURS=${LOOKBACK_HOURS:-24}
LOG_LINES=${LOG_LINES:-400}
MODEL=${DEPLOY_DOCTOR_MODEL:-claude-sonnet-5-5}
FIX_PRS=${FIX_PRS:-1}
MAX_FIX_FILES=${MAX_FIX_FILES:-5}
MAX_FIX_LINES=${MAX_FIX_LINES:-200}
LABEL=deploy-failure

need CLAUDE_CODE_OAUTH_TOKEN
# From the most this agent can use to the least: fix PRs need contents write, comments on pull
# requests need pull_requests write. Without them it still opens its issue.
mint_token \
  '{"actions":"read","contents":"write","issues":"write","pull_requests":"write"}' \
  '{"actions":"read","contents":"read","issues":"write","pull_requests":"write"}' \
  '{"actions":"read","contents":"read","issues":"write"}'
token_can contents || FIX_PRS=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# match_rule DIR: the first rule in rules/transient.txt that a failed job's log matches, as
# {name, line, file}, or nothing.
match_rule() {
  local dir=$1 name regex f line
  while IFS=$'\t' read -r name regex; do
    case "$name" in '' | '#'*) continue ;; esac
    for f in "$dir"/logs/*.log; do
      [ -f "$f" ] || continue
      line=$(grep -m1 -E -- "$regex" "$f" || true)
      if [ -n "$line" ]; then
        jq -nc --arg n "$name" --arg l "$line" --arg f "logs/${f##*/}" '{name: $n, line: $l, file: $f}'
        return
      fi
    done
  done <"$AGENTS_HOME/rules/transient.txt"
}

# check_answer DIR ANSWER: layer 3. Prints what is wrong, one line each; nothing if it holds.
check_answer() {
  local dir=$1 answer=$2 ev file text f
  while IFS= read -r ev; do
    [ -n "$ev" ] || continue
    file=$(jq -r .file <<<"$ev")
    text=$(jq -r .text <<<"$ev")
    case "$file" in *..*) echo "evidence file $file leaves the inputs" && continue ;; esac
    if [ ! -f "$dir/$file" ]; then
      echo "evidence file $file does not exist"
    elif ! grep -qF -- "$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"$text")" "$dir/$file"; then
      echo "evidence \"${text:0:80}\" is not in $file: copy lines exactly"
    fi
  done < <(jq -c '.evidence[]?' <<<"$answer")
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in *..*) echo "file $f leaves the repository" && continue ;; esac
    [ -e "$dir/repo/${f#repo/}" ] || echo "file $f does not exist in the repository"
  done < <(jq -r '.files[]?' <<<"$answer")
}

# render ANSWER RULE: the issue's Markdown, from the checked answer; the rule fixes the verdict.
render() {
  local answer=$1 rule=$2
  jq -r --argjson rule "${rule:-null}" '
    (if $rule then "transient" else .verdict end) as $v
    | "## Verdict: \($v)"
      + (if $rule then " (rule `\($rule.name)`)" else "" end)
      + "\n\n**What failed:** \(.failed_step): \(.error)\n\n**Why:** \(.cause)\n\n**Evidence**, checked against the files:\n\n"
      + ([.evidence[] | "`\(.file)`\n```text\n\(.text)\n```"] | join("\n"))
      + "\n\n**What to do:** \(.fix)"
      + (if (.files | length) > 0 then "\n\n**Files:** " + ([.files[] | "`\(.)`"] | join(", ")) else "" end)' <<<"$answer"
}

# fallback DIR RULE: when no answer held up twice, what the harness knows without Claude.
fallback() {
  local dir=$1 rule=$2 f
  printf '## Verdict: %s\n\n' "$([ -n "$rule" ] && echo "transient (rule \`$(jq -r .name <<<"$rule")\`)" || echo unclear)"
  printf '**What failed:** %s\n\n' "$(jq -r '[.failed_jobs[] | "\(.name): \(.failed_steps | join(", "))"] | join("; ")' "$dir/run.json")"
  printf 'The diagnosis did not pass the harness'"'"'s checks twice, so this issue has only the facts. The last lines of the failed jobs:\n\n'
  for f in "$dir"/logs/*.log; do
    # shellcheck disable=SC2016 # the backticks are Markdown
    [ -f "$f" ] && printf '`logs/%s`\n```text\n%s\n```\n' "${f##*/}" "$(tail -n 15 "$f")"
  done
  [ -n "$rule" ] && printf '\n**What to do:** Re-run the failed jobs.\n'
  true
}

# gather RUN_JSON: the run's failed jobs' logs (without colour codes), the rule they match, and the
# repository at its commit, in a directory of their own. Prints the directory.
gather() {
  local run=$1 id sha dir jobs job rule
  id=$(jq -r .id <<<"$run")
  sha=$(jq -r .head_sha <<<"$run")
  dir=$work/$id
  mkdir -p "$dir/logs"
  jobs=$(gh_api GET "repos/$REPO/actions/runs/$id/jobs?filter=latest" |
    jq -c '[.jobs[] | select(.conclusion == "failure")
      | {id, name, failed_steps: [.steps[] | select(.conclusion == "failure") | .name]}]')
  for job in $(jq -r '.[].id' <<<"$jobs"); do
    gh_download "repos/$REPO/actions/jobs/$job/logs" | strip_ansi | tail -n "$LOG_LINES" >"$dir/logs/job-$job.log" ||
      log "run $id: could not read the log of job $job"
  done
  rule=$(match_rule "$dir")
  [ -n "$rule" ] && log "run $id: transient by rule $(jq -r .name <<<"$rule")"
  jq -n --argjson run "$run" --argjson jobs "$jobs" --arg lines "$LOG_LINES" --argjson rule "${rule:-null}" \
    '{run: $run, failed_jobs: $jobs, log_lines_kept: ($lines | tonumber)} + (if $rule then {rule: $rule} else {} end)' >"$dir/run.json"
  git clone -q --filter=blob:none --no-checkout "$REPO_GIT_URL" "$dir/repo"
  git -C "$dir/repo" checkout -q "$sha"
  lessons deploy-doctor >"$dir/lessons.md"
  printf '%s' "$dir"
}

# check_fix REPO_DIR: the harness's rules for a fix's diff. Prints what is wrong, one line each.
check_fix() {
  local repo=$1 files n lines diff
  git -C "$repo" add -A
  files=$(git -C "$repo" diff --cached --name-only)
  if [ -z "$files" ]; then
    echo "no change"
    return
  fi
  n=$(wc -l <<<"$files")
  [ "$n" -le "$MAX_FIX_FILES" ] || echo "$n files changed: at most $MAX_FIX_FILES"
  lines=$(git -C "$repo" diff --cached --numstat | awk '{s += $1 + $2} END {print s + 0}')
  [ "$lines" -le "$MAX_FIX_LINES" ] || echo "$lines lines changed: at most $MAX_FIX_LINES"
  grep -E '^(\.github/workflows/|keys/|flake\.lock$|.*\.(age|pem|key)$)' <<<"$files" | sed 's/^/a file the fixer may not touch: /'
  diff=$(git -C "$repo" diff --cached)
  grep -qE '^[-+].*stateVersion' <<<"$diff" && echo "system.stateVersion must never change"
  [ "$(scrub <<<"$diff")" = "$diff" ] || echo "the diff holds something shaped like a credential"
  true
}

# fix DIR ISSUE_NUMBER: a second run that may edit repo/, then a branch and a pull request if the
# harness accepts the diff. The base is the branch that failed: main, or a drill's branch.
fix() {
  local dir=$1 issue=$2 run id sha base branch result answer problems title body pr
  run=$(jq -c .run "$dir/run.json")
  id=$(jq -r .id <<<"$run")
  sha=$(jq -r .head_sha <<<"$run")
  base=$(jq -r '.head_branch // "main"' <<<"$run")
  # A new branch each time: a fix asked for again (a mention) never collides with an earlier one.
  branch="agents/deploy-doctor-run-$id-$(date -u +%Y%m%d%H%M%S)"
  git -C "$dir/repo" checkout -q -b "$branch"
  log "run $id: proposing a fix with $MODEL"
  result=$(cd "$dir" && claude_json "$MODEL" "$AGENTS_HOME/prompts/deploy-fixer.md" "Read,Grep,Glob,Edit" \
    "$AGENTS_HOME/prompts/deploy-fixer.schema.json") || result='{"is_error": true}'
  answer=$(answer_of "$result")
  if [ -z "$answer" ] || [ -n "$(jq -r '.no_fix_reason // empty' <<<"$answer")" ]; then
    log "run $id: no fix: $(jq -r '.no_fix_reason // "no answer that fits the schema"' <<<"${answer:-{\}}")"
    gh_api POST "repos/$REPO/issues/$issue/comments" "$(jq -n --arg b "$(printf 'No fix proposed: %s\n\n%s\n' \
      "$(jq -r '.no_fix_reason // "the fixer gave no answer that fits its schema"' <<<"${answer:-{\}}" | scrub)" \
      "$(signature deploy-doctor "$result")")" '{body: $b}')" >/dev/null
    return 0
  fi
  problems=$(check_fix "$dir/repo")
  if [ -n "$problems" ]; then
    log "run $id: fix rejected: $(tr '\n' ';' <<<"$problems")"
    gh_api POST "repos/$REPO/issues/$issue/comments" "$(jq -n --arg b "$(printf 'A fix was drafted but the harness rejected it, so there is no pull request:\n\n%s\n\n%s\n' \
      "$(while IFS= read -r p; do printf -- '- %s\n' "$p"; done <<<"$problems")" "$(signature deploy-doctor "$result")")" '{body: $b}')" >/dev/null
    return 0
  fi
  bot_identity
  git -C "$dir/repo" commit -q -m "$(jq -r .commit_message <<<"$answer")"
  push_branch "$dir/repo" "$branch"
  title="fix: $(jq -r .title_pt <<<"$answer")"
  # A bipr body, pt-BR first and its English mirror after the rule; the signature goes in a comment.
  body=$(jq -r --arg i "$issue" --arg run "$id" --arg url "$(jq -r .html_url <<<"$run")" --arg sha "${sha:0:7}" '
    "\(.summary_pt)\n\nDiagnóstico: #\($i) ([run \($run)](\($url)), commit `\($sha)`). Proposto pelo piabrota-ops: confira, deixe a CI rodar e só faça o merge se estiver certo.\n\n---\n\n\(.summary_en)\n\nDiagnosis: #\($i) ([run \($run)](\($url)), commit `\($sha)`). Proposed by piabrota-ops: check it, let CI run, and merge only if it is right."' <<<"$answer" | scrub)
  pr=$(gh_api POST "repos/$REPO/pulls" "$(jq -n --arg t "$title" --arg b "$body" --arg h "$branch" --arg base "$base" \
    '{title: $t, body: $b, head: $h, base: $base}')" | jq -r '.number')
  upsert_comment "$pr" "<!-- piabrota-ops:fix -->" "$(printf '<!-- piabrota-ops:fix -->\nThe fix for #%s, checked by the harness (%s).\n\n%s\n' \
    "$issue" "$(git -C "$dir/repo" diff --stat HEAD~1 | tail -1 | sed 's/^ *//')" "$(signature deploy-doctor "$result")")" >/dev/null
  gh_api POST "repos/$REPO/issues/$issue/comments" "$(jq -n --arg b "$(printf 'A fix is proposed in #%s.\n\n%s\n' "$pr" "$(signature deploy-doctor "$result")")" '{body: $b}')" >/dev/null
  mem_log deploy-doctor fix "run#$id" "$(jq -n --arg pr "$pr" --argjson a "$answer" '{pr: $pr, title: $a.title_pt}')"
  log "run $id: fix pull request #$pr against $base"
}

diagnose() {
  local run=$1 id sha dir rule result answer problems body title issue issue_url verdict pr
  id=$(jq -r .id <<<"$run")
  sha=$(jq -r .head_sha <<<"$run")
  dir=$(gather "$run")
  rule=$(jq -c '.rule // empty' "$dir/run.json")

  # Two tries: the second one is told what the harness rejected.
  problems=
  for try in 1 2; do
    log "run $id: diagnosing with $MODEL (try $try)"
    result=$(cd "$dir" && claude_json "$MODEL" "$AGENTS_HOME/prompts/deploy-doctor.md" "Read,Grep,Glob" \
      "$AGENTS_HOME/prompts/deploy-doctor.schema.json" "$problems") || result='{"is_error": true}'
    answer=$(answer_of "$result")
    if [ -z "$answer" ]; then
      problems="the answer was missing or did not fit the schema"
    else
      problems=$(check_answer "$dir" "$answer")
    fi
    [ -z "$problems" ] && break
    log "run $id: try $try rejected: $(tr '\n' ';' <<<"$problems")"
  done

  if [ -z "$problems" ]; then
    body=$(render "$answer" "$rule" | scrub)
    if [ -n "$rule" ]; then verdict=transient; else verdict=$(jq -r .verdict <<<"$answer"); fi
  else
    body=$(fallback "$dir" "$rule" | scrub)
    verdict=unclear
  fi
  printf '%s\n' "$body" >"$dir/diagnosis.md"
  # shellcheck disable=SC2016 # the backticks are Markdown
  body=$(printf '%s\n\n---\n[Run %s](%s), commit `%s`; the last %s lines of each failed job and the repository at that commit.\n\n%s\n' \
    "$body" "$id" "$(jq -r .html_url <<<"$run")" "${sha:0:7}" "$LOG_LINES" "$(signature deploy-doctor "$result")")
  title="Deploy failed: run $id (${sha:0:7})"
  issue=$(gh_api POST "repos/$REPO/issues" \
    "$(jq -n --arg t "$title" --arg b "$body" --arg l "$LABEL" '{title: $t, body: $b, labels: [$l]}')")
  issue_url=$(jq -r .html_url <<<"$issue")
  log "run $id: $issue_url"
  mem_log deploy-doctor diagnosis "run#$id" "$(jq -n --arg v "$verdict" --arg i "$issue_url" --arg b "$(head -c 1500 "$dir/diagnosis.md")" '{verdict: $v, issue: $i, summary: $b}')"

  # The pull request this deploy came from: only a push to main has one.
  if token_can pull_requests && [ "$(jq -r '.event // ""' <<<"$run")" = push ]; then
    pr=$(gh_api GET "repos/$REPO/commits/$sha/pulls" | jq -r '[.[] | select(.merged_at != null)][0].number // empty')
    if [ -n "$pr" ]; then
      gh_api POST "repos/$REPO/issues/$pr/comments" "$(jq -n --arg b "$(
        printf '**The deploy of this merge failed.** %s\n\n%s\n\nThe diagnosis, with its evidence: %s\n\n%s\n' \
          "$(head -1 <<<"$body" | sed 's/^## //')" \
          "$(grep -m1 '^\*\*What to do:\*\*' <<<"$body" || true)" \
          "$issue_url" "$(signature deploy-doctor "$result")"
      )" '{body: $b}')" >/dev/null
      log "run $id: commented on #$pr"
    fi
  fi

  if [ "$verdict" = real ] && [ "$FIX_PRS" = 1 ]; then
    fix "$dir" "$(jq -r .number <<<"$issue")"
  fi
}

ensure_label "$LABEL" d73a4a "A failed deploy, diagnosed by piabrota/agents' deploy-doctor"
# Issue titles name their run, so a run is reported once whatever happens to its issue.
reported=$(gh_api GET "repos/$REPO/issues?labels=$LABEL&state=all&per_page=100" | jq -c '.[] | {number, title}')

if [ -n "${FIX_RUN:-}" ]; then
  [ "$FIX_PRS" = 1 ] || die "a fix needs contents:write for piabrota-ops on $REPO"
  run=$(gh_api GET "repos/$REPO/actions/runs/$FIX_RUN" |
    jq -c '{id, head_sha, head_branch, display_title, html_url, run_attempt, created_at, event}')
  issue=$(jq -r --arg id "$FIX_RUN" 'select(.title | contains("run \($id) ")) | .number' <<<"$reported" | head -1)
  [ -n "$issue" ] || die "run $FIX_RUN has no deploy-failure issue to fix from"
  dir=$(gather "$run")
  gh_api GET "repos/$REPO/issues/$issue" | jq -r .body >"$dir/diagnosis.md"
  fix "$dir" "$issue"
  exit 0
fi

since=$(date -u -d "-$LOOKBACK_HOURS hours" +%Y-%m-%dT%H:%M:%SZ)
runs=$(gh_api GET "repos/$REPO/actions/workflows/$WORKFLOW/runs?status=failure&per_page=20&created=%3E%3D$since" |
  jq -c '.workflow_runs[] | {id, head_sha, head_branch, display_title, html_url, run_attempt, created_at, event}')
if [ -z "$runs" ]; then
  log "no failed $WORKFLOW run since $since"
  exit 0
fi
while IFS= read -r run; do
  id=$(jq -r .id <<<"$run")
  if grep -qF "run $id " <<<"$reported"; then
    log "run $id: already reported"
    continue
  fi
  diagnose "$run"
done <<<"$runs"
