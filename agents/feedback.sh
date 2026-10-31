#!/usr/bin/env bash
# feedback: turns what people say about the agents' reports into lessons in memory, which those
# agents read before they write again (lessons in lib/memory.sh). Two signals, from trusted people
# only: the label `report-wrong` on an issue the App opened, and a 👎 on a comment the App posted.
# The person's own words (their comments on the issue) go with the report. Each is recorded once.
# shellcheck source=lib/common.sh
. "$AGENTS_HOME/lib/common.sh"
# shellcheck source=lib/github-app.sh
. "$AGENTS_HOME/lib/github-app.sh"
# shellcheck source=lib/memory.sh
. "$AGENTS_HOME/lib/memory.sh"

LABEL=report-wrong
LOOKBACK_DAYS=${FEEDBACK_LOOKBACK_DAYS:-14}

if [ "$(mem_backend)" = none ]; then
  log "no memory (AGENTS_DB_URL): nothing to keep feedback in"
  exit 0
fi
mint_token '{"issues":"write"}'
ensure_label "$LABEL" e99695 "A piabrota-ops report that was wrong: the agent learns from it"

# The agent that wrote a report, from its signature: <sub>NAME · ...
agent_of() { grep -oE '<sub>[a-z-]+ ·' <<<"$1" | head -1 | sed -E 's/<sub>([a-z-]+) ·/\1/'; }

said_on() {
  gh_api GET "repos/$REPO/issues/$1/comments?per_page=100" |
    jq -r --arg b "$BOT_LOGIN" '[.[] | select(.user.login != $b and (.author_association | IN("OWNER", "MEMBER", "COLLABORATOR")))
      | .body] | join("\n\n")'
}

# 1. Issues the App opened, labelled report-wrong.
while IFS= read -r issue; do
  [ -n "$issue" ] || continue
  number=$(jq -r .number <<<"$issue")
  subject="issue#$number"
  body=$(jq -r .body <<<"$issue")
  agent=$(agent_of "$body")
  [ -n "$agent" ] || continue
  mem_has "$agent" feedback "$subject" && continue
  mem_log "$agent" feedback "$subject" \
    "$(jq -n --arg r "$(jq -r '"\(.title)\n\n\(.body)"' <<<"$issue")" --arg s "$(said_on "$number")" '{report: $r[:4000], said: $s[:2000]}')"
  log "feedback: $agent, $subject"
done < <(gh_api GET "repos/$REPO/issues?labels=$LABEL&state=all&per_page=50" |
  jq -c --arg b "$BOT_LOGIN" '.[] | select(.user.login == $b)')

# 2. Comments the App posted in the last days with a 👎 from a trusted person.
since=$(date -u -d "-$LOOKBACK_DAYS days" +%Y-%m-%dT%H:%M:%SZ)
while IFS= read -r comment; do
  [ -n "$comment" ] || continue
  id=$(jq -r .id <<<"$comment")
  subject="comment#$id"
  body=$(jq -r .body <<<"$comment")
  agent=$(agent_of "$body")
  [ -n "$agent" ] || continue
  mem_has "$agent" feedback "$subject" && continue
  who=$(gh_api GET "repos/$REPO/issues/comments/$id/reactions?content=-1&per_page=100" | jq -r '.[].user.login')
  ok=
  for login in $who; do trusted "$login" && ok=1; done
  [ -n "$ok" ] || continue
  number=$(jq -r '.issue_url | split("/") | last' <<<"$comment")
  mem_log "$agent" feedback "$subject" \
    "$(jq -n --arg r "$body" --arg s "$(said_on "$number")" '{report: $r[:4000], said: $s[:2000]}')"
  log "feedback: $agent, $subject"
done < <(gh_api GET "repos/$REPO/issues/comments?since=$since&per_page=100" |
  jq -c --arg b "$BOT_LOGIN" '.[] | select(.user.login == $b and ((.reactions["-1"] // 0) > 0))')
