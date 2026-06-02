# Upstream pins

This fork tracks two upstream repositories. Both pins are intentional and changed deliberately.

## `marcusquinn/aidevops-cloudron-app` (our fork base)

| Field | Value |
|---|---|
| Repo | `https://github.com/marcusquinn/aidevops-cloudron-app` |
| Pinned ref | `main@2527354fd8aa (post-v0.1.0)` |
| Pinned SHA | 2527354fd8aa9722e403d8abaede7cc28271b777 |
| Tag published | 2026-03-16 |

We forked from this point. All modifications in this directory are diffs against that baseline. See `MODIFICATIONS.md` (forthcoming) for a per-file change list.

## `aidevops` npm package (installed by Dockerfile at build time)

| Field | Value |
|---|---|
| Package | `aidevops` |
| Pinned version | `3.20.8` |
| Source repo | `https://github.com/marcusquinn/aidevops` |
| Source SHA | `cbe938b78de1d2dea9a626990e2ee2166143e174` (npm gitHead for v3.20.8) |
| Tag checked | 2026-06-02 |

The Dockerfile installs this specific version via `npm install -g aidevops@3.20.8`. The container's `start.sh` Phase 7 runs `aidevops update`, which populates `/app/data/.aidevops/` from the npm package's templates.

## Why these pins

- **cloudron-app at main@2527354fd8aa (post-v0.1.0):** only release. The upstream cloudron-app is young (March 2026) and we want a known-tested baseline for our v1.
- **aidevops at 3.20.8:** TechOps GPT-5.5 proof pin. Upstream latest was confirmed as 3.20.8 on 2026-06-02 and includes the OpenAI OAuth pool + gpt-5.5 routing. Existing hunta/kidzcity/research remain on their proven image until TechOps validates this branch. The CI compat check (`ci/verify-upstream-compat.sh`) verifies ScalePass patches against upstream HEAD before rebuild.

## Upgrading the pins

When upgrading either pin:

1. Update this file with new SHA/version.
2. Run `ci/verify-upstream-compat.sh` to confirm all patches still apply against the new framework version.
3. If any patch fails: either rebase it against the new version OR confirm upstream has integrated the fix and remove the patch (with a note in `patches/README.md`).
4. Build a test image, deploy to a throwaway client, run the identity self-test.
5. Only after self-test passes, bump the production pin.

## Patch upstream-merge candidates

Per ADR-019 (forthcoming), we periodically review whether our patches should be submitted upstream:

| Patch | Upstream merge candidate? | Notes |
|---|---|---|
| 001 — allowlist defang | Maybe — only useful if Cloudron-style env injection is common upstream | Defensive against `AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=opencode` being set externally |
| 002 — HOME normalize | YES — fixes a genuine `gosu`-vs-`su -` HOME bug that affects any Cloudron-style deployment | Generally useful; submit as upstream PR |

Patch 003 (worktree-sentinel registration in manual dispatch path) was already integrated upstream in v3.15.54 and is no longer in our patches set.
