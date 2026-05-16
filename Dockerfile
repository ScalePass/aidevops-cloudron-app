# ============================================
# ScalePass aidevops worker — Dockerfile
# Fork of marcusquinn/aidevops-cloudron-app v0.1.0
# Modifications:
#   - Install `patch` utility (required by /app/code/patches/apply.sh)
#   - Pin `aidevops` npm version to a known-tested release (3.15.38 for v1)
#   - COPY our patches/ directory into the image at /app/code/patches/
# All other steps inherited verbatim from upstream.
# ============================================

FROM cloudron/base:5.0.0

# ============================================
# System dependencies
# ============================================
# `patch` added (ScalePass) — required by /app/code/patches/apply.sh at runtime.
RUN apt-get update && apt-get install -y --no-install-recommends \
    jq \
    patch \
    cron \
    && rm -rf /var/lib/apt/lists/*

# ============================================
# Node.js 20 LTS via NodeSource
# cloudron/base includes Node 18; server.js and aidevops CLI need 20 LTS
# ============================================
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version && npm --version

# ============================================
# GitHub CLI (gh)
# ============================================
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ============================================
# OpenCode CLI (from GitHub releases) + aidevops CLI (PINNED VERSION)
# ============================================
# ScalePass change: pinned `aidevops@3.15.38` (was unversioned upstream).
# The pinned version matches kidzcity's currently-running production framework.
# See UPSTREAM.md for the upgrade ritual.
RUN curl -fsSL "https://github.com/anomalyco/opencode/releases/latest/download/opencode-linux-x64.tar.gz" \
    | tar -xz -C /usr/local/bin \
    && chmod +x /usr/local/bin/opencode \
    && opencode --version \
    && npm install -g aidevops@3.15.38

# ============================================
# Writable home directories (Cloudron read-only /app/code workaround)
# ============================================
RUN mkdir -p /app/data/.ssh /app/data/.config \
    && rm -rf /home/cloudron/.ssh /home/cloudron/.config /home/cloudron/.gitconfig \
    && ln -sfn /app/data/.ssh /home/cloudron/.ssh \
    && ln -sfn /app/data/.config /home/cloudron/.config \
    && ln -sfn /app/data/.gitconfig /home/cloudron/.gitconfig

# ============================================
# Application code + ScalePass patches
# ============================================
WORKDIR /app/code

COPY start.sh /app/code/start.sh
COPY server.js /app/code/server.js
# ScalePass: COPY our patches into the image. Applied by start.sh Phase 7b
# at container start, and re-applied by the cron entry installed in Phase 7c
# every 5 minutes (handles in-container `aidevops update` events).
COPY patches /app/code/patches

RUN chmod +x /app/code/start.sh \
    && chmod +x /app/code/patches/apply.sh

EXPOSE 3000

CMD ["/app/code/start.sh"]
