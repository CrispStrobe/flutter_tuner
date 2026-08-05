#!/usr/bin/env bash
# Capture App Store screenshots from a booted iOS Simulator.
#
# The integration test drives the app to each screen and holds it, printing a
# `SHOT_MARKER <name>` line just before each hold. This script watches that log
# and grabs native pixels while the screen is held.
#
# Usage:  tool/capture_screenshots.sh <device-udid> <output-dir>
#
# Why not just script taps from outside? There is no `simctl tap`, and
# AppleScript cannot reach inside the simulated iOS screen — it is one opaque
# canvas to macOS's accessibility tree. Driving from inside the engine with
# WidgetTester is the only reliable route.
set -euo pipefail

DEVICE="${1:?usage: capture_screenshots.sh <device-udid> <output-dir>}"
OUT="${2:?usage: capture_screenshots.sh <device-udid> <output-dir>}"
BUNDLE_ID="com.crispstrobe.CrispTuner"

mkdir -p "$OUT"
LOG="$(mktemp -t crisptuner-shots)"

# Deterministic status bar, as Apple prefers for store screenshots.
xcrun simctl status_bar "$DEVICE" override \
  --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true

echo "running integration test (log: $LOG)"
# GEM_* cleared: `flutter test -d <sim>` shells out to CocoaPods internally and
# a stale GEM_HOME from a Ruby version manager makes it fail confusingly.
PATH="/usr/bin:$PATH" env -u GEM_HOME -u GEM_PATH -u RUBYOPT \
  flutter test integration_test/screenshots_test.dart -d "$DEVICE" >"$LOG" 2>&1 &
TEST_PID=$!

seen=""
while kill -0 "$TEST_PID" 2>/dev/null; do
  while IFS= read -r name; do
    case " $seen " in *" $name "*) continue ;; esac
    [ "$name" = "done" ] && continue
    seen="$seen $name"
    # The app holds each screen for ~6s; wait past the transition, then grab.
    sleep 2
    xcrun simctl io "$DEVICE" screenshot "$OUT/$name.png" >/dev/null 2>&1 \
      && echo "  captured $name" || echo "  FAILED $name"
  done < <(grep -o 'SHOT_MARKER [a-z_]*' "$LOG" 2>/dev/null | awk '{print $2}')
  sleep 1
done

wait "$TEST_PID" || echo "::warning:: test process exited non-zero (screenshots may still be valid)"
echo "--- captured ---"
ls -la "$OUT"
