#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Leon (ScalePass)
#
# apply.sh — deterministic, idempotent re-applier for ScalePass patches against
# the aidevops framework's deployed files at /app/data/.aidevops/.
#
# Invocation contexts:
#   1. start.sh Phase 7b — once at container start, after Phase 7's `aidevops update`.
#   2. cron entry from start.sh Phase 7c — every 5 min, to catch in-container
#      `aidevops update` events that overwrite our patched files.
#   3. Manual operator invocation for diagnostic / forced re-apply.
#
# Contract:
#   - MUST be idempotent. Already-applied patches skip silently with rc=0.
#   - MUST be quiet on the happy path.
#   - MUST be loud on genuine failure (upstream changed, patch no longer applies).
#   - Returns 0 if all patches end up applied; non-zero if any failed.
#
# Idempotency strategy: grep the target file for a marker that's known to be
# present iff the patch is applied. The marker is extracted from each patch
# itself — the first `+#` comment line added by the patch's first hunk. Each
# patch's first added line MUST be a unique `# [ScalePass patch NNN — …]`
# comment by convention. This sidesteps `patch`'s unreliable reverse-detection
# behavior, which varies between GNU patch and BSD patch.

set -euo pipefail

TARGET_DIR="${TARGET_DIR:-/app/data/.aidevops}"
PATCHES_DIR="${PATCHES_DIR:-/app/code/patches}"
LOG_PREFIX="[scalepass-apply.sh]"

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "$LOG_PREFIX ERROR: target dir $TARGET_DIR not found — framework not initialized yet?" >&2
    exit 1
fi

if [[ ! -d "$PATCHES_DIR" ]]; then
    echo "$LOG_PREFIX ERROR: patches dir $PATCHES_DIR not found" >&2
    exit 1
fi

cd "$TARGET_DIR"

applied=0
skipped=0
failed=0
seen=0

# Extract the first comment line added by this patch — used as the
# idempotency marker. If grep finds it in the target, the patch is applied.
# Accepts both column-zero `+#` (patches 001-006) and indented `+\t#` (patch 007+),
# which is required for patches whose added content sits inside a function or
# array literal.
patch_marker() {
    local patch="$1"
    grep -m1 -E '^\+[[:space:]]*#' "$patch" | sed -E 's/^\+[[:space:]]*//'
}

# Find the target file the patch modifies — from the first "+++ b/..." header.
# ScalePass F7 (2026-05-18): translate `.agents/X` (upstream-repo source layout,
# which the patch files reference for `ci/verify-upstream-compat.sh` to keep
# applying against upstream HEAD) → `agents/X` (the deployed layout under
# /app/data/.aidevops/agents/). Pre-F7 the existence-check + `patch -p1` both
# resolved to /app/data/.aidevops/.agents/X which does not exist, so patches
# 001 + 003 silently failed every apply.sh run on every container. The bug
# was masked because Cloudron app env vars (AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST,
# HOME) delivered the runtime behaviours attributed to those patches.
patch_target_file() {
    local patch="$1"
    # Strip `+++ b/` or `+++ ` prefix, then translate `.agents/X` → `agents/X`.
    # Implemented entirely via sed because bash 5.3.9 on macOS (which the
    # operator may use for local apply.sh testing) SIGSEGVs on the equivalent
    # `${raw#.agents/}` parameter-expansion form. Linux bash is fine but sed
    # is portable to both.
    grep -m1 -E '^\+\+\+ ' "$patch" \
        | sed -E 's|^\+\+\+ b?/?||' \
        | sed -E 's|^\.agents/|agents/|'
}

# ScalePass F7: rewrite the patch's path headers in-flight so `patch -p1` from
# $TARGET_DIR writes to the translated `agents/X` location. Idempotent — the
# sed expressions are no-ops for patches that already use `agents/` (no dot).
_translated_patch_stream() {
    local patch="$1"
    sed \
        -e 's|^--- a/\.agents/|--- a/agents/|' \
        -e 's|^+++ b/\.agents/|+++ b/agents/|' \
        "$patch"
}

for patch in "$PATCHES_DIR"/*.patch; do
    [[ -f "$patch" ]] || continue
    seen=$((seen + 1))
    name=$(basename "$patch")

    marker=$(patch_marker "$patch")
    target=$(patch_target_file "$patch")

    if [[ -z "$marker" ]]; then
        echo "$LOG_PREFIX FAIL: $name has no '+#' marker — patches must start added lines with a # comment for idempotency detection" >&2
        failed=$((failed + 1))
        continue
    fi

    if [[ -z "$target" || ! -f "$TARGET_DIR/$target" ]]; then
        echo "$LOG_PREFIX FAIL: $name targets $target which doesn't exist under $TARGET_DIR" >&2
        failed=$((failed + 1))
        continue
    fi

    # Idempotency probe via marker
    if grep -qF -- "$marker" "$TARGET_DIR/$target"; then
        skipped=$((skipped + 1))
        continue
    fi

    # Not applied — try forward apply via translated stream (ScalePass F7).
    if _translated_patch_stream "$patch" | patch -p1 --forward --batch --silent --reject-file=/dev/null >/dev/null 2>&1; then
        # Verify marker now present (paranoid post-condition check)
        if grep -qF -- "$marker" "$TARGET_DIR/$target"; then
            applied=$((applied + 1))
        else
            echo "$LOG_PREFIX FAIL: $name patch returned success but marker missing post-apply" >&2
            failed=$((failed + 1))
        fi
    else
        echo "$LOG_PREFIX FAIL: $name does not apply to current $TARGET_DIR — upstream framework may have changed" >&2
        failed=$((failed + 1))
    fi
done

# Config drops — full-file overrides under custom/configs/
if [[ -d "$PATCHES_DIR/configs" ]]; then
    mkdir -p "$TARGET_DIR/agents/custom/configs"
    cp -a "$PATCHES_DIR/configs/." "$TARGET_DIR/agents/custom/configs/"
fi

# Loud warning when no patches were seen at all. This is almost always a
# packaging bug (the Docker image was built before new patches landed in the
# repo) rather than a runtime problem, but it manifests as the same operator
# symptom — patches appearing to "revert" after auto-update — that GH#3002
# initially attributed to the path-mismatch bug. Surfacing it explicitly tells
# the operator which root cause they're looking at.
if [[ $seen -eq 0 ]]; then
    echo "$LOG_PREFIX WARN: no *.patch files found in $PATCHES_DIR — image rebuild required if new patches exist in the source repo" >&2
fi

if [[ $applied -gt 0 || $failed -gt 0 ]]; then
    echo "$LOG_PREFIX summary: seen=$seen applied=$applied skipped=$skipped failed=$failed"
fi

[[ $failed -eq 0 ]]
