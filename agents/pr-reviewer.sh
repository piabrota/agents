#!/usr/bin/env bash
# pr-reviewer: every open pull request on $REPO whose head commit it has not reviewed gets one
# review comment, edited in place on each new push. Two layers: rules the harness checks itself
# (the bipr shape, no agent trail, docs and their mirrors, the closure line, the machine-critical
# settings in rules/critical.txt), and Claude Code's review against AGENTS.md, whose every finding
# must quote a line that is in the diff or the file. REVIEW_PR=<number> reviews that one now,
# reviewed or not, as a mention asks.
# shellcheck source=lib/common.sh
. "$AGENTS_HOME/lib/common.sh"
# shellcheck source=lib/github-app.sh
. "$AGENTS_HOME/lib/github-app.sh"
# shellcheck source=lib/memory.sh
. "$AGENTS_HOME/lib/memory.sh"

MODEL=${PR_REVIEWER_MODEL:-claude-sonnet-5-5}
MAX_REVIEW_LINES=${MAX_REVIEW_LINES:-3000}
MARKER="<!-- piabrota-ops:review -->"

need CLAUDE_CODE_OAUTH_TOKEN
mint_token '{"contents":"read","issues":"write","pull_requests":"write"}'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# rule_findings DIR: the harness's own findings, as a JSON array.
rule_findings() {
  local dir=$1 files body commits f other
  files=$(jq -r '.[].filename' "$dir/files.json")
  body=$(jq -r '.body // ""' "$dir/pr.json")
  commits=$(jq -r '.[].message' "$dir/commits.json")
  {
    if ! grep -qx -- '---' <<<"$body"; then
      jq -nc '{severity: "high", rule: "bipr", file: "", comment: "AGENTS.md: every PR is a bipr: the title in pt-BR, the body in pt-BR, a `---` line, then its English mirror."}'
    fi
    if grep -qiE 'Co-Authored-By:.*(claude|anthropic)|Generated (with|by) .*(claude|copilot|devin|cursor)|claude\.com/claude-code|🤖 Generated' <<<"$body"$'\n'"$commits"; then
      jq -nc '{severity: "high", rule: "no agent trail", file: "", comment: "AGENTS.md: no commit or PR carries a mark of an agent or tool (a Co-Authored-By trailer, a Generated with line). Remove it."}'
    fi
    for f in $files; do
      other=
      case "$f" in
        docs/*.ptBR.md) other=${f%.ptBR.md}.md ;;
        docs/*.md) other=${f%.md}.ptBR.md ;;
      esac
      [ -z "$other" ] && other=$(awk -F'\t' -v f="$f" '!/^#/ && $1 == f {print $2} !/^#/ && $2 == f {print $1}' "$AGENTS_HOME/rules/mirrors.txt")
      if [ -n "$other" ] && [ -e "$dir/repo/$other" ] && ! grep -qxF -- "$other" <<<"$files"; then
        jq -nc --arg f "$f" --arg o "$other" '{severity: "medium", rule: "mirrors", file: $f, comment: "Its mirror \($o) does not change with it: AGENTS.md has the two change together."}'
      fi
    done
    if grep -qE '\.nix$|^flake\.lock$' <<<"$files" && ! grep -qiE 'closure|dix' <<<"$body"; then
      jq -nc '{severity: "medium", rule: "closure", file: "", comment: "AGENTS.md: the PR says what changed in the closure (the dix summary) and whether the build was run."}'
    fi
    while IFS= read -r regex; do
      case "$regex" in '' | '#'*) continue ;; esac
      grep -E '^[-+][^-+]' "$dir/diff.patch" | grep -qE -- "$regex" &&
        jq -nc --arg r "$regex" '{severity: "high", rule: "do not break the machine", file: "", comment: "The diff touches a setting on AGENTS.md'"'"'s \"Do not break the machine\" list (\($r)): check it keeps the VPS reachable."}'
    done <"$AGENTS_HOME/rules/critical.txt"
    true
  } | jq -s .
}

# check_findings DIR ANSWER: a quote must be a line of the diff or of the file. Prints what fails.
check_findings() {
  local dir=$1 answer=$2 f file quote
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    file=$(jq -r .file <<<"$f")
    quote=$(jq -r .quote <<<"$f" | sed -E 's/^[-+ ]?[[:space:]]*//; s/[[:space:]]+$//')
    case "$file" in *..*) echo "file $file leaves the repository" && continue ;; esac
    if ! grep -qF -- "$quote" "$dir/diff.patch" && ! { [ -f "$dir/repo/$file" ] && grep -qF -- "$quote" "$dir/repo/$file"; }; then
      echo "the quote \"${quote:0:80}\" is not in diff.patch or $file: copy one line exactly"
    fi
  done < <(jq -c '.findings[]?' <<<"$answer")
}

review() {
  local number=$1 force=$2 pr sha dir lines findings result answer problems verdict body worst
  pr=$(gh_api GET "repos/$REPO/pulls/$number")
  sha=$(jq -r .head.sha <<<"$pr")
  if [ "$force" != 1 ] && gh_api GET "repos/$REPO/issues/$number/comments?per_page=100" |
    jq -e --arg b "$BOT_LOGIN" --arg s "sha=$sha" 'any(.[]; .user.login == $b and (.body | contains($s)))' >/dev/null; then
    log "#$number: ${sha:0:7} already reviewed"
    return 0
  fi
  dir=$work/$number
  mkdir -p "$dir"
  jq '{number, title, body, author: .user.login, draft, base: .base.ref, head: .head.ref, sha: .head.sha}' <<<"$pr" >"$dir/pr.json"
  gh_api GET "repos/$REPO/pulls/$number/files?per_page=100" | jq '[.[] | {filename, status, additions, deletions, patch}]' >"$dir/files.json"
  jq -r '.[] | "--- a/\(.filename)\n+++ b/\(.filename)\n\(.patch // "(no patch: binary or too large)")"' "$dir/files.json" >"$dir/diff.patch"
  gh_api GET "repos/$REPO/pulls/$number/commits?per_page=100" | jq '[.[] | {sha: .sha[:7], message: .commit.message, author: .commit.author.name}]' >"$dir/commits.json"
  git clone -q --filter=blob:none --no-checkout "$REPO_GIT_URL" "$dir/repo"
  git -C "$dir/repo" fetch -q origin "$sha" 2>/dev/null || true
  git -C "$dir/repo" checkout -q "$sha"
  findings=$(rule_findings "$dir")
  printf '%s\n' "$findings" >"$dir/findings.json"
  lessons pr-reviewer >"$dir/lessons.md"

  lines=$(jq '[.[] | .additions + .deletions] | add // 0' "$dir/files.json")
  answer=
  result='{}'
  if [ "$lines" -gt "$MAX_REVIEW_LINES" ]; then
    log "#$number: $lines changed lines, more than $MAX_REVIEW_LINES: rules only"
    answer=$(jq -nc --arg l "$lines" '{verdict: "attention", summary: "\($l) changed lines: too large for a full review here; the rule checks below still ran.", findings: []}')
  else
    problems=
    for try in 1 2; do
      log "#$number: reviewing ${sha:0:7} with $MODEL (try $try)"
      result=$(cd "$dir" && claude_json "$MODEL" "$AGENTS_HOME/prompts/pr-reviewer.md" "Read,Grep,Glob" \
        "$AGENTS_HOME/prompts/pr-reviewer.schema.json" "$problems") || result='{"is_error": true}'
      answer=$(answer_of "$result")
      if [ -z "$answer" ]; then
        problems="the answer was missing or did not fit the schema"
        continue
      fi
      problems=$(check_findings "$dir" "$answer")
      [ -z "$problems" ] && break
      log "#$number: try $try rejected: $(tr '\n' ';' <<<"$problems")"
    done
    if [ -z "$answer" ]; then
      answer='{"verdict": "attention", "summary": "The review gave no answer that fits its schema; only the rule checks ran.", "findings": []}'
    elif [ -n "$problems" ]; then
      # Keep only the findings whose quote holds.
      answer=$(jq -c --argjson bad "$(while IFS= read -r f; do
        q=$(jq -r .quote <<<"$f" | sed -E 's/^[-+ ]?[[:space:]]*//; s/[[:space:]]+$//')
        file=$(jq -r .file <<<"$f")
        if grep -qF -- "$q" "$dir/diff.patch" || { [ -f "$dir/repo/$file" ] && grep -qF -- "$q" "$dir/repo/$file"; }; then echo true; else echo false; fi
      done < <(jq -c '.findings[]' <<<"$answer") | jq -s .)" '.findings |= [to_entries[] | select($bad[.key]) | .value]' <<<"$answer")
    fi
  fi

  # The verdict is the worse of the model's and the rules'.
  worst=$(jq -r 'if any(.[]; .severity == "high") then "changes-suggested" elif length > 0 then "attention" else "ok" end' <<<"$findings")
  verdict=$(jq -rn --arg a "$(jq -r .verdict <<<"$answer")" --arg b "$worst" \
    '["ok", "attention", "changes-suggested"] as $o | if ($o | index($a)) > ($o | index($b)) then $a else $b end')
  body=$(jq -r --arg v "$verdict" --argjson rules "$findings" --arg sha "${sha:0:7}" '
    ({"ok": "✅", "attention": "🔎", "changes-suggested": "✋"}[$v]) as $icon
    | "### \($icon) Review of `\($sha)`: \($v)\n\n\(.summary)\n"
      + (if (($rules | length) + (.findings | length)) == 0 then "\nNothing to flag.\n" else
        "\n| | Where | What |\n|---|---|---|\n"
        + ([$rules[] | "| \({"high": "🔴", "medium": "🟠", "low": "⚪"}[.severity]) | \(if .file == "" then "the PR" else "`\(.file)`" end) | **\(.rule)**: \(.comment | gsub("\n"; " ") | gsub("\\|"; "\\\\|")) |"] | join("\n"))
        + (if ($rules | length) > 0 and (.findings | length) > 0 then "\n" else "" end)
        + ([.findings[] | "| \({"high": "🔴", "medium": "🟠", "low": "⚪"}[.severity]) | `\(.file)` | \(.comment | gsub("\n"; " ") | gsub("\\|"; "\\\\|"))<br>`\(.quote | gsub("\\|"; "\\\\|"))` |"] | join("\n"))
        + "\n" end)' <<<"$answer" | scrub)
  body=$(printf '%s %s\n%s\n\n%s\n' "$MARKER" "<!-- sha=$sha -->" "$body" "$(signature pr-reviewer "$result")")
  log "#$number: $verdict, $(upsert_comment "$number" "$MARKER" "$body")"
  mem_log pr-reviewer review "pr#$number@${sha:0:7}" "$(jq -n --arg v "$verdict" --argjson a "$answer" --argjson r "$findings" '{verdict: $v, summary: $a.summary, findings: (($r | length) + ($a.findings | length))}')"
}

if [ -n "${REVIEW_PR:-}" ]; then
  review "$REVIEW_PR" 1
  exit 0
fi
prs=$(gh_api GET "repos/$REPO/pulls?state=open&per_page=30" | jq -r '.[].number')
[ -n "$prs" ] || log "no open pull request"
for number in $prs; do
  review "$number" 0
done
