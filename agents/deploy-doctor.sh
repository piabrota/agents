#!/usr/bin/env bash
# deploy-doctor: every failed run of $REPO's deploy workflow in the last $LOOKBACK_HOURS that has no
# issue yet gets one. Claude Code reads the failed jobs' logs and the repository at that commit and
# says what broke, whether re-running would fix it, and what to change if not. Run often: with no
# new failure it mints a token, reads two lists and exits, without calling Claude.
# shellcheck source=lib/common.sh
. "$AGENTS_HOME/lib/common.sh"
# shellcheck source=lib/github-app.sh
. "$AGENTS_HOME/lib/github-app.sh"

WORKFLOW=${WORKFLOW:-deploy.yml}
LOOKBACK_HOURS=${LOOKBACK_HOURS:-24}
LOG_LINES=${LOG_LINES:-400}
MODEL=${DEPLOY_DOCTOR_MODEL:-sonnet}
LABEL=deploy-failure

need CLAUDE_CODE_OAUTH_TOKEN
GH_TOKEN=$(github_app_token "$REPO" '{"actions":"read","contents":"read","issues":"write"}')
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

diagnose() {
  local run=$1 id sha dir jobs job body title
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
  jq -n --argjson run "$run" --argjson jobs "$jobs" --arg lines "$LOG_LINES" \
    '{run: $run, failed_jobs: $jobs, log_lines_kept: ($lines | tonumber)}' >"$dir/run.json"

  git clone -q --filter=blob:none --no-checkout "$REPO_GIT_URL" "$dir/repo"
  git -C "$dir/repo" checkout -q "$sha"

  log "run $id: diagnosing with $MODEL"
  body=$(cd "$dir" && claude_run "$MODEL" "$AGENTS_HOME/prompts/deploy-doctor.md" "Read,Grep,Glob")
  [ -n "$body" ] || die "run $id: no diagnosis"
  # shellcheck disable=SC2016 # the backticks are Markdown
  body=$(printf '%s\n\n---\n[Run %s](%s), commit `%s`. Diagnosed from the last %s lines of each failed job and the repository at that commit.\n' \
    "$body" "$id" "$(jq -r .html_url <<<"$run")" "${sha:0:7}" "$LOG_LINES")
  title="Deploy failed: run $id (${sha:0:7})"
  gh_api POST "repos/$REPO/issues" \
    "$(jq -n --arg t "$title" --arg b "$body" --arg l "$LABEL" '{title: $t, body: $b, labels: [$l]}')" |
    jq -r '"run \(.title | capture("run (?<id>[0-9]+)").id): \(.html_url)"' >&2
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
