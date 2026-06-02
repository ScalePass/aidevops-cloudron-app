# TechOps GPT-5.5 image branch

Purpose: prove the OpenAI GPT-5.5 worker path on `techops-aidevops` only before any shared rollout.

Pinned framework: `aidevops@3.20.8`.
OpenCode source: GitHub release `v1.15.13` at branch creation time. Capture `opencode --version` from build/install logs.
Provider allowlist: `openai,opencode`.
OAuth command in Cloudron terminal:

```bash
gosu cloudron:cloudron env HOME=/app/data USER=cloudron aidevops model-accounts-pool add openai
```

Do not roll this image to hunta/kidzcity/research until TechOps smoke tests pass.
