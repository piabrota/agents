# shellcheck shell=bash
# The agents' memory: events they log (a diagnosis, a review, a digest, a reply, a fix) and the
# feedback people give on them, read back by later runs. AGENTS_DB_URL picks the store: a
# postgres:// URL (PGX on the box, written into the Secret ax-tasks/agents-memory by nix-os) or
# file:///dir (a JSON-lines file, for tests). Unset, there is no memory and the agents work as
# before. Memory is a help, never a gate: a store that fails is logged and skipped.

mem_backend() {
  case "${AGENTS_DB_URL:-}" in
    postgres://* | postgresql://*) echo psql ;;
    file://*) echo file ;;
    *) echo none ;;
  esac
}

# mem_psql [-v NAME=VALUE...] < SQL: psql substitutes :'NAME' (quoted) only in SQL it reads, not in -c.
mem_psql() {
  psql "$AGENTS_DB_URL" -qAtX -v ON_ERROR_STOP=1 "$@" -f -
}

MEM_READY=
mem_init() {
  [ -n "$MEM_READY" ] && return 0
  case "$(mem_backend)" in
    psql)
      mem_psql >/dev/null <<'SQL' || return 1
create table if not exists agent_events (
  id bigserial primary key,
  agent text not null,
  kind text not null,
  subject text not null,
  data text not null,
  at timestamptz not null default now()
);
SQL
      ;;
    file) mkdir -p "${AGENTS_DB_URL#file://}" || return 1 ;;
    none) return 1 ;;
  esac
  MEM_READY=1
}

# mem_log AGENT KIND SUBJECT JSON: record an event.
mem_log() {
  local agent=$1 kind=$2 subject=$3 data=$4
  mem_init 2>/dev/null || return 0
  data=$(jq -c . <<<"$data" 2>/dev/null) || data=$(jq -cn --arg t "$4" '{text: $t}')
  case "$(mem_backend)" in
    psql)
      mem_psql -v a="$agent" -v k="$kind" -v s="$subject" -v d="$data" >/dev/null <<'SQL' ||
insert into agent_events (agent, kind, subject, data) values (:'a', :'k', :'s', :'d');
SQL
        log "memory: could not record $agent/$kind/$subject"
      ;;
    file)
      jq -cn --arg a "$agent" --arg k "$kind" --arg s "$subject" --argjson d "$data" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{agent: $a, kind: $k, subject: $s, data: $d, at: $at}' \
        >>"${AGENTS_DB_URL#file://}/events.jsonl"
      ;;
  esac
}

# mem_recent AGENT KIND N: the N newest events of that agent and kind, newest first, as a JSON
# array of {subject, data, at}. AGENT "*" means any agent. An empty array without memory.
mem_recent() {
  local agent=$1 kind=$2 n=$3
  mem_init 2>/dev/null || {
    echo '[]'
    return 0
  }
  case "$(mem_backend)" in
    psql)
      # Tab-separated plain columns: the data is compact JSON, which escapes any tab in it.
      mem_psql -F $'\t' -v a="$agent" -v k="$kind" -v n="$n" <<'SQL' |
select subject, to_char(at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), data
from agent_events where (:'a' = '*' or agent = :'a') and kind = :'k'
order by id desc limit :n;
SQL
        jq -Rn '[inputs | split("\t") | {subject: .[0], at: .[1], data: (.[2:] | join("\t") | fromjson? // .)}]' ||
        echo '[]'
      ;;
    file)
      local f=${AGENTS_DB_URL#file://}/events.jsonl
      [ -f "$f" ] || {
        echo '[]'
        return 0
      }
      jq -s --arg a "$agent" --arg k "$kind" --argjson n "$n" \
        '[.[] | select(($a == "*" or .agent == $a) and .kind == $k)] | reverse | .[:$n] | map({subject, data, at})' "$f"
      ;;
  esac
}

# mem_has AGENT KIND SUBJECT: whether that event was recorded.
mem_has() {
  mem_recent "$1" "$2" 500 | jq -e --arg s "$3" 'any(.[]; .subject == $s)' >/dev/null
}

# lessons AGENT: Markdown of the feedback people gave on that agent's reports, newest first, for
# the agent to read before it writes again. Empty without feedback.
lessons() {
  mem_recent "$1" feedback 10 | jq -r 'if length == 0 then "No feedback yet." else
    "People judged these past reports wrong. Do not repeat the mistake.\n\n" +
    (map("- \(.at[:10]), \(.subject): the report said: \(.data.report[:600] | gsub("\n"; " "))" +
      (if (.data.said // "") != "" then "\n  They said: \(.data.said[:600] | gsub("\n"; " "))" else "" end))
     | join("\n")) end'
}
