# ScalePass patches against the aidevops framework

This directory contains modifications to the upstream `aidevops` framework that get applied at every container start (and re-applied every 5 minutes by cron, to survive in-container `aidevops update` events that overwrite the framework files).

## Layout

```
patches/
├── apply.sh                                deterministic, idempotent re-applier
├── README.md                               this file
├── 001-pulse-wrapper-allowlist-and-home.patch
└── configs/
    └── model-routing-table.json            per-client config drop (NOT a patch — full-file)
```

## How apply.sh works

For each `.patch` file:

1. **Idempotency probe:** extract the first `+#` comment line from the patch (its "marker") and grep the target file for it. If found → skip silently. If not found → forward apply.
2. **Forward apply:** `patch -p1 --forward --batch --silent --reject-file=/dev/null < <patch>`. The `--batch` flag prevents auto-reversal (a known pitfall in `patch` when applied to already-modified files).
3. **Post-condition check:** grep the target for the marker again. If now present → success. If absent → loud failure (upstream framework changed under us).

For `configs/`:

- All files under `configs/` are copied verbatim to `/app/data/.aidevops/agents/custom/configs/` (the framework's documented per-client override path). These are not patches; they are full-file drop-ins that the framework reads in preference to its built-in defaults.

`apply.sh` is invoked from `start.sh` Phase 7b (once at container start) and from a `/etc/cron.d/scalepass-patches-reapply` cron entry installed by start.sh Phase 7c (every 5 minutes, to handle in-container framework updates).

## Convention for new patches

Every patch MUST start its first added line with a `# [ScalePass patch NNN — short description]` comment. This serves as `apply.sh`'s idempotency marker. Without it, the script can't tell "already applied" apart from "needs apply" and will fail loudly.

The convention also documents intent in-tree — anyone reading the patched file sees exactly which ScalePass patch added each block.

Naming: `NNN-<short-description>.patch` with zero-padded sequence number. Order of application is alphabetic, so dependencies between patches should be reflected in the sequence numbers.

## Patches index

### 001 — `pulse-wrapper.sh` allowlist defang + HOME normalize

**Why this exists:**

- **Allowlist defang:** the Cloudron container's env can set `AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=opencode`, which forces opencode-only model selection regardless of the routing table. The framework's documented guidance (see `model-routing.md` upstream) is to OMIT the allowlist when you want the routing table to drive selection. The patch unsets the env var only when it equals exactly `"opencode"` (so intentional multi-provider settings like `"anthropic,opencode"` are preserved).
- **HOME normalize:** the upstream `start.sh` spawns pulse-wrapper via `gosu cloudron:cloudron` which switches uid but NOT HOME (unlike `su -`). The inherited `HOME=/root` makes `${HOME}/.aidevops/oauth-pool.json` resolve to a non-existent path, causing Pulse to report `provider_accounts_total=0` and refuse to dispatch. The patch normalizes `HOME=/app/data` when `/app/data` exists.

**Target file:** `.agents/scripts/pulse-wrapper.sh` (deployed at `/app/data/.aidevops/agents/scripts/pulse-wrapper.sh`)

**Insertion point:** immediately after `set -euo pipefail` near the top of the file.

**Upstream merge candidate:** HOME normalize is a clear bug fix that affects any Cloudron-style deployment using `gosu`; submit as upstream PR (see `../UPSTREAM.md`).

**Risk if reverted:** dispatches fall back to opencode/big-pickle. Pool capacity reads incorrectly. No data loss; degraded routing.

## Config drops index

### `configs/model-routing-table.json`

**What it does:**

Overrides the framework's default routing table with a per-client tier ladder. Restores Anthropic-primary routing for tiers that need reasoning quality (`opus`, `coding`, `pro`); keeps `opencode/big-pickle` as the universal last-resort fallback.

**Deployed at:** `/app/data/.aidevops/agents/custom/configs/model-routing-table.json`

The framework's `select()` reads `agents/custom/configs/model-routing-table.json` FIRST when present, then falls back to `agents/configs/model-routing-table.json` (the framework default).

**Verified against:** kidzcity production state on 2026-05-15. The dispatch sequence Issue #20→PR #21 (2026-05-15) and Issue #22→PR #23 (2026-05-16) both routed correctly to `anthropic/claude-opus-4-7` using this routing table.

**Per-client customization:** when deploying a new client, this file can be overridden at install time with per-client tier preferences. The build harness reads the per-client preferences from the deployment registry record and writes a customized version of this file into the image at build time. v1 ships with the kidzcity defaults; future versions will template this per-client.
