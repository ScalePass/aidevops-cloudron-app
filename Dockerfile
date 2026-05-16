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
    ripgrep \
    && rm -rf /var/lib/apt/lists/*

# ScalePass: cloudron user ships with /usr/sbin/nologin as login shell. When
# opencode (running as cloudron via gosu) spawns its Bash tool, the spawn picks
# up the user's login shell from /etc/passwd and every tool call returns the
# nologin banner "This account is currently not available." with exit 1. Fix:
# give cloudron a real shell so opencode's tool subprocess actually runs bash.
# /etc/passwd is mounted read-only at runtime, so this MUST live in the image.
RUN usermod -s /bin/bash cloudron

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
# ScalePass pin: opencode v1.14.45 matches kidzcity. v1.15.1+ has incompatible
# model-name format (bare names instead of provider/model) which breaks the
# framework canary. v1.14.45 stays compatible with framework v3.15.38's routing.
RUN curl -fsSL "https://github.com/anomalyco/opencode/releases/download/v1.14.45/opencode-linux-x64.tar.gz" \
    | tar -xz -C /usr/local/bin \
    && chmod +x /usr/local/bin/opencode \
    && opencode --version \
    && npm install -g aidevops@3.15.38

# ============================================
# Writable home directories (Cloudron read-only /app/code workaround)
# ScalePass addition: also symlink /home/cloudron/.aidevops → /app/data/.aidevops
# so `aidevops update` populates the persistent volume (matches kidzcity's runtime layout).
# ============================================
RUN mkdir -p /app/data/.ssh /app/data/.config /app/data/.aidevops /app/data/Git \
    && rm -rf /home/cloudron/.ssh /home/cloudron/.config /home/cloudron/.gitconfig /home/cloudron/.aidevops /home/cloudron/Git \
    && ln -sfn /app/data/.ssh /home/cloudron/.ssh \
    && ln -sfn /app/data/.config /home/cloudron/.config \
    && ln -sfn /app/data/.gitconfig /home/cloudron/.gitconfig \
    && ln -sfn /app/data/.aidevops /home/cloudron/.aidevops \
    && ln -sfn /app/data/Git /home/cloudron/Git

# ============================================
# ScalePass: install patch re-apply cron at BUILD time
# /etc is mounted read-only at runtime so we cannot write the cron file from start.sh.
# This file is baked into the image; cron daemon launched in start.sh Phase 9 picks it up.
# ============================================
RUN printf '%s\n' \
    '# ScalePass: re-apply patches every 5 min to survive in-container framework updates.' \
    '# apply.sh is idempotent — no-op when patches already applied.' \
    'SHELL=/bin/bash' \
    'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    '*/5 * * * * cloudron /app/code/patches/apply.sh >> /app/data/logs/patches-reapply.log 2>&1' \
    > /etc/cron.d/scalepass-patches-reapply \
    && chmod 644 /etc/cron.d/scalepass-patches-reapply

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
