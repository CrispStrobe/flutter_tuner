#!/usr/bin/env bash
# Copy CometBeat's Flutter-free pitch engines into bench/lib/cometbeat/.
#
# Same reason as tool/sync_core.sh: this benchmark is a pure-Dart package, and
# a path dependency on a Flutter app drags in the Flutter SDK. CometBeat's
# whole `lib/core/audio/transcription/` tree is Flutter-free — all 67 files,
# verified — so the engines can be benchmarked directly; they just have to be
# copied rather than depended on.
#
#   tool/sync_cometbeat.sh [--check] [path-to-cometbeat]
#
# `--check` verifies the copies match the source and exits non-zero if not,
# which is what CI runs so a silently-stale copy cannot produce numbers
# attributed to CometBeat.
set -euo pipefail

CHECK=0
SRC_ROOT=""
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    *) SRC_ROOT="$a" ;;
  esac
done
SRC_ROOT="${SRC_ROOT:-/mnt/volume1/cometbeat}"
SRC="$SRC_ROOT/lib/core/audio"
DEST="$(cd "$(dirname "$0")/.." && pwd)/lib/cometbeat"

if [ ! -d "$SRC" ]; then
  echo "cometbeat not found at $SRC_ROOT" >&2
  exit 2
fi

# Flat destination: the package: imports are rewritten to relative ones, so
# the directory layout does not need to survive.
FILES=(
  "transcription/contracts.dart"
  "transcription/route.dart"
  "transcription/note_hmm.dart"
  "transcription/tuning.dart"
  "transcription/pyin.dart"
  "transcription/dio.dart"
  "transcription/basic_pitch.dart"
  "chroma_analysis.dart"
  "pitch_analysis.dart"
  "crisp_dsp/resample.dart"
)

mkdir -p "$DEST"
status=0
for rel in "${FILES[@]}"; do
  base="$(basename "$rel")"
  tmp="$(mktemp)"
  # `package:comet_beat/core/audio/<anything>/<file>.dart` -> `<file>.dart`,
  # since everything lands in one directory.
  sed -E "s|package:comet_beat/core/audio/([a-z_]+/)*([a-z_]+\.dart)|\2|g" \
    "$SRC/$rel" > "$tmp"
  if [ "$CHECK" = "1" ]; then
    if ! diff -q "$tmp" "$DEST/$base" >/dev/null 2>&1; then
      echo "STALE: $base differs from $SRC_ROOT" >&2
      status=1
    fi
  else
    mv "$tmp" "$DEST/$base"
    echo "synced $base"
  fi
  rm -f "$tmp"
done

if [ "$CHECK" = "1" ] && [ "$status" = "0" ]; then
  echo "cometbeat copies are current"
fi
exit $status
