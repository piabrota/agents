#!/usr/bin/env bash
# mirror-keeper: an open pull request on $REPO that changes a document but not its mirror (docs'
# pt-BR and English pairs, and rules/mirrors.txt) gets a pull request into its own branch that
# brings the mirrors up to date, written by Claude Code. The harness lets the change touch only
# those mirrors. One at a time per pull request; it skips its own branches and forks (it cannot
# push to a fork). Needs contents:write; without it, it does nothing.
# shellcheck source=lib/common.sh
. "$AGENTS_HOME/lib/common.sh"
# shellcheck source=lib/github-app.sh
. "$AGENTS_HOME/lib/github-app.sh"
# shellcheck source=lib/memory.sh
. "$AGENTS_HOME/lib/memory.sh"

MODEL=${MIRROR_KEEPER_MODEL:-claude-sonnet-5-5}
MAX_MIRROR_LINES=${MAX_MIRROR_LINES:-400}

need CLAUDE_CODE_OAUTH_TOKEN
mint_token '{"contents":"write","issues":"write","pull_requests":"write"}' '{"contents":"read"}'
if ! token_can contents; then
  log "no contents:write for piabrota-ops on $REPO: no mirror pull requests"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# missing_mirrors FILES_JSON REPO_DIR: the pairs whose one side changed and the other did not.
missing_mirrors() {
  local files=$1 repo=$2 names f other
  names=$(jq -r '.[].filename' <<<"$files")
  for f in $names; do
    other=
    case "$f" in
      docs/*.ptBR.md) other=${f%.ptBR.md}.md ;;
      docs/*.md) other=${f%.md}.ptBR.md ;;
    esac
    [ -z "$other" ] && other=$(awk -F'\t' -v f="$f" '!/^#/ && $1 == f {print $2} !/^#/ && $2 == f {print $1}' "$AGENTS_HOME/rules/mirrors.txt")
    if [ -n "$other" ] && [ -e "$repo/$other" ] && ! grep -qxF -- "$other" <<<"$names"; then
      jq -nc --arg c "$f" --arg m "$other" --argjson files "$files" \
        '{changed: $c, mirror: $m, patch: ([$files[] | select(.filename == $c) | .patch][0] // "")}'
    fi
  done | jq -s .
}

keep() {
  local pr=$1 number sha head dir files pairs branch result answer changed bad lines title body new
  number=$(jq -r .number <<<"$pr")
  sha=$(jq -r .head.sha <<<"$pr")
  head=$(jq -r .head.ref <<<"$pr")
  branch="agents/mirror-for-pr-$number-${sha:0:7}"
  mem_has mirror-keeper mirror "pr#$number@${sha:0:7}" && return 0
  if gh_api GET "repos/$REPO/pulls?state=open&per_page=100" |
    jq -e --arg p "agents/mirror-for-pr-$number-" 'any(.[]; .head.ref | startswith($p))' >/dev/null; then
    log "#$number: a mirror pull request is open already"
    return 0
  fi
  dir=$work/$number
  mkdir -p "$dir"
  files=$(gh_api GET "repos/$REPO/pulls/$number/files?per_page=100" | jq -c '[.[] | {filename, status, patch}]')
  git clone -q --filter=blob:none --no-checkout "$REPO_GIT_URL" "$dir/repo"
  git -C "$dir/repo" fetch -q origin "$sha" 2>/dev/null || true
  git -C "$dir/repo" checkout -q "$sha"
  pairs=$(missing_mirrors "$files" "$dir/repo")
  if [ "$(jq length <<<"$pairs")" = 0 ]; then
    mem_log mirror-keeper mirror "pr#$number@${sha:0:7}" '{"pairs": 0}'
    return 0
  fi
  printf '%s\n' "$pairs" >"$dir/pairs.json"
  lessons mirror-keeper >"$dir/lessons.md"
  git -C "$dir/repo" checkout -q -b "$branch"
  log "#$number: $(jq -r '[.[].mirror] | join(", ")' <<<"$pairs") to bring up to date, with $MODEL"
  result=$(cd "$dir" && claude_json "$MODEL" "$AGENTS_HOME/prompts/mirror-keeper.md" "Read,Grep,Glob,Edit" \
    "$AGENTS_HOME/prompts/mirror-keeper.schema.json") || result='{"is_error": true}'
  answer=$(answer_of "$result")
  mem_log mirror-keeper mirror "pr#$number@${sha:0:7}" "$(jq -n --argjson p "$pairs" --arg a "${answer:-}" '{pairs: ($p | length), answer: $a}')"
  git -C "$dir/repo" add -A
  changed=$(git -C "$dir/repo" diff --cached --name-only)
  if [ -z "$answer" ] || [ -z "$changed" ]; then
    log "#$number: no mirror change: $(jq -r '.no_change_reason // "no answer that fits the schema"' <<<"${answer:-{\}}")"
    return 0
  fi
  bad=$(grep -vxF -f <(jq -r '.[].mirror' <<<"$pairs") <<<"$changed" || true)
  lines=$(git -C "$dir/repo" diff --cached --numstat | awk '{s += $1 + $2} END {print s + 0}')
  if [ -n "$bad" ] || [ "$lines" -gt "$MAX_MIRROR_LINES" ] || [ "$(git -C "$dir/repo" diff --cached | scrub)" != "$(git -C "$dir/repo" diff --cached)" ]; then
    log "#$number: mirror change rejected (other files: ${bad:-none}; $lines lines)"
    return 0
  fi
  bot_identity
  git -C "$dir/repo" commit -q -m "docs: bring $(tr '\n' ' ' <<<"$changed" | sed 's/ $//; s/ /, /g') up to date with #$number"
  push_branch "$dir/repo" "$branch"
  title="docs: espelho de $(tr '\n' ' ' <<<"$changed" | sed 's/ $//; s/ /, /g') para o #$number"
  body=$(jq -r --arg n "$number" '"\(.summary_pt)\n\nPara o branch do #\($n): faça o merge aqui se estiver certo, e ele entra no #\($n).\n\n---\n\n\(.summary_en)\n\nInto #\($n)'"'"'s branch: merge it here if it is right, and it goes into #\($n)."' <<<"$answer" | scrub)
  new=$(gh_api POST "repos/$REPO/pulls" "$(jq -n --arg t "$title" --arg b "$body" --arg h "$branch" --arg base "$head" \
    '{title: $t, body: $b, head: $h, base: $base}')" | jq -r .number)
  upsert_comment "$new" "<!-- piabrota-ops:mirror -->" "$(printf '<!-- piabrota-ops:mirror -->\nThe mirrors #%s left behind, checked by the harness: only %s changed.\n\n%s\n' \
    "$number" "$(tr '\n' ' ' <<<"$changed")" "$(signature mirror-keeper "$result")")" >/dev/null
  gh_api POST "repos/$REPO/issues/$number/comments" "$(jq -n --arg b "$(printf 'The mirrors this pull request leaves behind are brought up to date in #%s, into this branch.\n\n%s\n' \
    "$new" "$(signature mirror-keeper "$result")")" '{body: $b}')" >/dev/null
  log "#$number: mirror pull request #$new into $head"
}

prs=$(gh_api GET "repos/$REPO/pulls?state=open&per_page=30" |
  jq -c --arg r "$REPO" '.[] | select(.head.repo.full_name == $r and (.head.ref | startswith("agents/") | not))')
[ -n "$prs" ] || {
  log "no open pull request to check"
  exit 0
}
while IFS= read -r pr; do keep "$pr"; done <<<"$prs"
