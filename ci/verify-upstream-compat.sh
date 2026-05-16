#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Leon (ScalePass)
#
# verify-upstream-compat.sh — quarterly compat check for our patches against
# the current upstream `aidevops` framework HEAD.
#
# For each `.patch` in patches/, this script:
#   1. Clones upstream `marcusquinn/aidevops` at HEAD into a scratch dir.
#   2. Tries `patch --dry-run` to determine if our patch still applies.
#   3. Reports per-patch status: OK / CONFLICT / OBSOLETE.
#
# OBSOLETE = our patch's added lines are ALREADY in upstream HEAD (someone
# upstreamed our fix or an equivalent). Action: drop the patch from our set.
#
# CONFLICT = patch no longer applies cleanly — upstream changed surrounding
# code. Action: rebase the patch against upstream HEAD.
#
# OK = patch still applies cleanly. No action needed.
#
# Intended to run as a quarterly cron OR as a manual check before bumping
# the `aidevops` npm pin in Dockerfile.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FORK_ROOT="$(dirname "$SCRIPT_DIR")"
PATCHES_DIR="$FORK_ROOT/patches"
SCRATCH="${SCRATCH_DIR:-/tmp/aidevops-compat-check-$$}"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/marcusquinn/aidevops.git}"

trap 'rm -rf "$SCRATCH"' EXIT

echo "==> Cloning $UPSTREAM_REPO HEAD into $SCRATCH"
git clone --quiet --depth 1 "$UPSTREAM_REPO" "$SCRATCH"
upstream_sha=$(cd "$SCRATCH" && git rev-parse HEAD)
echo "==> Upstream HEAD: $upstream_sha"
echo ""

ok=0
obsolete=0
conflict=0

for patch in "$PATCHES_DIR"/*.patch; do
    [[ -f "$patch" ]] || continue
    name=$(basename "$patch")

    # Extract idempotency marker (first +# line)
    marker=$(grep -m1 -E '^\+#' "$patch" | sed 's/^+//')
    target=$(grep -m1 -E '^\+\+\+ ' "$patch" | sed 's|^+++ b/||' | sed 's|^+++ ||')

    if [[ -z "$marker" || -z "$target" ]]; then
        echo "$name: MALFORMED (missing marker or +++ header)"
        conflict=$((conflict + 1))
        continue
    fi

    # Check if upstream HEAD already contains the marker → patch is obsolete
    if grep -qF -- "$marker" "$SCRATCH/$target" 2>/dev/null; then
        echo "$name: OBSOLETE — upstream HEAD already contains this patch's marker."
        echo "  Action: drop this patch and bump the npm pin in Dockerfile."
        obsolete=$((obsolete + 1))
        continue
    fi

    # Try forward apply (dry-run, --batch to prevent reverse auto-detect)
    if (cd "$SCRATCH" && patch -p1 --forward --batch --dry-run --silent --reject-file=/dev/null < "$patch") >/dev/null 2>&1; then
        echo "$name: OK — applies cleanly against upstream HEAD."
        ok=$((ok + 1))
    else
        echo "$name: CONFLICT — does not apply against upstream HEAD."
        echo "  Action: rebase the patch against the upstream changes around target=$target."
        conflict=$((conflict + 1))
    fi
done

echo ""
echo "==> Summary: ok=$ok obsolete=$obsolete conflict=$conflict"
echo ""

if [[ $obsolete -gt 0 ]]; then
    echo "==> $obsolete patch(es) obsolete. Run patch removal then bump npm pin in Dockerfile."
fi
if [[ $conflict -gt 0 ]]; then
    echo "==> $conflict patch(es) in CONFLICT. Manual rebase needed before next deploy."
    exit 1
fi

exit 0
