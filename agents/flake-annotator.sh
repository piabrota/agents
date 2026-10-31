#!/usr/bin/env bash
# flake-annotator: an open pull request labelled flake-update (nix-os' weekly flake-update workflow
# opens them, with the closure difference in the body) gets one comment, per head commit, on how
# risky the update is and what to watch after it deploys, written by Claude Code from the dix
# output and the lock's diff.
# shellcheck source=lib/common.sh
. "$AGENTS_HOME/lib/common.sh"
# shellcheck source=lib/github-app.sh
. "$AGENTS_HOME/lib/github-app.sh"
# shellcheck source=lib/memory.sh
. "$AGENTS_HOME/lib/memory.sh"

MODEL=${FLAKE_ANNOTATOR_MODEL:-claude-sonnet-5-5}
LABEL=flake-update
MARKER="<!-- piabrota-ops:flake -->"

need CLAUDE_CODE_OAUTH_TOKEN
mint_token '{"contents":"read","issues":"write","pull_requests":"write"}'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

prs=$(gh_api GET "repos/$REPO/issues?labels=$LABEL&state=open&per_page=10" | jq -r '.[] | select(.pull_request) | .number')
[ -n "$prs" ] || {
  log "no open $LABEL pull request"
  exit 0
}
for number in $prs; do
  pr=$(gh_api GET "repos/$REPO/pulls/$number")
  sha=$(jq -r .head.sha <<<"$pr")
  if gh_api GET "repos/$REPO/issues/$number/comments?per_page=100" |
    jq -e --arg b "$BOT_LOGIN" --arg s "sha=$sha" 'any(.[]; .user.login == $b and (.body | contains($s)))' >/dev/null; then
    continue
  fi
  dir=$work/$number
  mkdir -p "$dir"
  jq '{number, title, body}' <<<"$pr" >"$dir/pr.json"
  gh_api GET "repos/$REPO/pulls/$number/files?per_page=100" | jq -r '.[] | select(.filename == "flake.lock") | .patch // ""' >"$dir/lock.diff"
  git clone -q --filter=blob:none --no-checkout "$REPO_GIT_URL" "$dir/repo"
  git -C "$dir/repo" fetch -q origin "$sha" 2>/dev/null || true
  git -C "$dir/repo" checkout -q "$sha"
  lessons flake-annotator >"$dir/lessons.md"
  log "#$number: annotating ${sha:0:7} with $MODEL"
  result=$(cd "$dir" && claude_json "$MODEL" "$AGENTS_HOME/prompts/flake-annotator.md" "Read,Grep,Glob" \
    "$AGENTS_HOME/prompts/flake-annotator.schema.json") || result='{"is_error": true}'
  answer=$(answer_of "$result")
  [ -n "$answer" ] || {
    log "#$number: no answer that fits the schema"
    continue
  }
  body=$(jq -r '({"low": "🟢", "medium": "🟠", "high": "🔴"}[.risk]) as $i
    | "### \($i) Update risk: \(.risk)\n\n\(.summary)\n"
      + (if (.watch | length) > 0 then "\n**After it deploys, check:**\n\n" + ([.watch[] | "- \(.)"] | join("\n")) + "\n" else "" end)' <<<"$answer" | scrub)
  body=$(printf '%s %s\n%s\n\n%s\n' "$MARKER" "<!-- sha=$sha -->" "$body" "$(signature flake-annotator "$result")")
  log "#$number: $(jq -r .risk <<<"$answer"), $(upsert_comment "$number" "$MARKER" "$body")"
  mem_log flake-annotator annotation "pr#$number@${sha:0:7}" "$answer"
done
