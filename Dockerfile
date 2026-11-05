# syntax=docker/dockerfile:1

# Hardened image for riking/AutoDelete (https://github.com/riking/AutoDelete).
#
# How this differs from ksurl/autodelete-discord:
# - The bot is compiled once, at image build time, from one pinned upstream
#   commit. The container never downloads or compiles code when it starts.
# - Both base images are pinned by digest. Dependabot opens PRs to bump them.
# - The runtime image is distroless/static: no shell, package manager, git or
#   Go toolchain. The bot runs as UID/GID 65532, not root.
# - gorilla/websocket is raised from v1.5.0 to v1.5.3 to fix GO-2026-6278,
#   the only vulnerability govulncheck finds reachable from the bot's code.
# - The Go runtime uses current security defaults (see the go.mod step).

# To update the bot, review the upstream changes and set a full 40-character
# commit SHA here. The source stage fails the build if the checkout differs.
ARG AUTODELETE_REPO=https://github.com/riking/AutoDelete.git
ARG AUTODELETE_COMMIT=8cd5bdc63d91ab48562c3895ef115362abc0c194

# ---------------------------------------------------------------------------
# Source stage. Runs on the builder's own architecture. The build stage
# cross-compiles from here, so multi-arch builds need no QEMU emulation.
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM golang:1.27.3-alpine3.24@sha256:fa4881266890ef051f0ce63afdfaccb69bbe8186084387f4fafd60d7ecbabc71 AS source

ARG AUTODELETE_REPO
ARG AUTODELETE_COMMIT

RUN apk add --no-cache git

WORKDIR /src
RUN git init -q . \
 && git fetch -q --depth 1 "$AUTODELETE_REPO" "$AUTODELETE_COMMIT" \
 && git checkout -q FETCH_HEAD \
 && test "$(git rev-parse HEAD)" = "$AUTODELETE_COMMIT"

# Two changes to upstream's go.mod, nothing else in the source is touched:
# 1. gorilla/websocket v1.5.0 -> v1.5.3. go get checks the new module against
#    sum.golang.org and the grep pins its expected hash.
# 2. godebug default=go1.27. Upstream's go.mod says "go 1.13", which makes
#    Go 1.27 keep old runtime defaults for compatibility, such as accepting
#    SHA-1 TLS signatures and RSA keys under 1024 bits. This switches the
#    runtime to current Go defaults without changing language semantics.
# Then every module is downloaded once and checked against go.sum.
RUN go get github.com/gorilla/websocket@v1.5.3 \
 && grep -qxF 'github.com/gorilla/websocket v1.5.3 h1:saDtZ6Pbx/0u+bgYQ3q96pZgCzfhKXGPqt7kZ72aNNg=' go.sum \
 && go mod edit -godebug=default=go1.27 \
 && go mod download \
 && go mod verify

# ---------------------------------------------------------------------------
# Build stage.
# ---------------------------------------------------------------------------
FROM source AS build

ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT

RUN set -eu; \
    if [ "$TARGETARCH" = "arm" ]; then export GOARM="${TARGETVARIANT#v}"; fi; \
    CGO_ENABLED=0 GOOS="$TARGETOS" GOARCH="$TARGETARCH" \
      go build -trimpath -ldflags="-s -w -buildid=" -o /out/autodelete ./cmd/autodelete; \
    mkdir -p /out/data; \
    cp config.example.yml /out/config.example.yml

# ---------------------------------------------------------------------------
# Optional stage: `docker build --target vulncheck .` runs govulncheck against
# exactly the source and dependencies the image is built from. It exits
# non-zero if the bot's code can reach a known vulnerability.
# ---------------------------------------------------------------------------
FROM source AS vulncheck
RUN go install golang.org/x/vuln/cmd/govulncheck@v1.9.0 \
 && govulncheck ./cmd/autodelete

# ---------------------------------------------------------------------------
# Runtime stage. This is the default target.
# ---------------------------------------------------------------------------
FROM gcr.io/distroless/static-debian13:nonroot@sha256:25ac8f0c3b2334a9eb05452266bd4697864a8c8ef0ef71e5e6480d7f92868329

ARG AUTODELETE_COMMIT
LABEL org.opencontainers.image.source="https://github.com/outpoints/docker-autodelete-discord" \
      org.opencontainers.image.description="Hardened image for the AutoDelete Discord bot" \
      org.opencontainers.image.licenses="MIT" \
      io.github.riking.autodelete.commit="$AUTODELETE_COMMIT"

# The distroless base defaults to the nonroot user. Switch to root for the
# setup steps so /app itself is root-owned and the bot can't replace files in it.
USER 0:0

# The bot reads ./config.yml and keeps per-channel settings in ./data.
WORKDIR /app

# The binary stays owned by root so the bot can't modify it. Only data/ is
# writable by the bot's user.
COPY --from=build /out/autodelete /out/config.example.yml /app/
COPY --from=build --chown=65532:65532 /out/data /app/data

USER 65532:65532
VOLUME /app/data
EXPOSE 2202

ENTRYPOINT ["/app/autodelete"]
