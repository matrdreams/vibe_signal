#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Vibe Signal.app"
APP_BIN="$APP/Contents/MacOS/VibeSignalApp"
CLI="$ROOT/dist/vibe-signal"
LOG="$ROOT/.build/manual/smoke-app.log"
SMOKE_RUNTIME="$ROOT/.build/manual/smoke-runtime"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
export VIBE_SIGNAL_APP_SUPPORT="$SMOKE_RUNTIME/app-support"
export VIBE_SIGNAL_SOCKET="$SMOKE_RUNTIME/vibe-signal.sock"
SOCKET="$("$CLI" paths | awk -F': ' '/^socket:/ { print $2 }')"

if [[ ! -x "$APP_BIN" ]]; then
    echo "App binary not found. Run ./scripts/build-app.sh first." >&2
    exit 1
fi

mkdir -p "$SMOKE_RUNTIME"
rm -f "$SOCKET" "$VIBE_SIGNAL_APP_SUPPORT/state.json" "$VIBE_SIGNAL_APP_SUPPORT/.state.lock"

"$APP_BIN" >"$LOG" 2>&1 &
APP_PID="$!"

cleanup() {
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
    if [[ -x "$LSREGISTER" ]]; then
        "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

for _ in {1..50}; do
    if "$CLI" ping >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

if ! "$CLI" ping >/dev/null 2>&1; then
    echo "Hub did not come online at: $SOCKET" >&2
    cat "$LOG" >&2 || true
    exit 1
fi

"$APP_BIN" >"$LOG.second" 2>&1 &
SECOND_PID="$!"
sleep 0.5
if kill -0 "$SECOND_PID" >/dev/null 2>&1; then
    echo "Second app instance did not exit while hub was online" >&2
    kill "$SECOND_PID" >/dev/null 2>&1 || true
    wait "$SECOND_PID" >/dev/null 2>&1 || true
    exit 1
fi
wait "$SECOND_PID" >/dev/null 2>&1 || true

"$CLI" emit \
    --require-hub \
    --source demo \
    --adapter vibe-signal-cli \
    --session-id demo \
    --workspace "$ROOT" \
    --state blocked \
    --reason approval \
    --message "Waiting for user input" \
    >/dev/null
"$CLI" status
