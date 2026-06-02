# TechOps Playwright Chromium dependency image

Purpose: unblock desktop/mobile screenshot QA in non-interactive workers.

Root cause: Playwright Chromium could download but failed to launch because the Cloudron runtime image lacked OS libraries such as `libatk-1.0.so.0`; the runtime `cloudron` user cannot run `sudo npx playwright install-deps chromium`.

Change: bake Chromium runtime dependencies into the Cloudron image at build time. Prove on `techops-aidevops` only before any shared tenant rollout.

Do not roll this image to hunta/kidzcity/research without explicit operator approval.
