#!/usr/bin/env bash
# Keep bench/lib/app/*.dart byte-identical to the app's Flutter-free core.
#
# The benchmark cannot path-depend on the app package: that pulls in the
# Flutter SDK and `dart run` stops working. The three files below have no
# Flutter import, so they are simply copied.
#
#   tool/sync_core.sh          copy lib/*.dart -> bench/lib/app/*.dart
#   tool/sync_core.sh --check  exit 1 if they have drifted (use in CI)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
src="$here/.."
files=(tuner_core.dart detectors.dart fft_real.dart harmonics.dart temperament.dart tunings.dart)
status=0
for f in "${files[@]}"; do
  if [[ "${1:-}" == "--check" ]]; then
    if ! diff -q "$src/lib/$f" "$here/lib/app/$f" >/dev/null; then
      echo "DRIFT: lib/$f differs from bench/lib/app/$f"; status=1
    fi
  else
    cp "$src/lib/$f" "$here/lib/app/$f"
    echo "synced $f"
  fi
done
if [[ "${1:-}" == "--check" && $status -eq 0 ]]; then echo "core files in sync"; fi
exit $status
