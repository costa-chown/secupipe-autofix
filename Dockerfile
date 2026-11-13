# Secupipe Autofix, Code-Scan und Architektur-Review: laufen als Container-Job auf dem CI-Runner des Kunden (GitHub Actions, GitLab CI,
# Jenkins, Azure DevOps). Enthält git, Node/npm, Go, Python/pip und Claude Code für den optionalen KI-Agenten.
#
#   docker build -t secupipe-autofix .
#   docker run --rm -v "$PWD:/repo" -w /repo -e SECUPIPE_TOKEN -e REPO=acme/shop -e GITHUB_TOKEN secupipe-autofix
#   docker run --rm -v "$PWD:/repo" -w /repo -e SECUPIPE_TOKEN -e REPO=acme/shop -e ANTHROPIC_API_KEY \
#     --entrypoint secupipe-codescan secupipe-autofix
#   docker run --rm -v "$PWD:/repo" -w /repo -e SECUPIPE_TOKEN -e REPO=acme/shop -e ANTHROPIC_API_KEY \
#     --entrypoint secupipe-archreview secupipe-autofix

FROM golang:1.27.3-trixie AS go

FROM node:24-trixie-slim
ARG VERSION=dev
ARG CLAUDE_CODE_VERSION=2.1.319
LABEL org.opencontainers.image.title="secupipe-autofix" \
      org.opencontainers.image.description="Fix-PRs für Schwachstellen aus Secupipe, optional mit KI-Agent" \
      org.opencontainers.image.source="https://github.com/costa-chown/secupipe-autofix" \
      org.opencontainers.image.version="${VERSION}"

RUN apt-get update \
 && apt-get install -y --no-install-recommends bash ca-certificates curl git jq python3 python3-pip openssh-client \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g --no-audit --no-fund "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force
COPY --from=go /usr/local/go /usr/local/go
ENV PATH=/usr/local/go/bin:/root/go/bin:$PATH \
    GOTOOLCHAIN=auto \
    DISABLE_AUTOUPDATER=1 \
    DISABLE_TELEMETRY=1
COPY autofix.sh /usr/local/bin/secupipe-autofix
COPY codescan.sh /usr/local/bin/secupipe-codescan
COPY archreview.sh /usr/local/bin/secupipe-archreview
COPY archfix.sh /usr/local/bin/secupipe-archfix
ENTRYPOINT ["/usr/local/bin/secupipe-autofix"]
