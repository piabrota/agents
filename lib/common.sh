# shellcheck shell=bash
# Shared by the agents: logging, the GitHub API as piabrota-ops, and Claude Code headless.
set -euo pipefail

AGENTS_HOME=${AGENTS_HOME:-/opt/agents}
GITHUB_API=${GITHUB_API:-https://api.github.com}
# The repository the agents watch and report on.
REPO=${REPO:-piabrota/nix-os}
REPO_GIT_URL=${REPO_GIT_URL:-https://github.com/$REPO}

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

# ensure_label NAME COLOR DESCRIPTION: create the label in $REPO unless it exists.
ensure_label() {
  gh_api GET "repos/$REPO/labels/$1" >/dev/null 2>&1 && return 0
  gh_api POST "repos/$REPO/labels" \
    "$(jq -n --arg n "$1" --arg c "$2" --arg d "$3" '{name: $n, color: $c, description: $d}')" >/dev/null
}

# claude_run MODEL PROMPT_FILE TOOLS: Claude Code headless in the current directory, which holds
# the inputs, with only TOOLS (read-only ones) allowed and no MCP servers. The answer on stdout.
claude_run() {
  local model=$1 prompt=$2 tools=$3
  "${CLAUDE_BIN:-claude}" -p "$(cat "$prompt")" \
    --model "$model" \
    --allowedTools "$tools" \
    --strict-mcp-config \
    --no-session-persistence \
    --output-format text
}
