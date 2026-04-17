#!/usr/bin/env bash
#
# 100-tile stress harness for the Tado canvas. This script spawns
# lightweight no-op tiles (each runs `yes | head -n 200000`, which
# floods the VT stream with ~1 MB of output then sits idle for an
# hour) so you can observe the renderer + Rust core under heavy load.
#
# Usage
#   1. Launch Tado via `make dev`.
#   2. In a separate terminal, run: bash bench/100-tile-stress.sh
#   3. Watch Activity Monitor, MTL_HUD_ENABLED, powermetrics.
#   4. Compare numbers with useMetalRenderer toggled on vs off (the
#      baseline vs rewrite comparison).
#
# This script deliberately uses `yes | head` rather than `tado-deploy`
# with a real agent engine — Claude/Codex tiles would incur API cost
# and unpredictable output, making per-frame measurements noisy. The
# current tado-deploy CLI doesn't expose a "raw shell" engine, so the
# script instead bootstraps tiles via a hand-written shell command.
# If you add a shell engine later, swap the per-tile loop to:
#   tado-deploy "yes | head -n 200000; sleep 3600" --engine shell
#
# Pre-2.6 note: toggle useMetalRenderer in Settings → Rendering to
# capture both baseline (SwiftTerm) and rewrite (Metal) numbers in
# the same harness. After Packet E ships, only the Metal path exists.

set -euo pipefail

TILES="${TILES:-100}"
SLEEP_SECS="${SLEEP_SECS:-3600}"

if ! command -v tado-deploy >/dev/null 2>&1; then
    echo "ERROR: tado-deploy not on PATH — is Tado running?" >&2
    exit 1
fi

echo "Spawning ${TILES} stress tiles (yes | head -n 200000; sleep ${SLEEP_SECS})"
for i in $(seq 1 "${TILES}"); do
    # Plain claude-engine tile running an auto-canned shell command.
    # The agent itself never activates — it just sits in the prompt
    # after dumping the synthetic VT output.
    tado-deploy "run the following shell command verbatim and do nothing else: yes | head -n 200000 && sleep ${SLEEP_SECS}" --engine claude >/dev/null
    if (( i % 10 == 0 )); then
        echo "  ... $i / ${TILES}"
    fi
done

cat <<'INSTRUCTIONS'

Spawned. Measurement commands to run in parallel:

  # CPU + thermal
  top -pid $(pgrep -x Tado | head -1)
  sudo powermetrics -s thermal,cpu_power -n 5

  # Metal HUD (frame time)
  MTL_HUD_ENABLED=1 make dev      # restart Tado with HUD, then re-spawn

  # Power usage
  sudo powermetrics -s tasks --samplers tasks -n 2 | grep -A1 Tado

Record results in bench/BENCH.md under "100-tile stress" with the date,
build commit, and useMetalRenderer state.
INSTRUCTIONS
