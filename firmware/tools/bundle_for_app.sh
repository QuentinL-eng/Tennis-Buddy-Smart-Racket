#!/usr/bin/env bash
# Builds the racket firmware and copies it into the apps, which offer it as an over-the-air (BLE) update
# whenever the connected racket reports an older version. Run after bumping TB_FW_MINOR in protocol.h.
set -euo pipefail
cd "$(dirname "$0")/.."

PIO=${PIO:-$(command -v pio || ls ~/Library/Python/*/bin/pio 2>/dev/null | tail -1)}
"$PIO" run -e xiao_esp32c3

major=$(awk '/#define TB_FW_MAJOR/ {print $3}' include/protocol.h)
minor=$(awk '/#define TB_FW_MINOR/ {print $3}' include/protocol.h)
out=../apple/Shared/Resources
cp .pio/build/xiao_esp32c3/firmware.bin "$out/RacketFirmware.bin"
printf '{ "version": "%s.%s" }\n' "$major" "$minor" > "$out/RacketFirmware.json"
echo "Bundled firmware $major.$minor ($(wc -c < "$out/RacketFirmware.bin" | tr -d ' ') bytes) into $out"
