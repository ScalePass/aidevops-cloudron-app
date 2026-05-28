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
# ScalePass: install supervisor-pulse cron at BUILD time
# The framework's own pulse-cron install (setup_supervisor_pulse) silently fails
# in Cloudron containers because /var/spool/cron/ is read-only at runtime —
# `crontab -` cannot write to it. We bypass via /etc/cron.d/ which IS writable
# at build time (this RUN step), giving the cron daemon a system entry to fire
# pulse-wrapper.sh on the framework's standard 2-minute cadence.
#
# flock prevents overlapping runs (pulse-wrapper has its own mkdir lock too).
# Logs land in scheduler-pulse.log so they're distinguishable from the
# session-flag pulse.log.
#
# F-NEW-2 (2026-05-20): the cron entry's env list is HARDCODED because cron
# doesn't inherit Cloudron app env vars. Variables that need to be active in
# the pulse-wrapper process tree MUST be listed inline here — operator-set
# `cloudron env set` values do NOT propagate into cron-spawned processes
# (same root cause as patch 003's PULSE_PROVIDER_ACCOUNT_SLOT_MULTIPLIER bug).
#
# Two safety bypasses added 2026-05-20 (validated empirically on kidzcity
# 2026-05-19 — without them the dispatcher gets trapped in a "no_dispatchable_
# evidence" guardrail loop on fresh containers and at the start of any
# new workload burst):
#
# - AIDEVOPS_SKIP_PULSE_CURRENT_STATE_GUARDRAILS=1: bypasses the rolling-
#   window "no_dispatchable evidence" guardrail. The guardrail is designed
#   for general-purpose deployments where humans may be in the loop and a
#   pause-and-wait is appropriate; ScalePass-spec workers are autonomous,
#   and the guardrail's interpretation of "no recent dispatch = something's
#   wrong, stop dispatching" creates a chicken-and-egg loop on cold-start.
#
# - AIDEVOPS_SKIP_CANARY_NEG_CACHE=1: bypasses the canary negative cache so
#   fresh containers don't carry stale "canary failed" state from prior boots.
#
# F-NEW-1 mitigation (2026-05-20): the framework's post-merge-review-scanner
# defaults to SCANNER_PR_LIMIT=1000 × SCANNER_DAYS=7 (run on a 24h cadence).
# On stress-test repos with 100+ PRs/day, the once-per-day fire stalls the
# pulse cycle for 15+ minutes iterating PRs via GraphQL. Tightened to
# SCANNER_PR_LIMIT=200 + SCANNER_DAYS=2 here, which keeps the bot-feedback
# follow-up function active while bounding the worst-case cycle duration to
# ~2 min (the framework's intended per-stage cadence).
# ============================================
RUN printf '%s\n' \
    '# ScalePass: supervisor-pulse scheduler — runs every 2 min (framework default).' \
    '# AIDEVOPS_PULSE_IDLE_BACKOFF_STEP_30_S=300 caps the adaptive idle-backoff at 5 min' \
    '# (default is 1800s/30 min) — operator preference for active development workflows.' \
    '# See scalepass-work/docs/13-pulse-cadence-levers.md.' \
    '# `timeout --kill-after=60s 1500s` hard-caps the supervisor-pulse session at 25 min' \
    '# (SIGTERM) + 1 min grace (SIGKILL). Catches the --role pulse stall pattern that' \
    '# worker-activity-watchdog.sh does NOT cover (scalepass-work#3007). Without this the' \
    '# whole dispatch path stalls indefinitely behind a stuck pulse holding the flock.' \
    'SHELL=/bin/bash' \
    'PATH=/app/data/bin:/usr/local/node-22.14.0/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    '*/2 * * * * cloudron HOME=/app/data USER=cloudron AIDEVOPS_SUPERVISOR_PULSE=true AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=anthropic,opencode AIDEVOPS_NON_INTERACTIVE=true AIDEVOPS_SKIP_PULSE_CURRENT_STATE_GUARDRAILS=1 AIDEVOPS_SKIP_CANARY_NEG_CACHE=1 SCANNER_PR_LIMIT=200 SCANNER_DAYS=2 AIDEVOPS_PULSE_IDLE_BACKOFF_STEP_30_S=300 flock -n /tmp/scalepass-pulse.lock timeout --kill-after=60s 1500s /app/data/.aidevops/agents/scripts/pulse-wrapper.sh >> /app/data/.aidevops/logs/scheduler-pulse.log 2>&1' \
    > /etc/cron.d/scalepass-supervisor-pulse \
    && chmod 644 /etc/cron.d/scalepass-supervisor-pulse

# ============================================
# ScalePass F-merge (2026-05-18): install pulse-merge-routine cron at BUILD time.
#
# Per pulse-merge-routine.sh docstring (framework):
#   "Decouples merge_ready_prs_all_repos() from the monolithic pulse cycle so
#    green PRs are merged within ~3 min of CI completion regardless of how
#    long the preflight stack takes (typically 5-10 min for a full pulse cycle).
#    [...] In a 24h sample, the merge pass ran only ~7 times despite ~40+
#    pulse cycles. Green PRs sat unmerged for 10+ minutes."
#
# The framework ships pulse-merge-routine.sh but NO launchd/cron config to
# schedule it. On Linux/Cloudron we therefore must install our own.
#
# Without this cron: empirically measured 7-15 min merge_wait per PR even
# at queue-head position (envelope-test 2026-05-18 per
# docs/investigations/2026-05-18-patch003-envelope-test.md).
#
# Expected effect: merge_wait drops from ~10min avg to ~2-3min (routine cadence).
# Per-routine duration is typically <30s when no work to merge; the script's
# own ~/.aidevops/.agent-workspace/locks/pulse-merge-routine.lock prevents
# overlap so we omit redundant flock at the cron layer.
# ============================================
RUN printf '%s\n' \
    '# ScalePass: pulse-merge-routine — runs every 2 min (independent of supervisor-pulse).' \
    '# Decouples PR merge from the monolithic pulse cycle preflight stack.' \
    'SHELL=/bin/bash' \
    'PATH=/app/data/bin:/usr/local/node-22.14.0/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    '*/2 * * * * cloudron HOME=/app/data USER=cloudron AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=anthropic,opencode AIDEVOPS_NON_INTERACTIVE=true /app/data/.aidevops/agents/scripts/pulse-merge-routine.sh >> /app/data/.aidevops/logs/pulse-merge-routine.log 2>&1' \
    > /etc/cron.d/scalepass-pulse-merge-routine \
    && chmod 644 /etc/cron.d/scalepass-pulse-merge-routine

# ============================================
# ScalePass F-stuck (2026-05-18): install headless-orphan-cleanup cron.
#
# v3.15.55 commit `1cedb5c7a fix(pulse-cleanup): preserve dirty worktrees and
# reflog-only WIP` hardened pulse-cleanup to NEVER auto-remove dirty
# worktrees (safety improvement to protect interactive editor sessions on
# upstream marcusquinn deployments). Side effect on ScalePass batch workloads:
# headless workers that stall mid-task leave dirty git state. Their worktrees
# persist 6h+ (or never; _cleanup_single_worktree refuses dirty removals
# even past the 6h threshold). Re-dispatches see the worktree and either
# spawn parallel workers on the same session-key OR get stuck.
#
# Empirically observed 2026-05-18 envelope test: issue #1524 worker running
# 14:01 elapsed with multiple sessions on the same key.
#
# This cron runs a scoped force-cleanup on `feature/auto-*-gh*` branches
# only (the headless-worker branch naming convention) where:
#   - no live worker process matches in pgrep argv
#   - age > 30 min
#   - no open PR for the branch
# Preserves upstream's safety for interactive worktrees (branch != feature/auto-*).
# ============================================
RUN printf '%s\n' \
    '# ScalePass: headless-worker orphan worktree cleanup — every 15 min.' \
    '# Scoped to feature/auto-*-gh* branches only; leaves interactive worktrees alone.' \
    'SHELL=/bin/bash' \
    'PATH=/app/data/bin:/usr/local/node-22.14.0/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    '*/15 * * * * cloudron /app/code/scalepass/headless-orphan-cleanup.sh >> /app/data/.aidevops/logs/scalepass-headless-orphan-cleanup.log 2>&1' \
    > /etc/cron.d/scalepass-headless-orphan-cleanup \
    && chmod 644 /etc/cron.d/scalepass-headless-orphan-cleanup

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
# ScalePass: COPY helper scripts. F-stuck — headless-orphan-cleanup.sh runs
# every 15 min via /etc/cron.d/scalepass-headless-orphan-cleanup.
COPY scalepass /app/code/scalepass

RUN chmod +x /app/code/start.sh \
    && chmod +x /app/code/patches/apply.sh \
    && chmod +x /app/code/scalepass/headless-orphan-cleanup.sh

EXPOSE 3000

CMD ["/app/code/start.sh"]
