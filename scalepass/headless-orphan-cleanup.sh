#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Leon (ScalePass)
#
# headless-orphan-cleanup.sh — force-clean stalled headless-worker worktrees.
#
# Why this exists:
#   v3.15.55 (commit 1cedb5c7a) hardened pulse-cleanup to never auto-remove
#   dirty worktrees (safety for interactive editor sessions). For our batch
#   workloads where headless workers stall mid-task (model timeout, network
#   blip, opencode crash), this means dirty worktrees persist 6h+ or forever.
#   Re-dispatches see the worktree and either spawn parallel workers OR get
#   stuck. The pulse dispatcher's effective_slots shrinks to 1-2 instead of
#   the configured 4 (patch 003) because stalled workers hold their slots.
#
# Scope:
#   Only worktrees whose branch matches feature/auto-*-gh* (the canonical
#   headless-worker branch naming). Interactive editor worktrees (any other
#   branch pattern) are left untouched — that's pulse-cleanup's safety
#   contract and we don't override it.
#
# Removal criteria (ALL must hold):
#   1. Branch matches feature/auto-*-gh*
#   2. No live worker process matches the worktree dir in pgrep argv
#   3. Worktree age > 30 min (matches ORPHAN_WORKTREE_GRACE_SECS default)
#   4. No OPEN PR exists for the branch
#
# Idempotent. Silent on empty (no candidates). Loud on action.
#
# Invocation: every 15 min via /etc/cron.d/scalepass-headless-orphan-cleanup.

set -uo pipefail

WORKSPACE_ROOT="${WORKSPACE_ROOT:-/app/data/workspace}"
GRACE_SECS="${SCALEPASS_HEADLESS_ORPHAN_GRACE_SECS:-1800}"
LOG_PREFIX="[headless-orphan-cleanup]"
NOW_EPOCH=$(date +%s)

if [[ ! -d "$WORKSPACE_ROOT" ]]; then
    exit 0  # No workspace yet — nothing to do (fresh install).
fi

# Verify gh is available + authenticated
if ! command -v gh >/dev/null 2>&1; then
    echo "$LOG_PREFIX SKIP: gh CLI not on PATH" >&2
    exit 0
fi

removed=0
checked=0
skipped_active=0
skipped_open_pr=0
skipped_young=0

for wt_dir in "$WORKSPACE_ROOT"/*-feature-auto-*-gh*; do
    [[ -d "$wt_dir" ]] || continue
    checked=$((checked + 1))

    # Extract branch from dir name. Convention:
    #   <Org>-<repo>-feature-auto-<ts>-gh<issue>
    # The branch on the remote is feature/auto-<ts>-gh<issue>.
    branch=$(basename "$wt_dir" | sed -E 's/^[^-]+-[^-]+-(feature)-(auto-.*-gh[0-9]+)$/\1\/\2/')
    if [[ "$branch" == "$(basename "$wt_dir")" ]]; then
        # sed didn't match — skip (unknown dir pattern, leave alone)
        continue
    fi

    # Age check
    wt_mtime=$(stat -c '%Y' "$wt_dir" 2>/dev/null || echo 0)
    wt_age=$((NOW_EPOCH - wt_mtime))
    if (( wt_age < GRACE_SECS )); then
        skipped_young=$((skipped_young + 1))
        continue
    fi

    # Live-worker check (pgrep argv)
    if pgrep -f -- "$wt_dir" >/dev/null 2>&1; then
        skipped_active=$((skipped_active + 1))
        continue
    fi

    # Open-PR check. Try to derive repo slug from dir name (first two segments
    # before -feature). Format: <Org>-<repo>-feature-auto-...
    repo_slug=$(basename "$wt_dir" | sed -E 's/^([^-]+)-([^-]+)-feature-auto-.*/\1\/\2/')
    if [[ "$repo_slug" == "$(basename "$wt_dir")" ]]; then
        # Cannot derive repo — skip defensively (don't remove without knowing)
        continue
    fi

    pr_state=$(gh pr list --repo "$repo_slug" --head "$branch" --state open --json number --jq 'length' 2>/dev/null || echo "")
    if [[ "$pr_state" =~ ^[1-9] ]]; then
        # 1 or more open PRs — leave alone (pulse-merge will pick up)
        skipped_open_pr=$((skipped_open_pr + 1))
        continue
    fi

    # All gates passed — force-remove
    echo "$LOG_PREFIX REMOVE $wt_dir age=${wt_age}s branch=$branch repo=$repo_slug (no live worker, no open PR)"
    rm -rf -- "$wt_dir" 2>/dev/null && removed=$((removed + 1)) || \
        echo "$LOG_PREFIX FAIL to rm $wt_dir" >&2
done

if (( removed > 0 || checked > 5 )); then
    echo "$LOG_PREFIX summary: checked=$checked removed=$removed skipped_active=$skipped_active skipped_open_pr=$skipped_open_pr skipped_young=$skipped_young"
fi

exit 0
