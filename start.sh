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
gosu cloudron:cloudron env HOME=/app/data aidevops update || echo "==> aidevops update exited non-zero (continuing — cron + Phase 9 will retry framework health)"

# ============================================
# PHASE 7b: [SCALEPASS] Apply patches against the freshly-installed framework
# Continues past failure — the periodic cron (installed by Dockerfile) retries every 5 min.
# ============================================
if [[ -d /app/code/patches ]]; then
	echo "==> Applying ScalePass patches"
	gosu cloudron:cloudron /app/code/patches/apply.sh || \
		echo "==> apply.sh exit non-zero on first boot (framework may not be initialised yet); cron will retry"
fi

# Phase 7c (cron install) is now done at Dockerfile build time — /etc is read-only at runtime in Cloudron.

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
exec gosu cloudron:cloudron node /app/code/server.js
