#!/bin/bash
# Xcode build phase ("Embed CrispASR", Runner target, iOS and macOS): copy
# crispasr.framework into the app's Frameworks folder and sign it.
#
# Embedded, deliberately NOT linked. The app only ever dlopen()s it
# (lib/crispasr_backend_ffi.dart), so it needs to be inside the bundle and
# nothing more. Linking would make it a launch dependency, and the macOS
# slice requires macOS 13.3 while the app supports 10.15: linked, CrispTuner
# would not start on an older Mac. Embedded, dlopen() fails there, the
# models report themselves unavailable, and the tuner runs as before.
#
# A no-op when tool/crispasr/build.sh apple has not been run, so a plain
# `flutter run` keeps working.
set -euo pipefail

XCF="${SRCROOT}/../tool/crispasr/apple/crispasr.xcframework"
if [ ! -d "$XCF" ]; then
  echo "note: CrispASR not fetched (tool/crispasr/build.sh apple) — models will be unavailable"
  exit 0
fi

case "${PLATFORM_NAME}" in
  iphoneos) SLICE=ios-arm64 ;;
  iphonesimulator) SLICE=ios-arm64_x86_64-simulator ;;
  macosx) SLICE=macos-arm64_x86_64 ;;
  *) echo "note: no CrispASR slice for ${PLATFORM_NAME}"; exit 0 ;;
esac

SRC="$XCF/$SLICE/crispasr.framework"
DEST="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "$DEST"
rm -rf "$DEST/crispasr.framework"
# -a keeps the macOS framework's Versions/Current symlinks intact.
cp -a "$SRC" "$DEST/"

# Keep only the architectures being built, so an arm64 iPhone build does not
# carry a simulator slice and the App Store does not reject the binary.
BIN="$DEST/crispasr.framework/crispasr"
if [ "${PLATFORM_NAME}" = macosx ]; then
  BIN="$DEST/crispasr.framework/Versions/A/crispasr"
fi
if [ -n "${ARCHS:-}" ] && lipo -info "$BIN" | grep -q 'Architectures in the fat file'; then
  KEEP=()
  for arch in ${ARCHS}; do
    lipo "$BIN" -verify_arch "$arch" 2>/dev/null && KEEP+=(-extract "$arch")
  done
  if [ ${#KEEP[@]} -gt 0 ]; then
    lipo "$BIN" "${KEEP[@]}" -output "$BIN.thin" && mv "$BIN.thin" "$BIN"
  fi
fi

# Sign when Xcode is signing; an unsigned archive is signed at export, and
# the macOS release signs nested frameworks itself (macos-release.yml).
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
    ${OTHER_CODE_SIGN_FLAGS:-} --preserve-metadata=identifier,entitlements \
    "$DEST/crispasr.framework"
fi
echo "embedded crispasr.framework ($SLICE) in ${FRAMEWORKS_FOLDER_PATH}"
