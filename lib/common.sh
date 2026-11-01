# shellcheck shell=bash
# Shared by the agents: logging, the GitHub API as piabrota-ops, and Claude Code headless.
set -euo pipefail

AGENTS_HOME=${AGENTS_HOME:-/opt/agents}
GITHUB_API=${GITHUB_API:-https://api.github.com}
# The repository the agents watch and report on.
REPO=${REPO:-piabrota/nix-os}
REPO_GIT_URL=${REPO_GIT_URL:-https://github.com/$REPO}
# Where the agents that write push their branches (a local path in the tests).
REPO_PUSH_URL=${REPO_PUSH_URL:-https://github.com/$REPO.git}
# The App's user, as it shows on what it posts, and the people whose word the agents take: they
# answer only those (a public repository, and every answer is subscription usage).
BOT_LOGIN=${BOT_LOGIN:-piabrota-ops[bot]}
TRUSTED_USERS=${TRUSTED_USERS:-h0ffmann}

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() {
  log "error: $*"
  exit 1
}

# need VAR...: fail unless each is set, naming where it comes from.
need() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || die "$v is not set (it comes from the Secret ax-tasks/agents; see the README)"
  done
}

# gh_api METHOD PATH [JSON]: one GitHub API call with $GH_TOKEN, the response on stdout.
gh_api() {
  local method=$1 path=$2 data=${3:-}
  local args=(-fsS -X "$method"
    -H "Authorization: Bearer $GH_TOKEN"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28")
  if [ -n "$data" ]; then
    args+=(-H "Content-Type: application/json" --data-binary "$data")
  fi
  curl "${args[@]}" "$GITHUB_API/$path"
}

# gh_download PATH: a GitHub URL that redirects to storage, such as a job's log. curl does not
# send the Authorization header on to the other host.
gh_download() {
  curl -fsSL -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
    "$GITHUB_API/$1"
}

# strip_ansi: stdin to stdout without terminal colour codes, which a log keeps and a quote cannot.
strip_ansi() { sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g'; }

# mint_token PERMISSIONS_JSON...: set GH_TOKEN to an installation token for $REPO with the first set
# of permissions the App has, and TOKEN_PERMS to that set; the sets go from the most to the least
# the agent wants. Call it directly, not in $(...): it sets variables.
mint_token() {
  local perms token
  for perms in "$@"; do
    if token=$(github_app_token "$REPO" "$perms" 2>/dev/null) && [ -n "$token" ]; then
      export GH_TOKEN=$token TOKEN_PERMS=$perms
      log "token for $REPO: $perms"
      return 0
    fi
  done
  die "${BOT_LOGIN%\[bot\]} has none of the permissions asked for on $REPO"
}

# token_can PERMISSION: whether the token mint_token logged includes it (TOKEN_PERMS holds the set).
token_can() { jq -e --arg p "$1" '.[$p] == "write"' <<<"${TOKEN_PERMS:-{\}}" >/dev/null; }

# trusted LOGIN ASSOCIATION: whether the agents take this person's word: a TRUSTED_USERS login, or
# an owner, member or collaborator of the repository.
trusted() {
  case " $TRUSTED_USERS " in *" $1 "*) return 0 ;; esac
  case "${2:-}" in OWNER | MEMBER | COLLABORATOR) return 0 ;; esac
  return 1
}

# upsert_comment NUMBER MARKER BODY: the App's one comment on issue or pull request NUMBER that
# holds MARKER, edited in place, or a new one. Prints its URL.
upsert_comment() {
  local number=$1 marker=$2 body=$3 id
  id=$(gh_api GET "repos/$REPO/issues/$number/comments?per_page=100" |
    jq -r --arg m "$marker" --arg b "$BOT_LOGIN" '[.[] | select(.user.login == $b and (.body | contains($m)))][0].id // empty')
  if [ -n "$id" ]; then
    gh_api PATCH "repos/$REPO/issues/comments/$id" "$(jq -n --arg b "$body" '{body: $b}')" | jq -r .html_url
  else
    gh_api POST "repos/$REPO/issues/$number/comments" "$(jq -n --arg b "$body" '{body: $b}')" | jq -r .html_url
  fi
}

# bot_identity: GIT_AUTHOR/COMMITTER as the App's bot user, whose noreply email needs its user id
# (not the App's), as marola-devkit's bot-token does.
bot_identity() {
  local id
  id=$(gh_api GET "users/${BOT_LOGIN/\[bot\]/%5Bbot%5D}" | jq -r .id)
  export GIT_AUTHOR_NAME=$BOT_LOGIN GIT_COMMITTER_NAME=$BOT_LOGIN
  export GIT_AUTHOR_EMAIL="$id+$BOT_LOGIN@users.noreply.github.com" GIT_COMMITTER_EMAIL="$id+$BOT_LOGIN@users.noreply.github.com"
}

# push_branch DIR BRANCH: push the branch with the installation token in a header, never in the URL
# (which logs and git's config could keep).
push_branch() {
  local auth
  auth=$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)
  git -C "$1" -c "http.extraHeader=Authorization: Basic $auth" push -q "$REPO_PUSH_URL" "HEAD:refs/heads/$2"
}

# ensure_label NAME COLOR DESCRIPTION: create the label in $REPO unless it exists.
ensure_label() {
  gh_api GET "repos/$REPO/labels/$1" >/dev/null 2>&1 && return 0
  gh_api POST "repos/$REPO/labels" \
    "$(jq -n --arg n "$1" --arg c "$2" --arg d "$3" '{name: $n, color: $c, description: $d}')" >/dev/null
}

# claude_json MODEL PROMPT_FILE TOOLS SCHEMA_FILE [FEEDBACK]: Claude Code headless in the current
# directory, which holds the inputs. Layer 1, what it can do: --restricted (no Bash or other
# code-running tool, no WebFetch, no settings files, file tools confined to this directory), only
# TOOLS, no MCP, a time limit. Layer 2, what it returns: JSON valid against SCHEMA_FILE, which
# Claude Code checks and retries itself. The house rules (prompts/_rules.md) come with every run;
# FEEDBACK, when the harness rejected an earlier answer, follows the prompt. The whole result
# (structured_output, modelUsage, num_turns, duration_ms) on stdout.
claude_json() {
  local model=$1 prompt=$2 tools=$3 schema=$4 feedback=${5:-} text
  text=$(cat "$prompt")
  if [ -n "$feedback" ]; then
    text+=$'\n\nYour previous answer was rejected by the harness:\n'"$feedback"$'\nAnswer again, fixing that.'
  fi
  timeout "${CLAUDE_TIMEOUT:-600}" "${CLAUDE_BIN:-claude}" -p "$text" \
    --model "$model" \
    --restricted \
    --tools "$tools" \
    --strict-mcp-config \
    --no-session-persistence \
    --append-system-prompt "$(cat "$AGENTS_HOME/prompts/_rules.md")" \
    --json-schema "$(jq -c . "$schema")" \
    --output-format json
}

# answer_of RESULT: the structured answer, or nothing when the run failed.
answer_of() {
  jq -ce 'select(.is_error != true) | .structured_output // (.result | fromjson? // empty)' <<<"$1" 2>/dev/null || true
}

# scrub: stdin to stdout with anything shaped like a credential replaced, whatever the prompt said.
scrub() {
  sed -E \
    -e 's/(gh[opsur]_|github_pat_)[A-Za-z0-9_]{20,}/[redacted]/g' \
    -e 's/sk-ant-[A-Za-z0-9_-]{10,}/[redacted]/g' \
    -e 's/(Bearer|token|Token)([ =:]+)[A-Za-z0-9._~+\/-]{20,}=*/\1\2[redacted]/g' \
    -e 's/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/[redacted]/g' \
    -e 's/-----BEGIN [A-Z ]*-----.*/[redacted]/' \
    -e 's/[A-Za-z0-9+\/]{60,}={0,2}/[redacted]/g'
}

# signature AGENT RESULT: who wrote the report, with what, where. Small, after the report.
signature() {
  local agent=$1 result=$2 models turns secs version os kernel cpus cpu mem limit image
  models=$(jq -r '(.modelUsage // {}) | keys | join(", ") | select(. != "")' <<<"$result" 2>/dev/null || true)
  turns=$(jq -r '.num_turns // empty' <<<"$result" 2>/dev/null || true)
  secs=$(jq -r '((.duration_ms // 0) / 1000 | floor)' <<<"$result" 2>/dev/null || echo 0)
  version=$("${CLAUDE_BIN:-claude}" --version 2>/dev/null | cut -d' ' -f1 || true)
  # shellcheck source=/dev/null
  os=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}")
  kernel="$(uname -s) $(uname -r) $(uname -m)"
  cpus=$(nproc 2>/dev/null || echo '?')
  cpu=$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | head -1)
  mem=$(awk '/^MemTotal/ {printf "%.1f GiB", $2 / 1048576}' /proc/meminfo 2>/dev/null || true)
  limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)
  case "$limit" in '' | max) limit= ;; *) limit="$((limit / 1048576)) MiB limit" ;; esac
  image=$(sed -n 's/^ *image: *//p' <<<"${AX_TASK_YAML:-}" | head -1)
  printf '<sub>%s · %s via Claude Code %s · %s turns, %ss · as %s (uid %s) in %s · %s · %s · %s vCPU%s · %s RAM%s%s</sub>\n' \
    "$agent" "${models:-${MODEL:-?}}" "${version:-?}" "${turns:-?}" "$secs" \
    "$(id -un)" "$(id -u)" "$(hostname 2>/dev/null || cat /etc/hostname)" "${os:-?}" "$kernel" "$cpus" "${cpu:+ ($cpu)}" "${mem:-?}" \
    "${limit:+, $limit}" "${image:+ · $image}"
}
