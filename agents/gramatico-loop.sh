#!/usr/bin/env bash
# gramatico-loop: one step of a loop that works issues of piabrota/gramatico into pull requests, as
# the App pirsig-2nd-brain. A person approves the work with a label, the model edits a copy of the
# repository, the harness checks the diff, the repository's CI is the checker, and a person merges.
# A failed check gets a repair on the same branch. The attempts are capped, and at the cap the loop
# stops and asks a person. README, "The gramatico loop". Without the App's credentials it does
# nothing, so it can ship before the App exists.
#
# Each step does one thing, so it fits a schedule: wait on the open pull request, repair it, or
# start the next issue. State lives on GitHub, not in memory: an attempt is a comment, posted
# before the model runs, so a crash still counts and a store that fails cannot open the budget.

export REPO=${LOOP_REPO:-piabrota/gramatico}
export REPO_GIT_URL=${LOOP_GIT_URL:-https://github.com/$REPO}
export REPO_PUSH_URL=${LOOP_PUSH_URL:-$REPO_GIT_URL.git}
export BOT_LOGIN=${LOOP_BOT_LOGIN:-pirsig-2nd-brain[bot]}
# shellcheck source=lib/common.sh
. "$AGENTS_HOME/lib/common.sh"
# shellcheck source=lib/github-app.sh
. "$AGENTS_HOME/lib/github-app.sh"
# shellcheck source=lib/memory.sh
. "$AGENTS_HOME/lib/memory.sh"

AGENT=gramatico-loop
NAME=${BOT_LOGIN%\[bot\]}
MODEL=${LOOP_MODEL:-claude-sonnet-5-5}
BASE=${LOOP_BASE:-main}
READY_LABEL=${LOOP_READY_LABEL:-loop/pronto}
STOP_LABEL=${LOOP_STOP_LABEL:-loop/pare}
BLOCKED_LABEL=${LOOP_BLOCKED_LABEL:-status/bloqueado}
# Only these people's label starts work: the repository's CODEOWNERS.
APPROVERS=${LOOP_APPROVERS:-h0ffmann robkler}
BRANCH_PREFIX=loop/issue-
LOG_LINES=${LOG_LINES:-400}
MAX_ATTEMPTS=${LOOP_MAX_ATTEMPTS:-2}
MAX_PER_DAY=${LOOP_MAX_PER_DAY:-3}
MAX_FILES=${LOOP_MAX_FILES:-8}
MAX_LINES=${LOOP_MAX_LINES:-300}
ATTEMPT_MARKER="<!-- $NAME:attempt -->"
ESCALATED_MARKER="<!-- $NAME:escalated -->"

# The credentials are this App's alone: the loop never falls back to piabrota-ops.
if [ -z "${PIRSIG_APP_ID:-}" ] || [ -z "${PIRSIG_APP_PRIVATE_KEY_B64:-}" ]; then
  log "no PIRSIG_APP_ID or PIRSIG_APP_PRIVATE_KEY_B64: the loop is off"
  exit 0
fi
export GH_APP_ID=$PIRSIG_APP_ID GH_APP_PRIVATE_KEY_B64=$PIRSIG_APP_PRIVATE_KEY_B64

# within NAME VALUE CEILING: a limit must be a number from 1 to its ceiling. A setting can tighten
# a limit, never remove it: the run fails before it spends anything.
within() {
  case "$2" in '' | *[!0-9]*) die "$1 must be a number, not '$2'" ;; esac
  if [ "$2" -lt 1 ] || [ "$2" -gt "$3" ]; then die "$1 must be from 1 to $3, not $2"; fi
}
within LOOP_MAX_ATTEMPTS "$MAX_ATTEMPTS" 3
within LOOP_MAX_PER_DAY "$MAX_PER_DAY" 6
within LOOP_MAX_FILES "$MAX_FILES" 20
within LOOP_MAX_LINES "$MAX_LINES" 800

mint_token '{"actions":"read","contents":"write","issues":"write","pull_requests":"write"}'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
in=$work/in
gitdir=$work/git

approver() { [[ " $APPROVERS " == *" $1 "* ]]; }

stopped() {
  [ "$(gh_api GET "repos/$REPO/issues?state=open&labels=$(jq -rn --arg l "$STOP_LABEL" '$l | @uri')&per_page=1" | jq length)" != 0 ]
}

# spent_today: attempts since midnight UTC. A full page counts as the whole budget: a count that
# may be short must not open it.
spent_today() {
  local since page
  since=$(date -u +%Y-%m-%dT00:00:00Z)
  page=$(gh_api GET "repos/$REPO/issues/comments?since=$since&sort=created&direction=desc&per_page=100")
  if [ "$(jq length <<<"$page")" -ge 100 ]; then
    echo "$MAX_PER_DAY"
    return
  fi
  jq --arg b "$BOT_LOGIN" --arg m "$ATTEMPT_MARKER" --arg s "$since" \
    '[.[] | select(.user.login == $b and (.body | contains($m)) and .created_at >= $s)] | length' <<<"$page"
}

# budget_left: stop this step, without an error, when the day's attempts are spent.
budget_left() {
  local spent
  spent=$(spent_today)
  if [ "$spent" -ge "$MAX_PER_DAY" ]; then
    log "budget: $spent of $MAX_PER_DAY attempts today: nothing more until tomorrow"
    exit 0
  fi
}

# approved_at NUMBER: when an approver last labelled the issue, or nothing. The label's actor is
# checked because anyone who can triage can label; a new label starts the attempts again.
approved_at() {
  local last actor
  last=$(gh_api GET "repos/$REPO/issues/$1/events?per_page=100" |
    jq -c --arg l "$READY_LABEL" '[.[] | select(.event == "labeled" and .label.name == $l)] | last // empty')
  [ -n "$last" ] || return 0
  actor=$(jq -r '.actor.login // ""' <<<"$last")
  if approver "$actor"; then jq -r .created_at <<<"$last"; else log "#$1: labelled by $actor, not an approver"; fi
}

# attempts NUMBER SINCE: the attempts on an issue since its approval.
attempts() {
  gh_api GET "repos/$REPO/issues/$1/comments?per_page=100" |
    jq --arg b "$BOT_LOGIN" --arg m "$ATTEMPT_MARKER" --arg s "$2" \
      '[.[] | select(.user.login == $b and (.body | contains($m)) and .created_at >= $s)] | length'
}

comment() {
  gh_api POST "repos/$REPO/issues/$1/comments" "$(jq -n --arg b "$2" '{body: $b}')" >/dev/null
}

# charge NUMBER SHA TEXT: post the attempt before the model runs. If GitHub refuses, the run stops
# here (set -e), with nothing spent.
charge() {
  comment "$1" "$(printf '%s <!-- sha=%s -->\n%s\n' "$ATTEMPT_MARKER" "$2" "$3")"
}

add_label() {
  gh_api POST "repos/$REPO/issues/$1/labels" "$(jq -n --arg l "$2" '{labels: [$l]}')" >/dev/null ||
    log "#$1: could not add the label $2"
}

# escalate NUMBER WHY: stop on this issue and ask a person. The label keeps later steps away.
escalate() {
  log "#$1: stopping for a person: $2"
  # shellcheck disable=SC2016 # the backticks are Markdown
  upsert_comment "$1" "$ESCALATED_MARKER" "$(printf '%s\nThe loop stopped here and needs a person: %s\n\nTo try again, add the label `%s` again.\n' \
    "$ESCALATED_MARKER" "$2" "$READY_LABEL")" >/dev/null
  add_label "$1" "$BLOCKED_LABEL"
}

# prepare REF BRANCH: the repository at REF, on BRANCH, for the model to edit. The git directory
# moves out of the model's reach, and every git call below names it: with file tools alone, a hook
# or a core.fsmonitor in repo/.git would otherwise run as code in this pod, which holds the App's
# key, the moment the harness ran git add.
prepare() {
  rm -rf "$in" "$gitdir"
  mkdir -p "$in"
  git clone -q --filter=blob:none --no-checkout "$REPO_GIT_URL" "$in/repo"
  git -C "$in/repo" fetch -q origin "$1" 2>/dev/null || true
  git -C "$in/repo" checkout -q -B "$2" "$1"
  mv "$in/repo/.git" "$gitdir"
  lessons "$AGENT" >"$in/lessons.md"
}

git_in() { git --git-dir="$gitdir" --work-tree="$in/repo" "$@"; }

# write_issue NUMBER ISSUE_JSON: the request and its thread, only from people the loop trusts.
write_issue() {
  local c
  jq '{number, title, body, author: .user.login, labels: [.labels[].name]}' <<<"$2" >"$in/issue.json"
  while IFS= read -r c; do
    if [ "$(jq -r .user.login <<<"$c")" = "$BOT_LOGIN" ] || trusted "$(jq -r .user.login <<<"$c")" "$(jq -r '.author_association // ""' <<<"$c")"; then
      printf '%s\n' "$c"
    fi
  done < <(gh_api GET "repos/$REPO/issues/$1/comments?per_page=100" |
    jq -c '.[] | {user: {login: .user.login}, author_association, created_at, body}') | jq -s . >"$in/thread.json"
}

# run_model: sets result and answer. The model has file tools only, in this directory.
run_model() {
  result=$(cd "$in" && CLAUDE_TIMEOUT=${LOOP_TIMEOUT:-1200} claude_json "$MODEL" "$AGENTS_HOME/prompts/$AGENT.md" \
    "Read,Grep,Glob,Edit,Write" "$AGENTS_HOME/prompts/$AGENT.schema.json") || result='{"is_error": true}'
  answer=$(answer_of "$result")
}

# check_change: the harness's rules for a diff, whatever the prompt said. Prints what is wrong, one
# line each. A change may not weaken what checks it: ouroboric's protected paths and shrink guard.
check_change() {
  local files n lines diff f other raw regex status
  git_in add -A
  files=$(git_in diff --cached --name-only)
  if [ -z "$files" ]; then
    echo "no change"
    return
  fi
  n=$(wc -l <<<"$files")
  [ "$n" -le "$MAX_FILES" ] || echo "$n files changed: at most $MAX_FILES"
  lines=$(git_in diff --cached --numstat | awk '{s += $1 + $2} END {print s + 0}')
  [ "$lines" -le "$MAX_LINES" ] || echo "$lines lines changed: at most $MAX_LINES"
  while IFS= read -r regex; do
    case "$regex" in '' | '#'*) continue ;; esac
    grep -E -- "$regex" <<<"$files" | sed 's/^/a file the loop may not touch: /' || true
  done <"$AGENTS_HOME/rules/gramatico-protected.txt"
  raw=$(git_in diff --cached --raw --no-abbrev)
  while IFS= read -r status; do
    case "$status" in
      *' 120000 '* | ':120000 '*) echo "a symbolic link: ${status##*$'\t'}" ;;
    esac
    case "$(awk '{print $5}' <<<"$status")" in
      D*) echo "a deleted file: ${status##*$'\t'}" ;;
      T*) echo "a file that changed type: ${status##*$'\t'}" ;;
    esac
  done <<<"$raw"
  git_in diff --cached --numstat | awk '$1 == "-" {print "a binary file: " $3}'
  for f in $files; do
    other=$(awk -F'\t' -v f="$f" '!/^#/ && $1 == f {print $2} !/^#/ && $2 == f {print $1}' "$AGENTS_HOME/rules/gramatico-mirrors.txt")
    if [ -n "$other" ] && ! grep -qxF -- "$other" <<<"$files"; then
      echo "$f changes without its mirror $other"
    fi
  done
  diff=$(git_in diff --cached)
  guard "$diff" '⚠' "a ⚠ was removed: AGENTS.md keeps it until someone does the check"
  guard "$diff" '#\[test\]|^[-+][[:space:]]*(it|test)\(' "the change removes tests"
  [ "$(scrub <<<"$diff")" = "$diff" ] || echo "the diff holds something shaped like a credential"
  true
}

# guard DIFF REGEX MESSAGE: fewer matching lines added than removed fails: the shrink guard.
guard() {
  local minus plus
  minus=$(grep -E '^-[^-]' <<<"$1" | grep -cE -- "$2" || true)
  plus=$(grep -E '^\+[^+]' <<<"$1" | grep -cE -- "$2" || true)
  [ "$plus" -ge "$minus" ] || echo "$3"
}

# commit MESSAGE BRANCH: one commit by the App's bot user, pushed to a loop branch and nowhere else.
# The trailers are gramatico's rule: nothing ran here, so Tested: says that.
commit_push() {
  local branch=$2 message
  case "$branch" in "$BRANCH_PREFIX"*) ;; *) die "refusing to push $branch" ;; esac
  message=$(printf '%s\n\nTested: not run here; the pull request'"'"'s CI is the check.\nCo-Authored-By: Claude <noreply@anthropic.com>\n' "$1")
  bot_identity
  git_in commit -q -m "$message"
  GIT_DIR=$gitdir GIT_WORK_TREE=$in/repo push_branch "$in/repo" "$branch"
}

# accepted NUMBER: whether the step goes on. When the model declined or the harness rejected the
# change, it says why on the issue, and the next attempt reads that.
accepted() {
  local number=$1 problems
  if [ -z "$answer" ] || [ -n "$(jq -r '.no_change_reason // empty' <<<"$answer")" ]; then
    comment "$number" "$(printf 'No change this attempt: %s\n\n%s\n' \
      "$(jq -r '.no_change_reason // "the answer did not fit the schema"' <<<"${answer:-{\}}" | scrub)" "$(signature "$AGENT" "$result")")"
    return 1
  fi
  problems=$(check_change)
  if [ -n "$problems" ]; then
    log "#$number: rejected: $(tr '\n' ';' <<<"$problems")"
    comment "$number" "$(printf 'The harness rejected this attempt, so nothing was pushed:\n\n%s\n\n%s\n' \
      "$(while IFS= read -r p; do printf -- '- %s\n' "$p"; done <<<"$problems" | scrub)" "$(signature "$AGENT" "$result")")"
    return 1
  fi
}

# start ISSUE_JSON: the first attempt at an issue, from the tip of the base branch.
start() {
  local issue=$1 number branch title body pr footer
  number=$(jq -r .number <<<"$issue")
  branch="$BRANCH_PREFIX$number-$(date -u +%Y%m%d%H%M%S)"
  budget_left
  charge "$number" "$BASE" "Attempt at this issue, with \`$MODEL\`, on \`$branch\`."
  prepare "origin/$BASE" "$branch"
  write_issue "$number" "$issue"
  run_model
  accepted "$number" || return 0
  commit_push "$(jq -r .commit_message <<<"$answer")" "$branch"
  title="$(jq -r .type <<<"$answer"): $(jq -r .title_pt <<<"$answer")"
  # gramatico's bipr: pt-BR, then the English mirror, then the skill's footer.
  footer=$(cat "$in/repo/skills/bipr/footer.md" 2>/dev/null || true)
  body=$(jq -r --arg n "$number" '
    "**Resumo**: \(.summary_pt)\n\n**Testado**: ⚠ nada rodou no loop; a CI deste PR é a verificação.\n\nCloses #\($n)\n\n---\n\n**Summary**: \(.summary_en)\n\n**Tested**: ⚠ nothing ran in the loop; the CI of this pull request is the check."' <<<"$answer" | scrub)
  body=$(printf '%s\n\n%s\n' "$body" "$footer")
  pr=$(gh_api POST "repos/$REPO/pulls" "$(jq -n --arg t "$title" --arg b "$body" --arg h "$branch" --arg base "$BASE" \
    '{title: $t, body: $b, head: $h, base: $base}')" | jq -r .number)
  add_label "$pr" "tipo/$(jq -r .type <<<"$answer")"
  add_label "$number" status/em-andamento
  comment "$pr" "$(printf 'For #%s, checked by the harness. A person reviews and merges.\n\n%s\n' "$number" "$(signature "$AGENT" "$result")")"
  mem_log "$AGENT" pull_request "issue#$number" "$(jq -n --arg pr "$pr" --arg b "$branch" '{pr: $pr, branch: $b}')"
  log "#$number: pull request #$pr"
}

# repair PR_JSON NUMBER SINCE FAILED_RUNS: the failed checks of the loop's own pull request get one
# more commit on its branch, until the attempts run out.
repair() {
  local pr=$1 number=$2 since=$3 failed=$4 sha head job id n
  sha=$(jq -r .head.sha <<<"$pr")
  head=$(jq -r .head.ref <<<"$pr")
  n=$(jq -r .number <<<"$pr")
  if gh_api GET "repos/$REPO/issues/$number/comments?per_page=100" |
    jq -e --arg b "$BOT_LOGIN" --arg s "sha=$sha" 'any(.[]; .user.login == $b and (.body | contains($s)))' >/dev/null; then
    log "#$n: ${sha:0:7} had its attempt"
    return 0
  fi
  if [ "$(attempts "$number" "$since")" -ge "$MAX_ATTEMPTS" ]; then
    escalate "$number" "the checks of #$n still fail after $MAX_ATTEMPTS attempts."
    return 0
  fi
  budget_left
  charge "$number" "$sha" "Repair of #$n, with \`$MODEL\`: its checks failed at \`${sha:0:7}\`."
  prepare "$sha" "$head"
  write_issue "$number" "$(gh_api GET "repos/$REPO/issues/$number")"
  mkdir -p "$in/failure"
  for id in $(jq -r '.[].id' <<<"$failed"); do
    for job in $(gh_api GET "repos/$REPO/actions/runs/$id/jobs?filter=latest" | jq -r '.jobs[] | select(.conclusion == "failure") | .id'); do
      gh_download "repos/$REPO/actions/jobs/$job/logs" | strip_ansi | tail -n "$LOG_LINES" >"$in/failure/job-$job.log" ||
        log "#$n: could not read the log of job $job"
    done
  done
  run_model
  accepted "$number" || return 0
  commit_push "$(jq -r .commit_message <<<"$answer")" "$head"
  comment "$n" "$(printf 'A repair of the failed checks, checked by the harness.\n\n%s\n' "$(signature "$AGENT" "$result")")"
  log "#$n: repair pushed"
}

# watch PR_JSON: the one open pull request of the loop. A person's commit means hands off.
watch_pr() {
  local pr=$1 n number sha since issue runs failed
  n=$(jq -r .number <<<"$pr")
  sha=$(jq -r .head.sha <<<"$pr")
  number=$(jq -r .head.ref <<<"$pr" | sed -E "s|^$BRANCH_PREFIX([0-9]+)-.*|\1|")
  if gh_api GET "repos/$REPO/pulls/$n/commits?per_page=100" |
    jq -e --arg b "$BOT_LOGIN" 'any(.[]; .commit.author.name != $b)' >/dev/null; then
    log "#$n: a person committed here: the loop leaves it alone"
    return 0
  fi
  issue=$(gh_api GET "repos/$REPO/issues/$number")
  if jq -e --arg l "$BLOCKED_LABEL" 'any(.labels[]; .name == $l)' <<<"$issue" >/dev/null; then
    log "#$n: #$number waits for a person"
    return 0
  fi
  since=$(approved_at "$number")
  if [ -z "$since" ]; then
    log "#$n: #$number has no approval now: the loop leaves it alone"
    return 0
  fi
  runs=$(gh_api GET "repos/$REPO/actions/runs?head_sha=$sha&per_page=30" |
    jq -c '[.workflow_runs[] | {id, status, conclusion}]')
  if [ "$(jq length <<<"$runs")" = 0 ]; then
    log "#$n: no check ran at ${sha:0:7}: a person must decide"
  elif jq -e 'any(.[]; .status != "completed")' <<<"$runs" >/dev/null; then
    log "#$n: checks are running"
  else
    failed=$(jq -c '[.[] | select(.conclusion != "success" and .conclusion != "skipped" and .conclusion != "neutral")]' <<<"$runs")
    if [ "$(jq length <<<"$failed")" = 0 ]; then
      log "#$n: checks passed: it waits for a person's review"
    else
      repair "$pr" "$number" "$since" "$failed"
    fi
  fi
}

# closed_already NUMBER SINCE: a loop pull request for this issue was closed after its approval.
# Whether it merged or a person turned it down, the answer is not another attempt.
closed_already() {
  jq -e --arg p "$BRANCH_PREFIX$1-" --arg s "$2" \
    'any(.[]; (.head.ref | startswith($p)) and (.closed_at // "") >= $s)' <<<"$closed" >/dev/null
}

# next_issue: the most urgent approved issue. Its author must be trusted too: anyone can edit their
# own issue after the label, so a stranger's text would reach the model unreviewed.
next_issue() {
  local issues issue number since done_n
  issues=$(gh_api GET "repos/$REPO/issues?state=open&labels=$(jq -rn --arg l "$READY_LABEL" '$l | @uri')&per_page=50" |
    jq -c --arg b "$BLOCKED_LABEL" '[.[] | select((.pull_request | not) and (any(.labels[]; .name == $b) | not))]
      | sort_by(([.labels[].name] | if index("prioridade/alta") then 0 elif index("prioridade/média") then 1 else 2 end), .number) | .[]')
  if [ -z "$issues" ]; then
    log "no issue labelled $READY_LABEL"
    return 0
  fi
  closed=$(gh_api GET "repos/$REPO/pulls?state=closed&sort=updated&direction=desc&per_page=100")
  while IFS= read -r issue; do
    number=$(jq -r .number <<<"$issue")
    if ! trusted "$(jq -r .user.login <<<"$issue")" "$(jq -r '.author_association // ""' <<<"$issue")"; then
      log "#$number: its author is not trusted"
      continue
    fi
    since=$(approved_at "$number")
    [ -n "$since" ] || continue
    if closed_already "$number" "$since"; then
      log "#$number: a loop pull request was closed: a person decides what is next"
      continue
    fi
    done_n=$(attempts "$number" "$since")
    if [ "$done_n" -ge "$MAX_ATTEMPTS" ]; then
      escalate "$number" "$done_n attempts gave no pull request."
      continue
    fi
    need CLAUDE_CODE_OAUTH_TOKEN
    start "$issue"
    return 0
  done <<<"$issues"
}

if stopped; then
  log "an open issue has the label $STOP_LABEL: the loop stops here"
  exit 0
fi
# One pull request at a time: the next issue waits for a person to deal with this one.
open_pr=$(gh_api GET "repos/$REPO/pulls?state=open&per_page=100" |
  jq -c --arg b "$BOT_LOGIN" --arg p "$BRANCH_PREFIX" '[.[] | select(.user.login == $b and (.head.ref | startswith($p)))][0] // empty')
if [ -n "$open_pr" ]; then
  need CLAUDE_CODE_OAUTH_TOKEN
  watch_pr "$open_pr"
else
  next_issue
fi
