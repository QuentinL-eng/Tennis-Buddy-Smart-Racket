#!/usr/bin/env bash
#
# Start the USB-C tunnel and the packet receiver together.
#
#   ./tools/run_iphone_test.sh
#
# iproxy listens on the host port and forwards to the phone's port 5000, so the
# receiver connects to the tunnel instead of binding the same port. Override
# PORT / DEVICE_PORT / JSONL from the environment.
set -euo pipefail

PORT="${PORT:-5000}"
DEVICE_PORT="${DEVICE_PORT:-$PORT}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
JSONL="${JSONL:-$ROOT/runs/iphone_$(date +%Y%m%d_%H%M%S).jsonl}"

if ! command -v iproxy >/dev/null 2>&1; then
    cat >&2 <<'MSG'
iproxy was not found. Install libimobiledevice:
  macOS:   brew install libimobiledevice
  Windows: install libimobiledevice plus Apple Mobile Device Service,
           then run iproxy from the same shell that can see the phone.
MSG
    exit 1
fi

mkdir -p "$(dirname "$JSONL")"

cleanup() {
    if [[ -n "${IPROXY_PID:-}" ]] && kill -0 "$IPROXY_PID" 2>/dev/null; then
        kill "$IPROXY_PID" 2>/dev/null || true
        wait "$IPROXY_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

iproxy "$PORT" "$DEVICE_PORT" &
IPROXY_PID=$!
sleep 0.5

if ! kill -0 "$IPROXY_PID" 2>/dev/null; then
    echo "iproxy exited immediately: is host port $PORT already in use, or is the phone unlocked and trusted?" >&2
    exit 1
fi

echo "iproxy: host $PORT -> device $DEVICE_PORT (pid $IPROXY_PID)"
echo "jsonl:  $JSONL"
echo "Now start TennisCamera on the phone and press \"Start capture\"."
echo

python3 "$HERE/iproxy_receiver.py" --connect --port "$PORT" --jsonl "$JSONL"
