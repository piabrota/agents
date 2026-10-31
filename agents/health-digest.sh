#!/usr/bin/env bash
# health-digest: once a day, a short comment on $REPO's open issue labelled health-digest (made the
# first time), from the box's health snapshot, the last deploys and the previous digest, so it can
# say what changed. Claude Code reads those files and answers in prompts/health-digest.schema.json;
# the harness writes the comment from that, scrubbed of anything shaped like a credential, and
# signs it. Two answers that do not fit the schema fail the run instead of posting.
# shellcheck source=lib/common.sh
. "$AGENTS_HOME/lib/common.sh"
# shellcheck source=lib/github-app.sh
. "$AGENTS_HOME/lib/github-app.sh"

MODEL=${HEALTH_DIGEST_MODEL:-claude-haiku-5-5}
LABEL=health-digest
SNAPSHOT_NAMESPACE=${SNAPSHOT_NAMESPACE:-ax-tasks}
SNAPSHOT_CONFIGMAP=${SNAPSHOT_CONFIGMAP:-health-snapshot}

need CLAUDE_CODE_OAUTH_TOKEN
GH_TOKEN=$(github_app_token "$REPO" '{"actions":"read","issues":"write"}')
export GH_TOKEN

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The snapshot: a file (HEALTH_SNAPSHOT_FILE), or the ConfigMap the box writes, read with the pod's
# service account token.
if [ -n "${HEALTH_SNAPSHOT_FILE:-}" ]; then
  cp "$HEALTH_SNAPSHOT_FILE" "$work/snapshot.md"
else
  sa=/var/run/secrets/kubernetes.io/serviceaccount
  [ -r "$sa/token" ] || die "no snapshot: set HEALTH_SNAPSHOT_FILE, or run with a service account that reads $SNAPSHOT_NAMESPACE/$SNAPSHOT_CONFIGMAP"
  curl -fsS --cacert "$sa/ca.crt" -H "Authorization: Bearer $(cat "$sa/token")" \
    "https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT/api/v1/namespaces/$SNAPSHOT_NAMESPACE/configmaps/$SNAPSHOT_CONFIGMAP" |
    jq -er '.data["snapshot.md"]' >"$work/snapshot.md"
fi

gh_api GET "repos/$REPO/actions/workflows/deploy.yml/runs?per_page=10" |
  jq '[.workflow_runs[] | {created_at, conclusion, display_title, html_url}]' >"$work/deploys.json"

ensure_label "$LABEL" 0e8a16 "The box's daily health, from piabrota/agents' health-digest"
issue=$(gh_api GET "repos/$REPO/issues?labels=$LABEL&state=open&per_page=1" | jq -r '.[0].number // empty')
if [ -z "$issue" ]; then
  issue=$(gh_api POST "repos/$REPO/issues" "$(jq -n --arg l "$LABEL" '{
    title: "VPS health digest",
    body: "One comment a day on the box'"'"'s health, from piabrota/agents'"'"' health-digest. Pin this issue; close it to start a new one.",
    labels: [$l]}')" | jq -r .number)
  log "opened issue #$issue"
fi
since=$(date -u -d "-3 days" +%Y-%m-%dT%H:%M:%SZ)
gh_api GET "repos/$REPO/issues/$issue/comments?since=$since&per_page=100" |
  jq -r 'last.body // "There is no previous digest: this is the first."' >"$work/previous.md"

answer=
for try in 1 2; do
  log "writing the digest with $MODEL (try $try)"
  result=$(cd "$work" && claude_json "$MODEL" "$AGENTS_HOME/prompts/health-digest.md" "Read" \
    "$AGENTS_HOME/prompts/health-digest.schema.json" \
    "${answer:+the answer was missing or did not fit the schema}") || result='{"is_error": true}'
  answer=$(answer_of "$result")
  [ -n "$answer" ] && break
  answer=rejected
done
[ "$answer" != rejected ] || die "no digest that fits the schema, twice"

body=$(jq -r '"**\(.date): \(.status)**, \(.reason)\n\n"
  + "- **Services:** \(.services)\n"
  + "- **Memory and disk:** \(.memory_and_disk)\n"
  + "- **Kubernetes:** \(.kubernetes)\n"
  + "- **Deploys:** \(.deploys)\n"
  + "- **Errors:** \(.errors)"
  + (if (.watch // "") != "" then "\n- **Watch:** \(.watch)" else "" end)' <<<"$answer" | scrub)
body=$(printf '%s\n\n%s\n' "$body" "$(signature health-digest "$result")")
gh_api POST "repos/$REPO/issues/$issue/comments" "$(jq -n --arg b "$body" '{body: $b}')" |
  jq -r '"digest: \(.html_url)"' >&2
