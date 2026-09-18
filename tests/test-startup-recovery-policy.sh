#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
START="$ROOT/start.sh"

bash -n "$START"

if grep -qE '^chown -hR cloudron:cloudron /app/data$' "$START"; then
	echo "recursive app-data chown remains" >&2
	exit 1
fi

grep -qF 'PULSE_ENABLED=false' "$START"
grep -qF 'Skipping aidevops update while supervisor pulse is disabled' "$START"
grep -qF 'Supervisor pulse setup skipped by configuration' "$START"
grep -qF 'Cron disabled with supervisor pulse' "$START"
grep -qF 'timeout 20 gosu cloudron:cloudron gh auth login' "$START"

echo "startup recovery policy: PASS"
