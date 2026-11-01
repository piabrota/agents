# piabrota's agents: bash and curl around Claude Code headless (README). One image; a rax task picks
# the agent with its command, `agent deploy-doctor` or `agent health-digest`.
#
#   docker build -t agents .
# Agent Orchestrator's daemon and CLI for issue-worker, from a pinned commit (v0.14.8). Only `ao`,
# in pure Go: the desktop app, Node and the release's Electron bundle stay out of the image.
FROM golang:1.27.1-bookworm@sha256:8d48e12ec56735e9358640898b9d9b9fcca110612ed8a5567438c0a1baa24e66 AS ao
ARG AO_COMMIT=403a8c8385ed43bbf9e9289e3f3bbaa6517dc437
RUN set -eu; \
    git init -q /src; cd /src; \
    git fetch -q --depth 1 https://github.com/OrchestratorInc/agent-orchestrator "$AO_COMMIT"; \
    git checkout -q FETCH_HEAD; \
    cd backend; CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /ao ./cmd/ao

FROM debian:bookworm-slim

# Claude Code's standalone binary (no Node), pinned with its checksum from the release's
# manifest.json. To update: change the version and both sums together.
ARG CLAUDE_CODE_VERSION=2.1.316
ARG CLAUDE_CODE_SHA256_X64=fd13c70000fec3f2116dfbcbb6121210b4a29328bf0e46210a59dd594a67d824
ARG CLAUDE_CODE_SHA256_ARM64=55cdb8e162d190432696ea54010e0fca2e18d06fa7a7127fd563b9ffd4f22624
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq openssl postgresql-client tmux \
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) platform=linux-x64 sum=$CLAUDE_CODE_SHA256_X64 ;; \
      arm64) platform=linux-arm64 sum=$CLAUDE_CODE_SHA256_ARM64 ;; \
      *) echo "no Claude Code build for $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/claude \
      "https://downloads.claude.ai/claude-code-releases/$CLAUDE_CODE_VERSION/$platform/claude"; \
    echo "$sum  /usr/local/bin/claude" | sha256sum -c -; \
    chmod 755 /usr/local/bin/claude

COPY --from=ao /ao /usr/local/bin/ao
# issue-worker's limits, as Claude Code's managed settings: read-only to the user the agents run as,
# and above every other setting. They bind every agent; no other agent uses a denied tool.
COPY rules/worker-settings.json /etc/claude-code/managed-settings.json

# A user of its own: the pods run with runAsNonRoot.
RUN useradd --uid 10001 --create-home --home-dir /home/agent agent
COPY bin /opt/agents/bin
COPY lib /opt/agents/lib
COPY agents /opt/agents/agents
COPY prompts /opt/agents/prompts
COPY rules /opt/agents/rules

USER 10001
WORKDIR /home/agent
# No self-update, telemetry or other traffic Claude Code can do without.
ENV AGENTS_HOME=/opt/agents \
    PATH=/opt/agents/bin:$PATH \
    DISABLE_AUTOUPDATER=1 \
    DISABLE_TELEMETRY=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
ENTRYPOINT ["/opt/agents/bin/agent"]
