# ScalePass aidevops-cloudron-app

Cloudron app package for ScalePass-managed aidevops workers. Fork of [`marcusquinn/aidevops-cloudron-app`](https://github.com/marcusquinn/aidevops-cloudron-app) v0.1.0 with patches baked in.

## What this is

A Docker image that, when deployed via Cloudron, runs an autonomous code-PR worker that:

- Polls GitHub issues labeled `auto-dispatch` + `tier:*` on configured repos.
- Dispatches one worker per claimed issue, routing to `anthropic/claude-opus-4-7` (or other models per tier — see `patches/configs/model-routing-table.json`).
- Bills Anthropic calls to the OAuth pool entry configured for this client (per ADR-014; see ScalePass deployment registry).
- Auto-merges resulting PRs that pass the framework's safety gates.

## What's different from upstream

| Layer | Upstream | This fork |
|---|---|---|
| `Dockerfile` | `npm install -g aidevops` (unversioned) | **Pinned** `aidevops@3.15.38`; adds `patch` + `cron` packages; `COPY patches /app/code/patches` |
| `start.sh` Phase 3 | `worker.json` has `"pulse": {"enabled": false}` | `"pulse": {"enabled": true}` — Pulse-loop is the deployment shape |
| `start.sh` Phase 7b | absent | NEW — runs `patches/apply.sh` once at container start |
| `start.sh` Phase 7c | absent | NEW — installs `/etc/cron.d/scalepass-patches-reapply` (every 5 min) |
| `start.sh` Phase 9 | launches `server.js` only | starts `cron` daemon before launching `server.js` |
| `CloudronManifest.json` | `id: sh.aidevops.worker`, no env block | `id: io.scalepass.aidevops.worker`, env block with `AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=anthropic,opencode` |

All other files (server.js, logo.png) are inherited verbatim. See `UPSTREAM.md` for pinned SHAs and the upgrade ritual.

## Layout

```
.
├── README.md                                  this file
├── UPSTREAM.md                                pinned cloudron-app SHA + aidevops npm version
├── Dockerfile                                 modified (3 changes)
├── start.sh                                   modified (3 phase additions)
├── CloudronManifest.json                      modified (env block, manifest id)
├── server.js                                  inherited verbatim (not in this dir; fetched at fork)
├── logo.png                                   inherited verbatim (not in this dir; fetched at fork)
├── patches/                                   contents COPY'd to /app/code/patches/ at build
│   ├── README.md                              what each patch is + the convention
│   ├── apply.sh                               deterministic idempotent re-applier
│   ├── 001-pulse-wrapper-allowlist-and-home.patch
│   └── configs/
│       └── model-routing-table.json           per-client routing override
└── ci/
    └── verify-upstream-compat.sh              quarterly compat check against upstream HEAD
```

This local mirror at `/opt/scalepass/scalepass-work/patches/` is for development. The corresponding GitHub fork at `ScalePass/aidevops-cloudron-app` (forthcoming) is the deployment build artifact.

## Build sequence

Per ADR-017 (`../docs/adr/ADR-017-non-clone-cloudron-deployment.md`), a new client install consumes:

1. This fork at its pinned SHA.
2. The `aidevops` npm package at the version pinned in Dockerfile (`3.15.38` for v1).
3. The patches in `patches/` (idempotent, re-applied every 5 min by cron).
4. The per-client deployment registry record (slug, FQDN, OAuth account ref, ntfy topic).

The build harness (forthcoming at `/opt/scalepass/scalepass-work/scripts/`) orchestrates the build + Cloudron install + post-install bootstrap + identity self-test.

## How to update the `aidevops` npm pin

1. Run `ci/verify-upstream-compat.sh` to see if our patches still apply against the new version.
2. If `OBSOLETE`: drop the patch from `patches/` and remove its entry from `patches/README.md`.
3. If `CONFLICT`: manually rebase the patch against the new upstream code.
4. Update `Dockerfile`'s `npm install -g aidevops@X.Y.Z`.
5. Update `UPSTREAM.md` with the new version + SHA.
6. Build a test image, deploy to a throwaway client, run identity self-test.
7. Bump the production pin only after self-test passes.

## How to add a new patch

1. Add the modification to a fresh copy of the upstream framework at the pinned version.
2. The first added line MUST start with `# [ScalePass patch NNN — short description]`. This is `apply.sh`'s idempotency marker.
3. Generate a unified diff: `diff -u upstream/path mod/path > patches/NNN-short-description.patch`.
4. Adjust the diff's header lines to `--- a/path` and `+++ b/path` for `patch -p1` to work.
5. Smoke-test against a fresh upstream copy: `TARGET_DIR=... PATCHES_DIR=patches patches/apply.sh`.
6. Document the patch in `patches/README.md`.

## Identity self-test

After deploying a worker via this fork, run the identity self-test:

```bash
gh issue create --repo <owner>/<repo> \
  --title "ScalePass install self-test — $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --label "auto-dispatch,tier:thinking" \
  --body "Write account-binding-recheck.txt with: model name, UTC timestamp, first 32 chars of access_token, active anthropic pool email. Then open a PR."
```

Wait up to 30 min. Pass criteria per ADR-017 § Step 9:

- Worker model line starts with `anthropic/claude-opus-4-` (any minor version).
- Token-prefix line non-empty.
- Email line matches the operator's expected account.
- PR opened and auto-merged.

Poll via REST API, NOT `gh issue view --json comments` — see `../docs/investigations/2026-05-16-oauth-race-test-and-locked-issue-comments-quirk.md`.

## License

MIT. Inherited from upstream marcusquinn/aidevops-cloudron-app, which is MIT-licensed by Marcus Quinn.
