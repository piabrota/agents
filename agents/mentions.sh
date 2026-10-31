#!/usr/bin/env bash
# mentions: comments on $REPO's issues and pull requests in the last $LOOKBACK_MINUTES that name
# @piabrota-ops get one reply each, only from trusted people (TRUSTED_USERS, or the repository's
# owners, members and collaborators): it is a public repository and every answer is subscription
# usage. "try a fix" on a deploy-failure issue runs deploy-doctor's fix for its run; "review" on a
# pull request reviews it now; anything else is a question, answered by Claude Code from the
# thread and the repository, each quote checked against its file.
# shellcheck source=lib/common.sh
. "$AGENTS_HOME/lib/common.sh"
# shellcheck source=lib/github-app.sh
. "$AGENTS_HOME/lib/github-app.sh"
# shellcheck source=lib/memory.sh
. "$AGENTS_HOME/lib/memory.sh"

MODEL=${MENTIONS_MODEL:-claude-sonnet-5-5}
LOOKBACK_MINUTES=${LOOKBACK_MINUTES:-60}
HANDLE=${HANDLE:-@piabrota-ops}

need CLAUDE_CODE_OAUTH_TOKEN
mint_token '{"contents":"read","issues":"write","pull_requests":"write"}' '{"contents":"read","issues":"write"}'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

reply() {
  local number=$1 id=$2 text=$3 result=${4:-'{}'}
  gh_api POST "repos/$REPO/issues/$number/comments" "$(jq -n --arg b "$(printf '<!-- piabrota-ops:reply to=%s -->\n%s\n\n%s\n' \
    "$id" "$(scrub <<<"$text")" "$(signature mentions "$result")")" '{body: $b}')" | jq -r .html_url
}

# check_evidence DIR ANSWER: each quote must be a line of the file it names.
check_evidence() {
  local dir=$1 answer=$2 e file quote
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    file=$(jq -r .file <<<"$e")
    quote=$(jq -r .quote <<<"$e" | sed -E 's/^[-+ ]?[[:space:]]*//; s/[[:space:]]+$//')
    case "$file" in *..*) echo "file $file leaves the inputs" && continue ;; esac
    if [ ! -f "$dir/$file" ] || ! grep -qF -- "$quote" "$dir/$file"; then
      echo "the quote \"${quote:0:80}\" is not in $file: copy one line exactly"
    fi
  done < <(jq -c '.evidence[]?' <<<"$answer")
}

answer_question() {
  local comment=$1 issue=$2 number id dir sha result answer problems text
  number=$(jq -r .number <<<"$issue")
  id=$(jq -r .id <<<"$comment")
  dir=$work/$id
  mkdir -p "$dir"
  jq -r '"From @\(.user.login) (\(.author_association)):\n\n\(.body)"' <<<"$comment" >"$dir/question.md"
  {
    jq -r '"# #\(.number): \(.title)\n\nOpened by @\(.user.login).\n\n\(.body // "")\n"' <<<"$issue"
    gh_api GET "repos/$REPO/issues/$number/comments?per_page=100" | jq -r '.[] | "\n## @\(.user.login), \(.created_at)\n\n\(.body)"'
  } >"$dir/thread.md"
  git clone -q --filter=blob:none --no-checkout "$REPO_GIT_URL" "$dir/repo"
  sha=HEAD
  if jq -e '.pull_request' <<<"$issue" >/dev/null; then
    gh_api GET "repos/$REPO/pulls/$number/files?per_page=100" |
      jq -r '.[] | "--- a/\(.filename)\n+++ b/\(.filename)\n\(.patch // "(no patch)")"' >"$dir/diff.patch"
    sha=$(gh_api GET "repos/$REPO/pulls/$number" | jq -r .head.sha)
    git -C "$dir/repo" fetch -q origin "$sha" 2>/dev/null || true
  fi
  git -C "$dir/repo" checkout -q "$sha"
  lessons mentions >"$dir/lessons.md"

  problems=
  for try in 1 2; do
    log "#$number: answering comment $id with $MODEL (try $try)"
    result=$(cd "$dir" && claude_json "$MODEL" "$AGENTS_HOME/prompts/mentions.md" "Read,Grep,Glob" \
      "$AGENTS_HOME/prompts/mentions.schema.json" "$problems") || result='{"is_error": true}'
    answer=$(answer_of "$result")
    if [ -z "$answer" ]; then
      problems="the answer was missing or did not fit the schema"
      continue
    fi
    problems=$(check_evidence "$dir" "$answer")
    [ -z "$problems" ] && break
    log "#$number: try $try rejected: $(tr '\n' ';' <<<"$problems")"
  done
  if [ -n "$problems" ]; then
    text="I could not ground an answer in the thread and the repository, so I give none rather than a guess."
  else
    text=$(jq -r '"\(.answer)\n\n<details><summary>Evidence (confidence: \(.confidence))</summary>\n\n"
      + ([.evidence[] | "- `\(.file)`: `\(.quote | gsub("`"; "'"'"'"))`"] | join("\n")) + "\n\n</details>"' <<<"$answer")
  fi
  log "#$number: $(reply "$number" "$id" "$text" "$result")"
  mem_log mentions reply "comment#$id" "$(jq -n --arg q "$(jq -r .body <<<"$comment")" --arg a "$text" '{question: $q[:1000], answer: $a[:2000]}')"
}

since=$(date -u -d "-$LOOKBACK_MINUTES minutes" +%Y-%m-%dT%H:%M:%SZ)
mentions=$(gh_api GET "repos/$REPO/issues/comments?since=$since&per_page=100" |
  jq -c --arg h "$HANDLE" --arg b "$BOT_LOGIN" '.[] | select(.user.login != $b and .user.type != "Bot"
    and (.body | ascii_downcase | contains($h | ascii_downcase)))')
[ -n "$mentions" ] || {
  log "no mention of $HANDLE since $since"
  exit 0
}
while IFS= read -r comment; do
  id=$(jq -r .id <<<"$comment")
  login=$(jq -r .user.login <<<"$comment")
  number=$(jq -r '.issue_url | split("/") | last' <<<"$comment")
  if ! trusted "$login" "$(jq -r .author_association <<<"$comment")"; then
    log "#$number: comment $id is from $login, who is not trusted: no reply"
    continue
  fi
  if gh_api GET "repos/$REPO/issues/$number/comments?per_page=100" |
    jq -e --arg b "$BOT_LOGIN" --arg m "piabrota-ops:reply to=$id " 'any(.[]; .user.login == $b and (.body | contains($m)))' >/dev/null; then
    continue
  fi
  issue=$(gh_api GET "repos/$REPO/issues/$number")
  ask=$(jq -r .body <<<"$comment" | tr '[:upper:]' '[:lower:]')
  if grep -qE "try a fix|fix (it|this)" <<<"$ask" && jq -e '[.labels[].name] | index("deploy-failure")' <<<"$issue" >/dev/null; then
    run=$(jq -r '.title | capture("run (?<id>[0-9]+)").id // empty' <<<"$issue")
    if [ -n "$run" ] && FIX_RUN=$run "$AGENTS_HOME/agents/deploy-doctor.sh"; then
      log "#$number: $(reply "$number" "$id" "Done: the fix, or why there is none, is in the comments above.")"
    else
      log "#$number: $(reply "$number" "$id" "The fix did not run: piabrota-ops may lack contents:write on this repository, or the run has no logs left. The task's log has the reason.")"
    fi
  elif grep -qE "(^|[^a-z])review([^a-z]|$)" <<<"$ask" && jq -e '.pull_request' <<<"$issue" >/dev/null; then
    REVIEW_PR=$number "$AGENTS_HOME/agents/pr-reviewer.sh"
    log "#$number: $(reply "$number" "$id" "Reviewed: the review comment above is up to date.")"
  else
    answer_question "$comment" "$issue"
  fi
done <<<"$mentions"
