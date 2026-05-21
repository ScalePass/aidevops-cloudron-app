# ScalePass patches against the aidevops framework

This directory contains modifications to the upstream `aidevops` framework that get applied at every container start (and re-applied every 5 minutes by cron, to survive in-container `aidevops update` events that overwrite the framework files).

## Layout

```
patches/
├── apply.sh                                deterministic, idempotent re-applier
├── README.md                               this file
├── 001-pulse-wrapper-allowlist-and-home.patch
├── 003-account-slot-multiplier-default.patch
├── 004-opus-concurrency-cap-pgrep-dedup.patch
├── 005-pulse-wrapper-zombie-detection-and-exit-logging.patch
├── 006-sandbox-exec-per-client-passthrough.patch
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

### 004 — `pulse-dispatch-lib.sh::_dispatch_check_model_concurrency_cap` dedup by --dir

**Why this exists:**

The framework caps concurrent opus workers via `pgrep -f 'opencode.*-m anthropic/claude-opus'` (pulse-dispatch-lib.sh:1138). That regex matches BOTH the `sandbox-exec-helper.sh run … -- opencode run … -m anthropic/claude-opus-X …` parent process AND the `opencode run … -m anthropic/claude-opus-X …` child process for each worker — so each actual worker counts as **2** in the cap check.

Net effect: `OPUS_CONCURRENCY_CAP=4` gates dispatches at **2 actual concurrent workers** (sometimes more, depending on mid-lifecycle race), and the gate is violated upward routinely (we observed `inflight=14` during the 2026-05-18 envelope test).

Compounding bug: deferred candidates have no aging / escalation path. Under sustained opus saturation, 89 correctly-labelled `tier:thinking` issues each got deferred 11-28 times (one issue 28×) over 30+ hours, never dispatching, never NMR'd. **2,605 total deferral events across the test window.** Full investigation: `docs/investigations/2026-05-19-f13-silent-dispatch-skip-and-f12-label-docs.md`.

**Fix:** dedupe by the `--dir <worktree>` argv. Both the sandbox-exec-helper and opencode inherit the same `--dir` from headless-runtime-helper.sh, so deduping by it counts each worker exactly once regardless of process lifecycle phase.

```diff
-	_opus_pids=$(pgrep -f 'opencode.*-m anthropic/claude-opus' 2>/dev/null) || true
+	_opus_pids=$(pgrep -af 'opencode.*-m anthropic/claude-opus' 2>/dev/null \
+		| grep -oE -- '--dir [^[:space:]]+' | sort -u) || true
```

**Target file:** `.agents/scripts/pulse-dispatch-lib.sh` (deployed at `/app/data/.aidevops/agents/scripts/pulse-dispatch-lib.sh`)

**Insertion point:** marker in the function-header doc-block above `_dispatch_check_model_concurrency_cap`; pgrep line replacement in the function body.

**Upstream merge candidate:** YES — this is a generic dispatcher correctness bug that affects any deployment using the opus concurrency cap. Worth submitting upstream as a PR.

**Risk if reverted:** opus throughput halves on single-OAuth deployments (back to effective cap=2 actual workers). Heavy opus workloads will see tier:thinking issues stranded in defer-loop.

**Doesn't address:** the secondary bug of no escalation after N defers. That's tracked separately (potential framework PR — apply `needs-maintainer-review` after 5+ defers to match dispatch-backoff convention).

### 005 — `pulse-wrapper.sh` zombie lock-holder detection + explicit exit-reason logging

**Why this exists:**

Two related operability defects observed during the 2026-05-19 kidzcity mini-stress:

- **F-NEW-3 (zombie lock-holder):** the pulse-already-running short-circuit at `pulse-wrapper.sh:~1700` uses `kill -0 $PID` to test if the lock holder is alive. On Linux, `kill -0` returns success for zombie/`<defunct>` processes (the PID remains in the process table until reaped by the parent shell). `_get_process_age` via `ps -p $PID -o etime=` also returns a valid elapsed time for zombies. A defunct pulse-wrapper from an aborted prior cycle held the lock for 24+ minutes during the mini-stress, silently blocking 12+ cron cycles before manual `rm -f` of the pid-file. **Fix:** read `/proc/$PID/status` and check `State:`. If it's `Z` (zombie), fall through to the reclaim path instead of treating it as a healthy lock holder.

- **F-NEW-4 (silent exits):** two early-exit paths return `0` without logging the reason — `_pulse_check_idle_backoff_gate` failure (line ~1735) and `acquire_instance_lock` failure (line ~1786). During the mini-stress, several cron cycles fired but produced only the `pulse-wrapper invoked: pid=N` line with zero further output, making the cause un-diagnosable without code-reading. **Fix:** add explicit `echo "[pulse-wrapper] Exiting: <reason>"` lines before both `return 0` statements.

**Target file:** `.agents/scripts/pulse-wrapper.sh` (deployed at `/app/data/.aidevops/agents/scripts/pulse-wrapper.sh`)

**Insertion points:**
- Marker comment in the function-header doc-block above `main()` (column-0, satisfies apply.sh's `^\+#` marker probe).
- Zombie check inside the existing `if kill -0 "$_ir_pid"` block at line ~1697.
- Exit-reason `echo` lines before `return 0` at lines ~1735 and ~1786.

**Upstream merge candidate:** YES — both fixes are generic operability improvements that benefit any deployment. Zombie PIDs are a defensive correctness issue (kill -0 isn't sufficient on its own); silent exits are an observability deficit. Worth submitting upstream.

**Risk if reverted:** zombie lock holders can silently block dispatch cycles for the duration of `PULSE_LOCK_MAX_AGE_S` (default 1800s = 30 min) until the stale-lock reclaim kicks in. Silent exits make operator triage take 10× longer.

### 006 — `sandbox-exec-helper.sh` per-client env-var passthrough extension

**Why this exists:**

The framework's `sandbox-exec-helper.sh:51` declares `DEFAULT_PASSTHROUGH="PATH HOME USER LANG TERM SHELL"` — a minimal allowlist that strips every other env var from sandboxed tool calls. This is correct security default behaviour. But it means **per-client env vars** (e.g., `KIDZCITY_GITHUB_PAT` for cross-org repo access, `KIDZCITY_NEON_DSN` for the client's DB) **never reach the worker's `gh`/`git`/`python` calls** even when set via `cloudron env set` and even after `~/.config/aidevops/credentials.sh` has been sourced into the pulse-wrapper's own env.

Discovered during the first real kidzcity mission (2026-05-21): the worker repeatedly returned `KIDZCITY_GITHUB_PAT not set` and `gh api repos/jlbryan/ebay → 404` despite the env var being present in the Cloudron app and accessible via `cloudron exec`. The runtime fix was a hardcoded edit to `DEFAULT_PASSTHROUGH` extending it with `GH_TOKEN GITHUB_TOKEN KIDZCITY_GITHUB_PAT KIDZCITY_NEON_DSN`. This patch generalises that fix so future clients don't have to repeat it.

**What the patch does:**

Replaces the single-line `readonly DEFAULT_PASSTHROUGH=…` with a block that reads `${HOME}/.config/aidevops/sandbox-passthrough.txt` (if present) and appends its contents (one env-var name per line; `#` comments and blank lines ignored) to the base allowlist. Per-client extensions are then a config file, not a script patch.

**Target file:** `.agents/scripts/sandbox-exec-helper.sh` (deployed at `/app/data/.aidevops/agents/scripts/sandbox-exec-helper.sh`).

**Insertion point:** replaces line 51 (the original `readonly DEFAULT_PASSTHROUGH=…` declaration).

**Pairs with:** `${HOME}/.config/aidevops/credentials.sh` (sourced by pulse-wrapper.sh:394, GH#17546). The two together form the canonical two-gate per-client env-var propagation pattern. See `docs/10-build-new-client-runbook.md` § "Per-client env-var propagation (two gates)".

**File format (`sandbox-passthrough.txt`):**

```
# Per-client env-var allowlist extension. One name per line.
# Comments and blank lines ignored.
GH_TOKEN
GITHUB_TOKEN
KIDZCITY_GITHUB_PAT
KIDZCITY_NEON_DSN
```

**Operator-managed:** mode 0600, owned by `cloudron:cloudron`. Created at install time by the bootstrap script (registry-driven) and editable by the operator afterwards. **Never** commit this file to the client repo or to scalepass-work — env var names are not secrets, but the convention is that per-client config lives only in the worker app's data volume.

**Upstream merge candidate:** YES — the "extend allowlist via config file" pattern is generally useful and not ScalePass-specific. Submit as upstream PR (see `../UPSTREAM.md`).

**Risk if reverted:** per-client env vars are stripped from sandboxed tool calls. Workers cannot use cross-org GitHub PATs, per-client DB DSNs, or any other client-specific credential beyond `GH_TOKEN`. The same symptom that prompted the patch in the first place.

## Config drops index

### `configs/model-routing-table.json`

**What it does:**

Overrides the framework's default routing table with a per-client tier ladder. Restores Anthropic-primary routing for tiers that need reasoning quality (`opus`, `coding`, `pro`); keeps `opencode/big-pickle` as the universal last-resort fallback.

**Deployed at:** `/app/data/.aidevops/agents/custom/configs/model-routing-table.json`

The framework's `select()` reads `agents/custom/configs/model-routing-table.json` FIRST when present, then falls back to `agents/configs/model-routing-table.json` (the framework default).

**Verified against:** kidzcity production state on 2026-05-15. The dispatch sequence Issue #20→PR #21 (2026-05-15) and Issue #22→PR #23 (2026-05-16) both routed correctly to `anthropic/claude-opus-4-7` using this routing table.

**Per-client customization:** when deploying a new client, this file can be overridden at install time with per-client tier preferences. The build harness reads the per-client preferences from the deployment registry record and writes a customized version of this file into the image at build time. v1 ships with the kidzcity defaults; future versions will template this per-client.
