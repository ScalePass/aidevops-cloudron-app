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
├── 007-takeover-pr-skip-review-gate.patch
├── 008-takeover-pr-required-checks-bypass.patch
├── 009-private-repo-no-pro-treated-as-no-branch-protection.patch
├── 010-private-repo-no-pro-treated-as-no-rulesets.patch
├── 011-pulse-wrapper-zombie-detection-extended.patch
├── 012-repos-registration-cross-client-pulse-gate.patch
├── 013-npm-cache-gc.patch
├── tests/
│   └── test-012-cross-client-pulse-gate.sh     acceptance test for patch 012 (#2999)
└── configs/
    └── model-routing-table.json            per-client config drop (NOT a patch — full-file)
```

## How apply.sh works

For each `.patch` file:

1. **Idempotency probe:** extract the first `+#` comment line from the patch (its "marker") and grep the target file for it. If found → skip silently. If not found → forward apply.
2. **Path translation (F7, 2026-05-18):** rewrite `--- a/.agents/X` and `+++ b/.agents/X` headers in-flight to `--- a/agents/X` and `+++ b/agents/X` before piping to `patch -p1`. See **Path convention** below for why.
3. **Forward apply:** `patch -p1 --forward --batch --silent --reject-file=/dev/null < <translated-stream>`. The `--batch` flag prevents auto-reversal (a known pitfall in `patch` when applied to already-modified files).
4. **Post-condition check:** grep the target for the marker again. If now present → success. If absent → loud failure (upstream framework changed under us).

For `configs/`:

- All files under `configs/` are copied verbatim to `/app/data/.aidevops/agents/custom/configs/` (the framework's documented per-client override path). These are not patches; they are full-file drop-ins that the framework reads in preference to its built-in defaults.

`apply.sh` is invoked from `start.sh` Phase 7b (once at container start) and from a `/etc/cron.d/scalepass-patches-reapply` cron entry installed by start.sh Phase 7c (every 5 minutes, to handle in-container framework updates).

## Path convention (read this before writing a new patch)

Patches in this directory use the **upstream-repo source layout** (`.agents/scripts/X`) in their unified-diff headers:

```diff
--- a/.agents/scripts/pulse-wrapper.sh
+++ b/.agents/scripts/pulse-wrapper.sh
```

The aidevops framework is deployed under `/app/data/.aidevops/agents/` (no leading dot) — the layout drops `.agents/` to `agents/`. Pre-F7 (`apply.sh` before 2026-05-18) this caused both the file-existence probe and `patch -p1` to resolve to `/app/data/.aidevops/.agents/X`, which never exists, and the script silently failed every cron run. The effects attributed to patches 001/003 were actually being delivered by Cloudron app env vars masking the failure (see GH#3002).

The fix lives in `apply.sh`:

- `patch_target_file()` rewrites `.agents/X` → `agents/X` for the existence probe.
- `_translated_patch_stream()` rewrites both `--- a/.agents/` and `+++ b/.agents/` for the `patch -p1` invocation.

**Authoring rule:** keep using `.agents/scripts/X` in new patch headers — that matches the upstream-repo layout and lets `ci/verify-upstream-compat.sh` (and any local `cd ~/Git/aidevops && patch -p1 < …` rebase work) operate against upstream HEAD without further translation. `apply.sh` handles the deployed-layout translation transparently.

**Do not** author patches against bare `agents/X` headers — `apply.sh` will still apply them (the translation is a no-op on already-stripped paths), but you lose upstream-rebase compatibility and the patch will no longer cleanly apply against `~/Git/aidevops` for hand-review.

## Convention for new patches

Every patch MUST start its first added line with a `# [ScalePass patch NNN — short description]` comment. This serves as `apply.sh`'s idempotency marker. Without it, the script can't tell "already applied" apart from "needs apply" and will fail loudly.

The convention also documents intent in-tree — anyone reading the patched file sees exactly which ScalePass patch added each block.

Naming: `NNN-<short-description>.patch` with zero-padded sequence number. Order of application is alphabetic, so dependencies between patches should be reflected in the sequence numbers.

Header paths: use `--- a/.agents/X` / `+++ b/.agents/X` (upstream layout). See **Path convention** above.

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

### 011 — `pulse-wrapper.sh` + `pulse-instance-lock.sh` extend zombie detection to FFJIT + preserve-PID paths

**Why this exists:**

Patch 005 added zombie detection to the `acquire_instance_lock` path in `main()`, but two OTHER PID-file checks had the same bug — `kill -0` / `_get_process_age` return success on zombie processes, leading to "preserve / skip" of defunct PIDs indefinitely:

- **Site A** (`pulse-wrapper.sh:~231`): the FFJIT pre-flight short-circuit. Exits with `[pulse-wrapper] another instance running` when the zombie's age is under `PULSE_LOCK_MAX_AGE_S`, silently blocking all cron-fired pulses.
- **Site B** (`pulse-instance-lock.sh:~448`): the "preserving active pulse PID for transcript-driven decisions" block. Compounds via the `Pulse already running (PID …, Xs elapsed). Skipping.` path.

Discovered 2026-05-27 during a kidzcity-aidevops mission dispatch test (ScalePass/kidzcity-work#28). Two distinct zombie PIDs (1384320 and 1369333) held two separate locks for 41+ minutes despite patch 005 being installed, blocking all pulse cycles.

**What the patch does:**

At both sites, inserts a `/proc/$PID/status` `State:Z` check before the existing `kill -0` / age logic. If the lock holder is a zombie, falls through to the reclaim path (Site A) or writes an IDLE sentinel and proceeds (Site B), with diagnostic log messages citing `ScalePass patch 011`.

**Target files:**
- `.agents/scripts/pulse-wrapper.sh` (deployed at `/app/data/.aidevops/agents/scripts/pulse-wrapper.sh`) — primary target, idempotency marker lives here
- `.agents/scripts/pulse-instance-lock.sh` (deployed at `/app/data/.aidevops/agents/scripts/pulse-instance-lock.sh`) — secondary target in the same multi-file patch

**Note on multi-file patch:** `apply.sh`'s idempotency probe checks only the first file's marker. `patch -p1` applies both file hunks atomically. Since both target files are updated together by `aidevops update`, partial-revert is not a concern in practice.

**Insertion points:**
- Site A: inside the existing `if kill -0 "$_pw_ffjit_pid"` block (line ~231), wrapping the age check in a zombie-state `if/else`.
- Site B: after the stale-process kill block's `fi` (line ~447), before the underfill logic.

**Upstream merge candidate:** YES — same rationale as patch 005. The zombie-detection idiom is a defensive correctness fix for any Linux container deployment where the init process (PID 1) doesn't reap zombies promptly (Cloudron without tini, Docker without `--init`).

**Risk if reverted:** zombie lock holders at either site can silently block pulse dispatch cycles for `PULSE_LOCK_MAX_AGE_S` (default 30 min) or indefinitely (Site B, where there is no age ceiling). Identical to the pre-005 risk surface but at two additional code paths.

**History:** initially deployed as an emergency Python script (`apply-patch-011.py`) directly into running containers on 2026-05-27. Converted to unified-diff format for `apply.sh` integration by GH#2996.

### 012-headless-runtime — RETIRED 2026-07-14 (superseded upstream) — `headless-runtime-lib.sh` drizzle seed fix

> **RETIRED 2026-07-14** (ScalePass/scalepass-work#3013). Patch file removed. The upstream framework
> (`aidevops@3.15.38`) now fixes this bug directly and more completely inside
> `_seed_worker_db_session_context`: the fresh-DB seed uses `sqlite3 … .backup` (a **full** DB copy that
> carries migration state) instead of the old schema-only `.schema | sqlite3` copy, then calls
> `_sync_worker_db_migration_ledgers` to copy the `__drizzle_migrations` (+ `data_migration`, `migration`)
> ledger rows. `_sync_worker_db_migration_metadata` + `_archive_partial_worker_db` additionally handle the
> pre-existing-worker-DB case our patch never covered. Our `opencode --version` workaround targeted the
> old schema-only path, which no longer exists — hence the patch could not apply (`apply.sh` FAIL). Workers
> were **never** at drizzle-crash risk despite the apply failure, because upstream already covers it.
> Historical rationale retained below.

**Why this exists:**

Workers reuse isolated sessions by persisting their `XDG_DATA_HOME`. On retry the worker's `opencode.db` already exists, so the schema-copy guard (`if [[ ! -f "$worker_db" ]]; then ...`) was skipped. But the upstream framework's schema-only copy path (`sqlite3 .schema | sqlite3`) created tables without populating `__drizzle_migrations`. On any second run of opencode against that DB, drizzle's migrator saw the tables exist but no migration row, so it re-applied migration 1 (`CREATE TABLE project`) and crashed with `DrizzleError: table 'project' already exists`.

The `aidevops update` event (2026-05-27 on kidzcity-aidevops @18:50 UTC and research-aidevops @19:23 UTC) silently reverted the emergency Python script fix (`apply-patch-012.py`), forcing the operator to re-apply manually. This unified-diff converts that Python script to a form that `apply.sh` can re-apply idempotently after every framework update.

**What the patch does:**

Replaces the bare `sqlite3 -cmd ".timeout 5000" ... .schema | sqlite3 ...` seed path (v2 upstream shape, post-2026-05-27 framework update) with:

```bash
if ! XDG_DATA_HOME="$isolated_dir" timeout 30 opencode --version >/dev/null 2>&1; then
    sqlite3 "$shared_db" .schema 2>/dev/null | sqlite3 "$worker_db" >/dev/null 2>&1 || return 0
fi
```

`opencode --version` against the isolated `XDG_DATA_HOME` triggers opencode's own drizzle migrator, which correctly populates `__drizzle_migrations`. The legacy schema-only copy is kept as a fallback for environments where `opencode` is unavailable or times out.

**Target file:** `.agents/scripts/headless-runtime-lib.sh` (deployed at `/app/data/.aidevops/agents/scripts/headless-runtime-lib.sh`).

**Insertion point:** function `_seed_worker_db_session_context()` (~line 1056), replacing the 3-line `if [[ ! -f "$worker_db" ]]; then ... fi` block in the upstream v2 shape.

**Upstream merge candidate:** YES — the schema-only copy path has always been broken for retry-with-persisted-session scenarios. The `opencode --version` pre-warm pattern is documented (t2758) and generic to any deployment. Worth submitting upstream.

**Risk if reverted:** workers that retry on a persisted session crash with `DrizzleError: table 'project' already exists` on the second `opencode run` invocation. Newly-created sessions are unaffected (the `if [[ ! -f "$worker_db" ]]` guard is true and the single-run path works).

**History:** initially deployed as an emergency Python script (`apply-patch-012.py`) directly into running containers on 2026-05-27. Converted to unified-diff format for `apply.sh` integration by GH#3001. Note: the filename prefix `012-` is shared with the repos-registration patch (both were independently numbered 012); they target different files and apply in the correct alphabetical order without conflict.

### 012 — `aidevops-repos-lib.sh::_compute_repo_registration_defaults` cross-client pulse:true gate

**Why this exists:**

The framework's repo auto-discovery walks `~/Git/` and registers every git checkout into `~/.config/aidevops/repos.json` via `register_repo()` → `_compute_repo_registration_defaults()`. The original logic defaults `pulse: true` for *any* non-local-only repo with a slug. That means a container that merely clones a cross-client work repo for read purposes — e.g. a worker on `research-aidevops` cloning `ScalePass/kidzcity-work` to read an issue body, or a worktree dispatched at `/app/data/Git/kidzcity-work` — will then have its own Pulse loop claim auto-dispatch issues from that foreign work repo. The container almost always lacks the cross-org PAT (e.g. `KIDZCITY_GITHUB_PAT`) required to action those issues, so worker dispatches stall on 404s, get killed by the watchdog, and burn the first-claim-wins race against the correct container ~50% of the time.

**Incident:** `ScalePass/kidzcity-work#77` on 2026-05-27 — `research-aidevops`'s pulse claimed a kidzcity issue twice (sonnet @18:29, opus @18:55) before the operator manually scrubbed `kidzcity-work` from `research-aidevops`'s `repos.json`. Tracked by `ScalePass/scalepass-work#2999`.

**What the patch does:**

Inserts a new helper `_sp_pulse_allowed_for_slug` immediately before `_compute_repo_registration_defaults`, and replaces the unconditional `default_pulse=true` in the else-branch with a call to the helper. The helper returns success (allowing `pulse: true`) only when:

1. The slug's repo basename is in the framework-meta allowlist: `aidevops`, `aidevops-routines`, `aidevops-cloudron-app`, `scalepass-work`.
2. A matching `<CLIENT>_GITHUB_PAT` env var is exported, where `<CLIENT>` is the repo basename with `-work` / `-aidevops` / `-mission-control` stripped and the result upper-cased.

The existing `_is_mission_control_repo_name` override branch is left intact (mission-control repos preserve `pulse: true`). All other cross-client slugs default to `pulse: false`. The local clone still exists for read purposes (issue bodies, cross-repo greps); only the auto-dispatch pulse claim is gated.

**Self-correcting:** when the operator later provisions a per-client PAT in `~/.config/aidevops/credentials.sh`, the next registration cycle flips that repo's default to `pulse: true`. Already-registered repos preserve their explicit `pulse` value (`register_repo`'s update branch uses `if .pulse == null then .pulse = ... else . end`).

**Target file:** `.agents/scripts/aidevops-cli/aidevops-repos-lib.sh` (deployed at `/app/data/.aidevops/agents/scripts/aidevops-cli/aidevops-repos-lib.sh`).

**Insertion point:** marker comment + helper function inserted before line 128 (the function-header comment of `_compute_repo_registration_defaults`); two-line in-place replacement at the unconditional `default_pulse=true` else-branch (line 143 in upstream).

**Acceptance test:** `patches/patches/tests/test-012-cross-client-pulse-gate.sh` exercises the helper and `_compute_repo_registration_defaults` against 10 inputs covering cross-client work / cross-client aidevops / framework-meta / mission-control / local-only / profile / PAT-present / PAT-mismatch cases. Runs in-process against a temp copy of the deployed library with patch 012 applied via apply.sh's path-translation; requires no network or `gh` authentication.

**Pairs with:** patch 006 (per-client passthrough). The two together form the canonical pattern: patch 006 exposes per-client env vars to sandboxed tool calls; patch 012 uses the *presence* of those vars as the gate for `pulse: true`. An operator who has provisioned a `<CLIENT>_GITHUB_PAT` in `credentials.sh` and exposed it via `sandbox-passthrough.txt` is implicitly opting in to claiming that client's auto-dispatch issues from this container.

**Upstream merge candidate:** YES — the cross-client-leak surface is generic to any multi-client headless deployment, not ScalePass-specific. Worth submitting upstream.

**Risk if reverted:** any container that ever clones a cross-client work repo (deliberately or as a worker side-effect) will pulse-claim that repo's auto-dispatch issues, burning workers on 404s and silently halving effective dispatch throughput per the first-claim-wins race. Identical pre-patch behaviour to the 2026-05-27 incident on `research-aidevops`.

### 013 — `pulse-wrapper.sh` bounded npm cache GC

**Why this exists:**

The worker's npm cache (`${HOME}/.npm/_cacache`, HOME=/app/data) grows **unbounded**. The bulk comes from mission-time `npm install`s — opencode installing dependencies in the node repos it works on — accumulating over weeks of dispatch. Observed ~50–56 GB **per worker** across kidzcity/research/techops/hunta on 2026-07-14, pushing the Cloudron mothership disk to 84% (484 GB / 581 GB). npm has no built-in cache-size cap, and `cache-max` is a deprecated no-op in npm 7+.

**What the patch does:**

Adds a **wrapper-level maintenance stage** to the pulse cycle (immediately after `_pulse_check_runaway_log`, modelled on the same sentinel-gated / fail-open pattern). Each cycle it: rate-limits to once per hour via `${HOME}/.aidevops/cache/npm-cache-gc.stamp`; then `du -sm`'s the cache and runs `npm cache clean --force` **only when it exceeds 5 GB**. Event-driven (no external cron), npm-native (no `rm -rf`), size-gated (near-free when the cache is small), fail-open (`|| true` — never blocks a pulse).

**Target file:** `.agents/scripts/pulse-wrapper.sh` (deployed at `/app/data/.aidevops/agents/scripts/pulse-wrapper.sh`).

**Insertion point:** marker comment + guarded block inserted after the `_pulse_check_runaway_log || true` call in the pre-flight maintenance stages.

**Verified:** hand-canary on kidzcity 2026-07-14 — the block executes on the next real pulse (stamp created, `bash -n` clean, pulse continues normally); the size-gate correctly skipped the clean while the cache was <5 GB.

**Upstream merge candidate:** YES — unbounded npm-cache growth is generic to any long-lived headless worker that runs npm installs, not ScalePass-specific.

**Risk if reverted:** npm cache resumes unbounded growth (~50 GB/worker over ~6 weeks), re-pressuring host disk.

## Config drops index

### `configs/model-routing-table.json`

**What it does:**

Overrides the framework's default routing table with a per-client tier ladder. Restores Anthropic-primary routing for tiers that need reasoning quality (`opus`, `coding`, `pro`); keeps `opencode/big-pickle` as the universal last-resort fallback.

**Deployed at:** `/app/data/.aidevops/agents/custom/configs/model-routing-table.json`

The framework's `select()` reads `agents/custom/configs/model-routing-table.json` FIRST when present, then falls back to `agents/configs/model-routing-table.json` (the framework default).

**Verified against:** kidzcity production state on 2026-05-15. The dispatch sequence Issue #20→PR #21 (2026-05-15) and Issue #22→PR #23 (2026-05-16) both routed correctly to `anthropic/claude-opus-4-7` using this routing table.

**Per-client customization:** when deploying a new client, this file can be overridden at install time with per-client tier preferences. The build harness reads the per-client preferences from the deployment registry record and writes a customized version of this file into the image at build time. v1 ships with the kidzcity defaults; future versions will template this per-client.
