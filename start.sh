#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn (upstream) + ScalePass (modifications)
#
# ScalePass fork of marcusquinn/aidevops-cloudron-app start.sh v0.1.0.
#
# Modifications vs upstream:
#   - Phase 3: `worker.json` default sets `"pulse": {"enabled": true}` (was false).
#   - Phase 7b: NEW — apply ScalePass patches from /app/code/patches/ to /app/data/.aidevops/.
#   - Phase 7c: NEW — install cron entry to re-apply patches every 5 min
#                     (handles in-container `aidevops update` events).
#   - Phase 7d: NEW — npm install opencode-aidevops plugin deps (plugin ships
#                     without node_modules).
#   - Phase 7e: NEW — `aidevops setup --scope pulse` to start a pulse session.
#                     (Cron file itself is baked at build time in Dockerfile —
#                     /var/spool/cron/ is read-only at runtime so the framework's
#                     own crontab-based install silently no-ops.)
#   - cron daemon launched in Phase 9 (background) before server.js.
# All other phases inherited verbatim from upstream.

set -eu

echo "==> Starting ScalePass AI DevOps Worker"

# ============================================
# PHASE 1: First-Run Detection
# ============================================
if [[ ! -f /app/data/.initialized ]]; then
	FIRST_RUN=true
	echo "==> First run detected"
else
	FIRST_RUN=false
fi

# ============================================
# PHASE 2: Directory Structure & Permissions
# ============================================
mkdir -p /app/data/config
mkdir -p /app/data/workspace
mkdir -p /app/data/logs
mkdir -p /app/data/.ssh
mkdir -p /app/data/.config
mkdir -p /app/data/aidevops/agents
mkdir -p /app/data/.aidevops
mkdir -p /app/data/Git
mkdir -p /run/app
[[ ! -L /app/data/.gitconfig ]] && touch /app/data/.gitconfig
chown -hR cloudron:cloudron /app/data
chown -hR cloudron:cloudron /run/app

# ============================================
# PHASE 3: First-Run Initialization
# ScalePass change: worker.json default has pulse.enabled=true (was false upstream).
# ============================================
if [[ "$FIRST_RUN" == "true" ]]; then
	echo "==> First-run initialization"

	if [[ ! -f /app/data/.ssh/id_ed25519 ]]; then
		echo "==> Generating SSH key for git operations"
		ssh-keygen -t ed25519 -f /app/data/.ssh/id_ed25519 -N "" -C "aidevops-worker@cloudron"
		echo "==> SSH public key (add to GitHub deploy keys):"
		cat /app/data/.ssh/id_ed25519.pub
		chown -hR cloudron:cloudron /app/data/.ssh
	fi

	if [[ ! -f /app/data/config/worker.json ]]; then
		AUTH_TOKEN=$(openssl rand -hex 32)
		cat >/app/data/config/worker.json <<EOF
{
  "worker": {
    "max_concurrent": 2,
    "ram_per_worker_mb": 256,
    "idle_timeout_minutes": 30,
    "model": "anthropic/claude-sonnet-4-6"
  },
  "dispatch": {
    "auth_token": "${AUTH_TOKEN}",
    "allowed_repos": [],
    "auto_accept": false
  },
  "pulse": {
    "enabled": true,
    "interval_seconds": 120,
    "repos_json_path": "/app/data/config/repos.json"
  }
}
EOF
		echo "============================================"
		echo "==> AUTH TOKEN (save this — shown only once):"
		echo "==> ${AUTH_TOKEN}"
		echo "============================================"
	fi

	if [[ ! -f /app/data/config/repos.json ]]; then
		cat >/app/data/config/repos.json <<'EOF'
{
  "git_parent_dirs": ["/app/data/workspace"],
  "initialized_repos": []
}
EOF
	fi
fi

# ============================================
# PHASE 4: SSH Configuration
# ============================================
[[ ! -L /app/data/.ssh/id_ed25519 && -f /app/data/.ssh/id_ed25519 ]] && chmod 600 /app/data/.ssh/id_ed25519
[[ ! -L /app/data/.ssh/id_ed25519.pub && -f /app/data/.ssh/id_ed25519.pub ]] && chmod 644 /app/data/.ssh/id_ed25519.pub

PINNED_GITHUB_KEY="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
if [[ -L /app/data/.ssh/known_hosts ]]; then
	rm -f /app/data/.ssh/known_hosts
fi
: >/tmp/known_hosts.tmp
if [[ -f /app/data/.ssh/known_hosts ]]; then
	grep -vE '^github\.com[ ,]' /app/data/.ssh/known_hosts >/tmp/known_hosts.tmp || true
fi
printf '%s\n' "$PINNED_GITHUB_KEY" >>/tmp/known_hosts.tmp
mv /tmp/known_hosts.tmp /app/data/.ssh/known_hosts
chmod 644 /app/data/.ssh/known_hosts

# ============================================
# PHASE 5: Git Configuration
# ============================================
gosu cloudron:cloudron git config --global user.name "AI DevOps Worker"
gosu cloudron:cloudron git config --global user.email "worker@aidevops.sh"
gosu cloudron:cloudron git config --global init.defaultBranch main

# ============================================
# PHASE 6: Environment Setup
# ============================================
if [[ -n "${GH_TOKEN:-}" ]]; then
	echo "==> Configuring GitHub CLI authentication"
	echo "$GH_TOKEN" | gosu cloudron:cloudron gh auth login --with-token 2>/dev/null || true
fi

# ============================================
# PHASE 7: Deploy aidevops agents
# ScalePass change: keep stderr (was 2>/dev/null) and || true so non-zero rc on first
# runs (e.g., network blips during git clone) doesn't kill start.sh before Phase 9.
# /home/cloudron/.aidevops is symlinked to /app/data/.aidevops by the Dockerfile so
# aidevops's framework files land in the persistent volume.
# ============================================
echo "==> Deploying aidevops agents"
# ScalePass change: HOME=/app/data (was /home/cloudron upstream). /home/cloudron is
# in the read-only image layer; aidevops's first-run mkdir of $HOME/Git fails there.
# /app/data is the writable persistent volume. Same fix pattern as patch 002
# (HOME normalize in pulse-wrapper.sh) — apply at this scope too.
export HOME=/app/data
export AIDEVOPS_NON_INTERACTIVE=true
# ScalePass: USER=cloudron — gosu doesn't propagate USER and aidevops' post-setup
# module references it unguarded (set -u → unbound variable, kills the stage).
#
# ScalePass F2 (2026-05-18): wrap in `timeout 300` so a stalled `aidevops update`
# cannot block start.sh from reaching Phase 9 (cron daemon + server.js).
# Without this guard we observed Phase 7 hanging 2+ hours, leaving the
# container with no scheduled pulse cycles. Patch 003's empirical test
# (envelope-test investigation) had to be unblocked by a manual
# `service cron start` — F2 makes the rebuild self-sufficient.
# rc=124 is timeout's signal that the inner command was killed; treat it the
# same as any other non-zero rc — log and continue. The 5-min budget is
# generous; observed completion when not hung is well under 60s.
timeout 300 gosu cloudron:cloudron env HOME=/app/data USER=cloudron aidevops update \
    || echo "==> aidevops update exited non-zero (rc=$?; continuing — cron + Phase 9 will retry framework health)"

# ============================================
# PHASE 7b: [SCALEPASS] Apply patches against the freshly-installed framework
# Continues past failure — the periodic cron (installed by Dockerfile) retries every 5 min.
# ============================================
if [[ -d /app/code/patches ]]; then
	echo "==> Applying ScalePass patches"
	gosu cloudron:cloudron /app/code/patches/apply.sh || \
		echo "==> apply.sh exit non-zero on first boot (framework may not be initialised yet); cron will retry"
fi

# ============================================
# PHASE 7d: [SCALEPASS] npm install the opencode-aidevops plugin
# The plugin ships with package.json but NOT node_modules. Without dependencies
# installed, opencode runtime crashes with "InstanceRef not provided" or
# "g.type undefined" inside its bun-compiled internals (issue #30 of the
# 2026-05-16 install marathon). Idempotent — npm install is a no-op when
# node_modules/ is already up to date.
# ============================================
OPENCODE_PLUGIN_DIR=/app/data/.aidevops/agents/plugins/opencode-aidevops
if [[ -d "$OPENCODE_PLUGIN_DIR" && -f "$OPENCODE_PLUGIN_DIR/package.json" ]]; then
	if [[ ! -d "$OPENCODE_PLUGIN_DIR/node_modules" ]]; then
		echo "==> Installing opencode-aidevops plugin npm dependencies"
		(cd "$OPENCODE_PLUGIN_DIR" && gosu cloudron:cloudron npm install --no-audit --no-fund 2>&1) \
			|| echo "==> WARNING: plugin npm install failed; canary will likely fail"
	fi
fi

# Phase 7c (cron install) is now done at Dockerfile build time — /etc is read-only at runtime in Cloudron.

# ============================================
# PHASE 7e: [SCALEPASS] install + start supervisor pulse
# `aidevops update --non-interactive` only deploys agents + safe migrations; it
# skips setup_supervisor_pulse. We invoke the scoped setup directly so the pulse
# cron+wrapper come up on first boot without operator interaction. Idempotent —
# noop when pulse cron is already installed.
# ============================================
echo "==> Installing supervisor pulse scheduler"
gosu cloudron:cloudron env HOME=/app/data USER=cloudron \
    AIDEVOPS_NON_INTERACTIVE=true AIDEVOPS_SUPERVISOR_PULSE=true \
    aidevops setup --scope pulse 2>&1 | tail -20 \
    || echo "==> aidevops setup --scope pulse non-zero (will retry on next boot)"

# ============================================
# PHASE 8: Final Permissions
# ============================================
chown -hR cloudron:cloudron /app/data
touch /app/data/.initialized

# ============================================
# PHASE 9: Launch cron daemon + server
# ScalePass change: cron daemon launched in background before server.
# ============================================
echo "==> Starting cron daemon (for ScalePass patch re-apply)"
service cron start || /usr/sbin/cron

echo "==> Launching AI DevOps Worker server"
# ScalePass: run under tini as PID 1 so reparented zombies (pulse/worker bash
# subtrees whose intermediate parent exited) are reaped. node-as-PID-1 only waits
# on its own children, leaving ~120 zombies/h to accumulate. tini -g forwards
# signals to the whole process group for clean shutdown.
exec /usr/bin/tini -g -- gosu cloudron:cloudron node /app/code/server.js
