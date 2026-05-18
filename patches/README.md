# ScalePass patches against the aidevops framework

This directory contains modifications to the upstream `aidevops` framework that get applied at every container start (and re-applied every 5 minutes by cron, to survive in-container `aidevops update` events that overwrite the framework files).

## Layout

```
patches/
├── apply.sh                                deterministic, idempotent re-applier
├── README.md                               this file
├── 001-pulse-wrapper-allowlist-and-home.patch
├── 003-account-slot-multiplier-default.patch
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

### 003 — `pulse-capacity.sh` account slot multiplier default 2 → 4

**Why this exists:**

`pulse_apply_provider_load_capacity_cap` derives `account_cap = account_available × PULSE_PROVIDER_ACCOUNT_SLOT_MULTIPLIER`, where the env var defaults to `2`. With a 1-account OAuth pool that pins `account_cap=2`, which cascades to `effective_slots=2` and `max_parallel ≤ 2` (clamped at `pulse-dispatch-lib.sh:1358`). The downstream `Dispatch_max: parallel iter=3 — stopping (... effective_slots=2)` log line is this cap in action — dispatch is throttled regardless of worker-pool capacity or PR backlog.

Setting `PULSE_PROVIDER_ACCOUNT_SLOT_MULTIPLIER=N` in the operator shell does **not** propagate into the gosu-spawned pulse-wrapper process tree (same root cause as patch 002's HOME bug — Cloudron-spawned children don't inherit ad-hoc operator env). Patching the default sidesteps the propagation gap.

Raised to `4` as a conservative envelope test (2× upstream). With 1 account this gives `account_cap=4` and `effective_slots=4`. Anthropic's rate-limit halving rule (`final_max = (final_max+1)/2` in `pulse-capacity.sh` when `rate_limits > 0`) is still in force — under sustained 429s the dispatcher will oscillate 4→2→4 rather than runaway. If oscillation stays mild (occasional halving, recovers within 1-2 cycles), consider bumping to `6`. If severe (saturating at 1-2 indefinitely), roll back to `:-3` or `:-2`.

**Target file:** `.agents/scripts/pulse-capacity.sh` (deployed at `/app/data/.aidevops/agents/scripts/pulse-capacity.sh`)

**Insertion point:** marker in the function header doc-block above `pulse_apply_provider_load_capacity_cap`; in-place edit of the `account_multiplier` default on line 277.

**Upstream merge candidate:** NO — this is bespoke tuning for the Claude Max OAuth single-account deployment shape. Upstream's `:-2` default is correct for the general OAuth-pool case where over-eager dispatch trips per-account rate-limits faster than the halving rule can damp them.

**Risk if reverted:** dispatch throughput halves on single-account deployments (back to iter≤2). No data loss; pure throughput regression.

**What to watch after deploy:**

- `pulse.log` for `Dispatch_capacity: ... account_cap=4` (confirms patch is active)
- `pulse.log` for `Dispatch_max: parallel iter=4` or higher (confirms cap is no longer at 2)
- `pulse.log` for repeated `rate_limits > 0` followed by `final_max=(final_max+1)/2` halving — that's the oscillation pattern to weigh

## Config drops index

### `configs/model-routing-table.json`

**What it does:**

Overrides the framework's default routing table with a per-client tier ladder. Restores Anthropic-primary routing for tiers that need reasoning quality (`opus`, `coding`, `pro`); keeps `opencode/big-pickle` as the universal last-resort fallback.

**Deployed at:** `/app/data/.aidevops/agents/custom/configs/model-routing-table.json`

The framework's `select()` reads `agents/custom/configs/model-routing-table.json` FIRST when present, then falls back to `agents/configs/model-routing-table.json` (the framework default).

**Verified against:** kidzcity production state on 2026-05-15. The dispatch sequence Issue #20→PR #21 (2026-05-15) and Issue #22→PR #23 (2026-05-16) both routed correctly to `anthropic/claude-opus-4-7` using this routing table.

**Per-client customization:** when deploying a new client, this file can be overridden at install time with per-client tier preferences. The build harness reads the per-client preferences from the deployment registry record and writes a customized version of this file into the image at build time. v1 ships with the kidzcity defaults; future versions will template this per-client.
