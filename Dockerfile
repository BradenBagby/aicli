# syntax=docker/dockerfile:1

# Build stage: compile git-status-watch (gsw) from source
FROM rust:latest AS gsw-builder
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    cargo install git-status-watch

# Build stage: compile diffwatch from source
FROM golang:latest AS diffwatch-builder
RUN --mount=type=cache,target=/root/go/pkg/mod \
    go install github.com/deemkeen/diffwatch/cmd/diffwatch@latest

# Shared base: full package install, used by all ubuntu fetch stages and the final image
FROM ubuntu:24.04 AS base
ARG TZ=America/Denver
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=${TZ}
RUN apt-get update && apt-get upgrade -y && apt-get install -y \
    aggregate \
    build-essential \
    bubblewrap \
    ca-certificates \
    curl \
    dnsutils \
    fzf \
    gh \
    git \
    glab \
    gnupg2 \
    iproute2 \
    ipset \
    iptables \
    iputils-ping \
    jq \
    less \
    libasound2t64 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libatspi2.0-0 \
    libcairo-gobject2 \
    libcairo2 \
    libcups2 \
    libdbus-1-3 \
    libdrm2 \
    libfontconfig1 \
    libfreetype6 \
    libgbm1 \
    libgdk-pixbuf-2.0-0 \
    libgtk-3-0 \
    libnss3 \
    libnspr4 \
    libpango-1.0-0 \
    libpangocairo-1.0-0 \
    libx11-6 \
    libx11-xcb1 \
    libxcomposite1 \
    libxcursor1 \
    libxdamage1 \
    libxcb-shm0 \
    libxcb1 \
    libxext6 \
    libxfixes3 \
    libxi6 \
    libxkbcommon0 \
    libxrandr2 \
    libxrender1 \
    libxshmfence1 \
    man-db \
    mtr \
    nmap \
    procps \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    tmux \
    tree \
    rsync \
    socat \
    sudo \
    tcpdump \
    unzip \
    vim \
    && rm -rf /var/lib/apt/lists/*

# Build stage: download opencode binary
FROM base AS opencode-builder
RUN curl -fsSL https://opencode.ai/install | bash

# Build stage: download kilo binary
FROM base AS kilo-builder
RUN curl -fsSL https://kilo.ai/cli/install | bash

# Build stage: download engram binary
FROM base AS engram-builder
RUN ENGRAM_VERSION=$(curl -s https://api.github.com/repos/Gentleman-Programming/engram/releases/latest \
      | grep '"tag_name"' | cut -d'"' -f4 | tr -d 'v') && \
    curl -fsSL "https://github.com/Gentleman-Programming/engram/releases/download/v${ENGRAM_VERSION}/engram_${ENGRAM_VERSION}_linux_amd64.tar.gz" \
      | tar -xz -C /tmp && \
    mv /tmp/engram /usr/local/bin/engram && \
    chmod +x /usr/local/bin/engram

FROM base

ARG GITCONFIG
ARG TZ=America/Denver

# Use interactive bash for all RUN so .bashrc is sourced and PATH (nvm, pnpm, bun) is set.
SHELL ["/bin/bash", "-i", "-c"]

# Create ai user and group with uid/gid 10000
RUN groupadd -g 10000 ai && \
    useradd -u 10000 -g 10000 -md /home/ai -s /bin/bash ai && \
    usermod -aG sudo ai && \
    sed -i 's|^ai:[^:]*:|ai:$y$j9T$zBOEQebG0rUTnLYW/l1WC/$.uCxX/KfgbU6d8qp/cRVGGWdravYJc9tVhrU5c7ybZ9:|' /etc/shadow

RUN mkdir -p \
    /home/ai/.ssh \
    /home/ai/.ai \
    /home/ai/.cache/kilo \
    /home/ai/.cache/opencode \
    /home/ai/.claude/skills \
    /home/ai/.codex/skills \
    /home/ai/.config/kilo \
    /home/ai/.config/opencode \
    /home/ai/.cursor/rules \
    /home/ai/.gemini/skills \
    /home/ai/.local/share/kilo \
    /home/ai/.local/share/opencode \
    /home/ai/.local/state/kilo \
    /home/ai/.local/state/opencode \
    /workspace \
    && chmod 700 /home/ai/.ssh

# Truecolor + agentic cli functions
RUN cat >> /home/ai/.bashrc <<'EOF'
export COLORTERM=truecolor
agent() { TID="$(openssl rand -hex 24)" PROVIDER=cursor command agent --yolo "$@"; }
claude() { cp ~/.claude/claude.json ~/.claude/settings.json; TID="$(openssl rand -hex 24)" PROVIDER=claude command claude --dangerously-skip-permissions "$@"; }
codex() { TID="$(openssl rand -hex 24)" PROVIDER=codex command codex --dangerously-bypass-approvals-and-sandbox "$@"; }
cursor() { TID="$(openssl rand -hex 24)" PROVIDER=cursor command agent --yolo "$@"; }
gemini() { TID="$(openssl rand -hex 24)" PROVIDER=gemini command gemini --yolo "$@"; }
kilo() { auth_file="$HOME/.local/share/kilo/auth.json"; mkdir -p "$(dirname "$auth_file")"; if [ -f "$auth_file" ] && grep -q APIKEY "$auth_file"; then [ -z "${MINIMAX_API_KEY:-}" ] && read -s -p "MiniMax API key: " MINIMAX_API_KEY && echo; sed -i "s/APIKEY/$MINIMAX_API_KEY/g" "$auth_file"; fi; TID="$(openssl rand -hex 24)" PROVIDER=kilo command kilo "$@"; }
opencode() { auth_file="$HOME/.local/share/opencode/auth.json"; mkdir -p "$(dirname "$auth_file")"; if [ -f "$auth_file" ] && grep -q APIKEY "$auth_file"; then [ -z "${MINIMAX_API_KEY:-}" ] && read -s -p "MiniMax API key: " MINIMAX_API_KEY && echo; sed -i "s/APIKEY/$MINIMAX_API_KEY/g" "$auth_file"; fi; TID="$(openssl rand -hex 24)" PROVIDER=opencode command opencode "$@"; }
EOF

# Copy and set up firewall script
# TODO: figure out a way to use this but not completely hamper the ai
#COPY init-firewall.sh /usr/local/sbin/
#RUN chmod +x /usr/local/sbin/init-firewall.sh && \
#  echo "ai ALL=(root) NOPASSWD: /usr/local/sbin/init-firewall.sh" > /etc/sudoers.d/ai-firewall && \
#  chmod 0440 /etc/sudoers.d/ai-firewall

# Install system Node.js 24 via NodeSource as root, then install codex, gemini, and agent-browser
# as npm globals into /usr/local/bin + /usr/local/lib/node_modules — not volume-mounted, always
# reflects the latest versions on every rebuild.
# Placed BEFORE builder COPYs so golang/rust base image refreshes don't bust this expensive layer.
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*
ENV PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/playwright
RUN --mount=type=cache,target=/root/.npm \
    npm install -g @openai/codex @google/gemini-cli agent-browser
RUN arch="$(dpkg --print-architecture)" && \
    if [ "$arch" = "arm64" ]; then \
      PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/playwright npx --yes playwright install chromium && \
      chrome_bin="$(find /usr/local/share/playwright -type f -path '*/chrome-linux/chrome' | head -n 1)" && \
      test -n "$chrome_bin" && \
      ln -sf "$chrome_bin" /usr/local/bin/agent-browser-chrome && \
      echo 'export AGENT_BROWSER_EXECUTABLE_PATH=/usr/local/bin/agent-browser-chrome' >> /home/ai/.bashrc; \
    else \
      agent-browser install --with-deps; \
    fi

# Set timezone from build arg (e.g. America/New_York); leave as UTC if TZ=UTC or unset
RUN if [ -n "$TZ" ] && [ "$TZ" != "UTC" ]; then \
      ln -sf /usr/share/zoneinfo/"$TZ" /etc/localtime && echo "$TZ" > /etc/timezone; \
    fi

# Install gitlogue (Git history visualizer) as root so it lands in /usr/local/bin,
# surviving the sandbox_local volume mount that shadows /home/ai/.local
RUN curl -fsSL https://raw.githubusercontent.com/unhappychoice/gitlogue/main/install.sh -o /tmp/gitlogue-install.sh && \
    echo y | INSTALL_DIR=/usr/local/bin bash /tmp/gitlogue-install.sh && \
    rm /tmp/gitlogue-install.sh

# Install diffwatch — copied from go build stage
COPY --from=diffwatch-builder /go/bin/diffwatch /usr/local/bin/diffwatch

# Install git-status-watch as gsw — copied from rust build stage
COPY --from=gsw-builder /usr/local/cargo/bin/git-status-watch /usr/local/bin/gsw

RUN chown -R ai:ai /workspace && chown -R ai:ai /home/ai

# Copy harness seed/scripts/docs last — changes here won't bust expensive layers above
COPY scripts/ /etc/aih/scripts/
COPY seed/ /etc/aih/seed/
COPY docs/ /etc/aih/docs/
COPY setup.sh /etc/aih/setup.sh
RUN chown -R ai:ai /etc/aih

# Copy entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod ugo+x /usr/local/bin/docker-entrypoint.sh

USER ai
WORKDIR /home/ai

# Set up NVM environment
ENV NVM_DIR=/home/ai/.nvm
ENV NODE_VERSION=24
ENV HOME=/home/ai
ENV SHELL=bash
# Set the default editor and visual
ENV EDITOR=vim
ENV VISUAL=vim

# create venv for ai user
RUN python3 -m venv "$HOME/venv"

# Ensure subsequent RUN/CMD use venv Python and tools first.
ENV PATH="$HOME/venv/bin:$PATH"

# Install semgrep for targeted way to find bugs/security issues
RUN --mount=type=cache,target=/root/.cache/pip \
    "$HOME/venv/bin/python" -m pip install --upgrade pip && \
    "$HOME/venv/bin/python" -m pip install semgrep

# Install nvm (latest release; pin to a version tag in the URL for reproducible builds)
RUN NVM_VERSION=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | jq -r .tag_name) && \
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash

# Install Node.js 24 via nvm and set as default (.bashrc already has nvm from install script)
RUN nvm install $NODE_VERSION && nvm alias default $NODE_VERSION && nvm use default

# Ensure node and npm are available in non-interactive shells
ENV PATH="$NVM_DIR/versions/node/v$NODE_VERSION.*/bin:$PATH"

# Install pnpm (as ai user so they install to user home directory)
RUN npm install -g pnpm && pnpm setup
# pnpm setup adds PATH to .bashrc; set it here too so pnpm is on PATH in later RUN and interactive shells
ENV PNPM_HOME="/home/ai/.local/share/pnpm"
ENV PATH="$PNPM_HOME:$PATH"

# Install claude-code
RUN curl -fsSL https://claude.ai/install.sh | bash

#Install cursor cli
RUN curl https://cursor.com/install -fsS | bash

# Install OpenCode CLI — copied from build stage to /usr/local/bin so it survives volume mounts
COPY --from=opencode-builder /root/.opencode/bin/opencode /usr/local/bin/opencode

# Install Kilo CLI — copied from build stage to /usr/local/bin so it survives volume mounts
COPY --from=kilo-builder /root/.kilo/bin/kilo /usr/local/bin/kilo

# Install engram — copied from build stage to /usr/local/bin so it survives volume mounts
COPY --from=engram-builder /usr/local/bin/engram /usr/local/bin/engram

RUN if [ -n "$GITCONFIG" ]; then \
      echo "$GITCONFIG" | base64 -d > /home/ai/.gitconfig; \
    fi

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/bin/bash"]
