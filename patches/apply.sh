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
failed_names=""

# Extract the first comment line added by this patch — used as the
# idempotency marker. If grep finds it in the target, the patch is applied.
# Accepts both column-zero `+#` (patches 001-006) and indented `+\t#` (patch 007+),
# which is required for patches whose added content sits inside a function or
# array literal.
patch_marker() {
    local patch="$1"
    grep -m1 -E '^\+[[:space:]]*#' "$patch" | sed -E 's/^\+[[:space:]]*//'
}

# Record a patch failure: bump the counter and remember the name for the
# drift alert below.
_record_fail() {
    failed=$((failed + 1))
    failed_names="${failed_names:+$failed_names, }$1"
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

# Patch 003 raised the historical provider-account slot fallback from 2 to 4.
# Newer aidevops releases use a higher native fallback. Patches 009/010 predate
# the required-checks module split and newer releases implement both private-plan
# HTTP 403 cases natively there. Retire each patch only when its complete
# upstream replacement contract is present.
_patch_superseded_upstream() {
    local name="$1"
    local capacity="$TARGET_DIR/agents/scripts/pulse-capacity.sh"
    local required_checks="$TARGET_DIR/agents/scripts/pulse-merge-required-checks.sh"

    case "$name" in
        003-account-slot-multiplier-default.patch)
            [[ -f "$capacity" ]] || return 1
            grep -qF 'pulse_apply_provider_load_capacity_cap()' "$capacity" || return 1

            # Require both native fallback sites to meet or exceed patch 003's
            # intended floor. This remains fail-closed if upstream restructures
            # the function or lowers either default again.
            local config_default invalid_default
            config_default=$(sed -n -E 's/.*config_get "orchestration\.provider_account_slot_multiplier" "([0-9]+)".*/\1/p' "$capacity" | head -1)
            invalid_default=$(sed -n -E 's/.*\|\| account_multiplier=([0-9]+).*/\1/p' "$capacity" | head -1)
            [[ "$config_default" =~ ^[0-9]+$ && "$invalid_default" =~ ^[0-9]+$ ]] || return 1
            ((config_default >= 4 && invalid_default >= 4))
            return
            ;;
        009-private-repo-no-pro-treated-as-no-branch-protection.patch|\
        010-private-repo-no-pro-treated-as-no-rulesets.patch)
            ;;
        *)
            return 1
            ;;
    esac

    [[ -f "$required_checks" ]] || return 1
    grep -qF '_pmrc_private_plan_feature_unavailable()' "$required_checks" || return 1
    grep -qF 'Upgrade to GitHub Pro or make this repository public to enable this feature.' "$required_checks" || return 1
    grep -qF '[[ "$response" == *"HTTP 403"* ]] || return 1' "$required_checks" || return 1
    grep -qF '_required_contexts_from_rulesets_for_default_branch()' "$required_checks" || return 1
    grep -qF 'classic_unavailable_reason="private-plan unavailable (HTTP 403)"' "$required_checks" || return 1
    [[ $(grep -cF 'if _pmrc_private_plan_feature_unavailable ' "$required_checks") -ge 2 ]] || return 1
}

for patch in "$PATCHES_DIR"/*.patch; do
    [[ -f "$patch" ]] || continue
    seen=$((seen + 1))
    name=$(basename "$patch")

    if _patch_superseded_upstream "$name"; then
        skipped=$((skipped + 1))
        continue
    fi

    marker=$(patch_marker "$patch")
    target=$(patch_target_file "$patch")

    if [[ -z "$marker" ]]; then
        echo "$LOG_PREFIX FAIL: $name has no '+#' marker — patches must start added lines with a # comment for idempotency detection" >&2
        _record_fail "$name"
        continue
    fi

    if [[ -z "$target" || ! -f "$TARGET_DIR/$target" ]]; then
        echo "$LOG_PREFIX FAIL: $name targets $target which doesn't exist under $TARGET_DIR" >&2
        _record_fail "$name"
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
            _record_fail "$name"
        fi
    else
        echo "$LOG_PREFIX FAIL: $name does not apply to current $TARGET_DIR — upstream framework may have changed" >&2
        _record_fail "$name"
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

# Patch-drift ntfy alert (GH#3013 follow-up, 2026-07-14). apply.sh exits non-zero
# on failure but BOTH invokers swallow the rc (start.sh Phase 7b `|| echo`, the 5-min
# cron just appends to a log nobody watches) — patches 007/008/012-headless failed
# silently for weeks. Surface failed>0 as a push notification.
#   - Config comes from ${HOME}/.config/aidevops/credentials.sh (targeted extraction,
#     NOT sourced — no side effects). A FILE is the only channel that reaches the
#     cron context: Cloudron cron strips container env (two-gate propagation trap).
#   - Vars: AIDEVOPS_PATCH_ALERT_URL (ntfy server/topic URL), AIDEVOPS_PATCH_ALERT_TOKEN
#     (write-only ntfy token). Unset/missing file → no alert, patching unaffected.
#   - Dedup: one alert per UNIQUE failure-set per 6h (sentinel keyed on the set's hash),
#     so a persistent failure doesn't fire 288 alerts/day but a CHANGED failure-set
#     alerts immediately.
#   - Fail-open throughout: alerting must never affect the apply result or rc.
if [[ $failed -gt 0 ]]; then
    _creds="${HOME:-/app/data}/.config/aidevops/credentials.sh"
    _alert_url=""
    _alert_token=""
    if [[ -f "$_creds" ]]; then
        _alert_url=$(sed -n -E 's/^(export[[:space:]]+)?AIDEVOPS_PATCH_ALERT_URL=//p' "$_creds" | head -1 | tr -d '"'"'"'') || true
        _alert_token=$(sed -n -E 's/^(export[[:space:]]+)?AIDEVOPS_PATCH_ALERT_TOKEN=//p' "$_creds" | head -1 | tr -d '"'"'"'') || true
    fi
    if [[ -n "$_alert_url" ]]; then
        _fingerprint=$(printf '%s' "$failed_names" | md5sum 2>/dev/null | cut -c1-12) || _fingerprint="nofp"
        _sentinel_dir="${HOME:-/app/data}/.aidevops/cache"
        _sentinel="${_sentinel_dir}/patch-drift-alert-${_fingerprint}.stamp"
        _now=$(date +%s)
        _last=$(stat -c %Y "$_sentinel" 2>/dev/null || echo 0)
        if (( _now - _last >= 21600 )); then
            mkdir -p "$_sentinel_dir" 2>/dev/null || true
            : > "$_sentinel" 2>/dev/null || true
            _host="${CLOUDRON_APP_DOMAIN:-$(hostname 2>/dev/null || echo unknown)}"
            _hdr_auth=()
            [[ -n "$_alert_token" ]] && _hdr_auth=(-H "Authorization: Bearer ${_alert_token}")
            curl -fsS -m 10 -X POST \
                -H "Title: aidevops patch drift [${_host}]" \
                -H "Priority: high" \
                -H "Tags: warning,package" \
                "${_hdr_auth[@]}" \
                -d "apply.sh: ${failed} packaged patch(es) could not be applied on ${_host}: ${failed_names}. Runtime behavior is UNKNOWN; verify whether upstream superseded the patch before declaring the protection inactive. Diagnose: Cloudron exec <app> -- gosu cloudron:cloudron /app/code/patches/apply.sh. Ref scalepass-work#3013 pattern." \
                "$_alert_url" >/dev/null 2>&1 \
                || echo "$LOG_PREFIX WARN: patch-drift alert POST failed (ntfy unreachable?)" >&2
        fi
    fi
fi

[[ $failed -eq 0 ]]
