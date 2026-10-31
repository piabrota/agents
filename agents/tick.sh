#!/usr/bin/env bash
# tick: every agent that watches GitHub, one after the other in one pod, so they never compete for
# the task quota. Each exits in seconds when it has nothing to do, without calling Claude. One that
# fails is logged and the others still run; the tick then fails, so the task shows Failed.
set -uo pipefail
AGENTS=${TICK_AGENTS:-feedback deploy-doctor pr-reviewer mentions mirror-keeper flake-annotator}
failed=
for agent in $AGENTS; do
  printf '%s == %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$agent" >&2
  "$AGENTS_HOME/agents/$agent.sh" || failed+=" $agent"
done
if [ -n "$failed" ]; then
  printf '%s tick: failed:%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$failed" >&2
  exit 1
fi
