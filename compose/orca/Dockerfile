# Orca ADE (https://github.com/stablyai/orca) running headless as `orca serve`.
#
# Upstream ships no container image — only desktop artifacts. We install the
# official .deb rather than extracting the AppImage: the AppImage path in
# upstream's headless guide needs FUSE (absent in containers) plus a
# hand-maintained list of Electron shared libraries, while `apt-get install
# ./orca.deb` resolves upstream's own declared dependency set. The .deb also
# lands a plain ELF binary at /opt/Orca/orca-ide, so there is no AppRun
# wrapper printing extraction chatter ahead of the ready JSON on stdout.
FROM ubuntu:26.04

ARG ORCA_VERSION=1.4.188
ARG NODE_VERSION=24.19.0
ARG CLAUDE_CODE_VERSION=2.1.246
ARG GH_VERSION=2.98.0
ARG PUID=1000
ARG PGID=1000

ENV DEBIAN_FRONTEND=noninteractive

# Electron/Chromium runtime libraries. The .deb declares only python3-gi,
# at-spi2-core, xdotool, xclip and xvfb — electron-builder does not emit the
# GTK/NSS/GBM dependencies the binary actually dlopens, so they are listed
# here explicitly. Ubuntu 24.04 renamed several of these to the `t64` suffix
# during the 64-bit time_t transition; the old names do not resolve on noble.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg file jq xz-utils \
      git openssh-client rsync less procps tini \
      python3 python3-venv python3-pip \
      build-essential \
      xvfb xdotool xclip at-spi2-core python3-gi gir1.2-atspi-2.0 \
      libgtk-3-0t64 libglib2.0-0t64 libnss3 libnspr4 libasound2t64 \
      libgbm1 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 \
      libxfixes3 libxrandr2 libxshmfence1 libx11-xcb1 libxtst6 \
      libatk1.0-0t64 libatk-bridge2.0-0t64 libatspi2.0-0t64 \
      libcups2t64 libpango-1.0-0 libcairo2 libsecret-1-0 libgcc-s1 \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI only — the daemon lives in the privileged `orca-dind` sidecar
# (see compose.yaml). buildx and compose plugins come along so agents can run
# `docker build` and `docker compose` inside a worktree.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
         -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu noble stable" \
         > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
         docker-ce-cli docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI. Agents need `gh` for PRs, issues and releases, but the
# load-bearing part is `gh auth setup-git`: this container has no SSH key, so
# git reaches GitHub over HTTPS and gh's credential helper is the only thing
# that authenticates a push. Installed from the official release tarball for
# the same reason as Node — no third-party apt repo to trust or key to
# rotate. Pinned as a build arg, and carrying the same blind spot as
# ORCA_VERSION: neither Renovate nor check.sh's pinning report can see it.
RUN curl -fL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
      -o /tmp/gh.tar.gz \
    && tar -xzf /tmp/gh.tar.gz -C /tmp \
    && install -m 0755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
    && rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_amd64"

# Node is the runtime for most CLI coding agents (Claude Code, Codex, …), which
# Orca launches into a terminal. Installed from the official static tarball so
# there is no third-party apt repo to trust or key to rotate.
RUN curl -fL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
      -o /tmp/node.tar.xz \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
         --exclude=CHANGELOG.md --exclude=LICENSE --exclude=README.md \
    && rm /tmp/node.tar.xz \
    && npm install -g npm@latest \
    && npm cache clean --force

# Claude Code, the agent this stack exists to run. Orca resolves each agent by
# name on PATH, so one that is not installed simply never appears in its agent
# list. Baked into the image rather than left to a runtime `npm i -g`: the
# service account cannot write root-owned /usr/local anyway.
#
# --allow-scripts is load-bearing. npm 12 blocks postinstall scripts by
# default, and the platform-native binary is fetched *by* that postinstall, so
# without the flag the install reports "added 2 packages" and leaves a
# launcher that exits with "claude native binary not installed" — a build that
# succeeds and produces a broken CLI.
#
# Pinned like ORCA_VERSION and carrying the same caveat: a build arg is
# invisible to Renovate and to check.sh's pinning report, so bump it by hand.
RUN npm install -g --allow-scripts=@anthropic-ai/claude-code \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm cache clean --force

RUN curl -fL "https://github.com/stablyai/orca/releases/download/v${ORCA_VERSION}/orca-ide_${ORCA_VERSION}_amd64.deb" \
      -o /tmp/orca.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/orca.deb \
    && rm -f /tmp/orca.deb \
    && rm -rf /var/lib/apt/lists/*
# Note: /opt/Orca/chrome-sandbox is deliberately left non-setuid. It cannot
# work in this container regardless (see the --no-sandbox rationale in
# entrypoint.sh), and a setuid-root binary that never functions is worse than
# no setuid binary at all.

# Unprivileged service account. PUID/PGID default to 1000 so the bind-mounted
# host coding directory stays writable by its real owner rather than by root.
# ubuntu:24.04 ships an `ubuntu` user already squatting on uid/gid 1000.
RUN userdel -r ubuntu 2>/dev/null || true; \
    groupadd -g "${PGID}" orca 2>/dev/null || true; \
    useradd -u "${PUID}" -g "${PGID}" -m -d /home/orca -s /bin/bash orca

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

EXPOSE 6768

# tini reaps the agent shells, Xvfb and Chromium helpers that Orca spawns;
# without a real init they accumulate as zombies under a long-lived PID 1.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["serve", "--port", "6768"]
