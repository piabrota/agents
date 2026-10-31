#!/usr/bin/env bash
# deploy-doctor: every failed run of $REPO's deploy workflow in the last $LOOKBACK_HOURS that has no
# issue yet gets one, and the pull request that the deploy came from gets a short comment pointing
# at it. Claude Code reads the failed jobs' logs and the repository at that commit and says what
# broke, whether re-running would fix it, and what to change if not. The harness holds it to that:
# known transient failures are matched by rule first (rules/transient.txt), the answer must fit
# prompts/deploy-doctor.schema.json, every quoted line must be in the file it names, every file
# must exist, and credentials are scrubbed before anything is posted. With no new failure it mints
# a token, reads two lists and exits, without calling Claude.
# shellcheck source=lib/common.sh
. "$AGENTS_HOME/lib/common.sh"
# shellcheck source=lib/github-app.sh
. "$AGENTS_HOME/lib/github-app.sh"

WORKFLOW=${WORKFLOW:-deploy.yml}
LOOKBACK_HOURS=${LOOKBACK_HOURS:-24}
LOG_LINES=${LOG_LINES:-400}
MODEL=${DEPLOY_DOCTOR_MODEL:-claude-sonnet-5-5}
PR_COMMENTS=${PR_COMMENTS:-1}
LABEL=deploy-failure

need CLAUDE_CODE_OAUTH_TOKEN
# Commenting on the deploy's pull request needs Pull requests write, which the App may not have
# yet: then the doctor still opens its issue, and says it skipped the comment.
if [ "$PR_COMMENTS" = 1 ] &&
  GH_TOKEN=$(github_app_token "$REPO" '{"actions":"read","contents":"read","issues":"write","pull_requests":"write"}' 2>/dev/null); then
  :
else
  [ "$PR_COMMENTS" = 1 ] && log "no pull_requests:write for piabrota-ops on $REPO: no comments on pull requests"
  PR_COMMENTS=0
  GH_TOKEN=$(github_app_token "$REPO" '{"actions":"read","contents":"read","issues":"write"}')
fi
export GH_TOKEN

since=$(date -u -d "-$LOOKBACK_HOURS hours" +%Y-%m-%dT%H:%M:%SZ)
runs=$(gh_api GET "repos/$REPO/actions/workflows/$WORKFLOW/runs?status=failure&per_page=20&created=%3E%3D$since" |
  jq -c '.workflow_runs[] | {id, head_sha, display_title, html_url, run_attempt, created_at, event}')
if [ -z "$runs" ]; then
  log "no failed $WORKFLOW run since $since"
  exit 0
fi
# Issue titles name their run, so a run is reported once whatever happens to its issue.
reported=$(gh_api GET "repos/$REPO/issues?labels=$LABEL&state=all&per_page=100" | jq -r '.[].title')

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

# fallback RUN_JSON RULE DIR: when no answer held up twice, what the harness knows without Claude.
fallback() {
  local run=$1 rule=$2 dir=$3
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

diagnose() {
  local run=$1 id sha dir jobs job rule result answer problems body title issue_url pr
  id=$(jq -r .id <<<"$run")
  sha=$(jq -r .head_sha <<<"$run")
  dir=$work/$id
  mkdir -p "$dir/logs"

  jobs=$(gh_api GET "repos/$REPO/actions/runs/$id/jobs?filter=latest" |
    jq -c '[.jobs[] | select(.conclusion == "failure")
      | {id, name, failed_steps: [.steps[] | select(.conclusion == "failure") | .name]}]')
  for job in $(jq -r '.[].id' <<<"$jobs"); do
    gh_download "repos/$REPO/actions/jobs/$job/logs" | tail -n "$LOG_LINES" >"$dir/logs/job-$job.log" ||
      log "run $id: could not read the log of job $job"
  done
  rule=$(match_rule "$dir")
  [ -n "$rule" ] && log "run $id: transient by rule $(jq -r .name <<<"$rule")"
  jq -n --argjson run "$run" --argjson jobs "$jobs" --arg lines "$LOG_LINES" --argjson rule "${rule:-null}" \
    '{run: $run, failed_jobs: $jobs, log_lines_kept: ($lines | tonumber)} + (if $rule then {rule: $rule} else {} end)' >"$dir/run.json"

  git clone -q --filter=blob:none --no-checkout "$REPO_GIT_URL" "$dir/repo"
  git -C "$dir/repo" checkout -q "$sha"

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
  else
    body=$(fallback "$run" "$rule" "$dir" | scrub)
  fi
  # shellcheck disable=SC2016 # the backticks are Markdown
  body=$(printf '%s\n\n---\n[Run %s](%s), commit `%s`; the last %s lines of each failed job and the repository at that commit.\n\n%s\n' \
    "$body" "$id" "$(jq -r .html_url <<<"$run")" "${sha:0:7}" "$LOG_LINES" "$(signature deploy-doctor "$result")")
  title="Deploy failed: run $id (${sha:0:7})"
  issue_url=$(gh_api POST "repos/$REPO/issues" \
    "$(jq -n --arg t "$title" --arg b "$body" --arg l "$LABEL" '{title: $t, body: $b, labels: [$l]}')" | jq -r .html_url)
  log "run $id: $issue_url"

  # The pull request that this deploy came from, if any (a deploy by hand has none).
  [ "$PR_COMMENTS" = 1 ] || return 0
  pr=$(gh_api GET "repos/$REPO/commits/$sha/pulls" | jq -r '[.[] | select(.merged_at != null)][0].number // empty')
  [ -n "$pr" ] || return 0
  gh_api POST "repos/$REPO/issues/$pr/comments" "$(jq -n --arg b "$(
    printf '**The deploy of this merge failed.** %s\n\n%s\n\nThe diagnosis, with its evidence: %s\n\n%s\n' \
      "$(head -1 <<<"$body" | sed 's/^## //')" \
      "$(grep -m1 '^\*\*What to do:\*\*' <<<"$body" || true)" \
      "$issue_url" "$(signature deploy-doctor "$result")"
  )" '{body: $b}')" >/dev/null
  log "run $id: commented on #$pr"
}

ensure_label "$LABEL" d73a4a "A failed deploy, diagnosed by piabrota/agents' deploy-doctor"
while IFS= read -r run; do
  id=$(jq -r .id <<<"$run")
  if grep -qF "run $id " <<<"$reported"; then
    log "run $id: already reported"
    continue
  fi
  diagnose "$run"
done <<<"$runs"
