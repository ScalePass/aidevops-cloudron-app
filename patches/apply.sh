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

# Extract the first "+#" comment line added by this patch — used as the
# idempotency marker. If grep finds it in the target, the patch is applied.
patch_marker() {
    local patch="$1"
    grep -m1 -E '^\+#' "$patch" | sed 's/^+//'
}

# Find the target file the patch modifies — from the first "+++ b/..." header.
patch_target_file() {
    local patch="$1"
    grep -m1 -E '^\+\+\+ ' "$patch" | sed 's|^+++ b/||' | sed 's|^+++ ||'
}

for patch in "$PATCHES_DIR"/*.patch; do
    [[ -f "$patch" ]] || continue
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

    # Not applied — try forward apply
    if patch -p1 --forward --batch --silent --reject-file=/dev/null < "$patch" >/dev/null 2>&1; then
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

if [[ $applied -gt 0 || $failed -gt 0 ]]; then
    echo "$LOG_PREFIX summary: applied=$applied skipped=$skipped failed=$failed"
fi

[[ $failed -eq 0 ]]
