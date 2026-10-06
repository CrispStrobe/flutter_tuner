#!/usr/bin/env bash
# Put CrispASR's native library where each platform's build picks it up.
#
#   tool/crispasr/build.sh apple     # iOS + macOS: prebuilt xcframework
#   tool/crispasr/build.sh android   # arm64-v8a .so files into jniLibs/
#   tool/crispasr/build.sh linux     # .so files for linux/CMakeLists.txt
#   tool/crispasr/build.sh windows   # .dll files for windows/CMakeLists.txt
#   tool/crispasr/build.sh wasm      # libwhisper.{js,wasm} into web/crispasr/
#
# Nothing this writes is committed (see .gitignore). Without it the app still
# builds and runs: the CrispASR models report themselves unavailable and the
# built-in model works as before.
#
# Why each platform gets what it gets:
#
#   apple    CrispASR's release xcframework is a self-contained dynamic
#            framework that exports the note ABI, so it is downloaded rather
#            than built — the build is 30-60 min and 7-20 GB. Pruned to the
#            three slices this app uses (the zip is 600 MB, mostly dSYMs and
#            tvOS/visionOS). Embedded, never linked: see embed_apple.sh.
#   android  Built, not downloaded: the release .so is 4 KB page-aligned, and
#            Google Play rejects that for apps targeting Android 15+.
#   linux,   Built, not downloaded: the release archives carry the CLI
#   windows  statically linked and no shared library at all.
#   wasm     Built from source plus wasm-piano-notes.patch, which adds the
#            sessionPianoNotes binding the release build lacks. Single-
#            threaded, so the site needs no COOP/COEP headers.
#
# For every source build, the find_package switches keep the library free of
# system dependencies a user may not have: no OpenMP runtime, no BLAS, and no
# pkg-config probes that would link libopus/opencore-amr/fdk-aac/espeak-ng
# from the build machine. None of those is used by the note models.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=tool/crispasr/version.env
source "$HERE/version.env"

WORK="${CRISPASR_WORK:-$ROOT/build/crispasr}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
GENERATOR=()
command -v ninja >/dev/null && GENERATOR=(-G Ninja)

log() { printf '\033[1m[crispasr]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[crispasr] %s\033[0m\n' "$*" >&2; exit 1; }

# A shallow checkout of the pinned release, with ggml. Reused across targets.
checkout() {
  local src="$WORK/src"
  if [ ! -d "$src/.git" ]; then
    log "cloning CrispASR $CRISPASR_REF"
    git clone --quiet --depth 1 --branch "$CRISPASR_REF" \
      https://github.com/CrispStrobe/CrispASR "$src"
    git -C "$src" submodule update --quiet --init --depth 1 ggml
  fi
  SRC="$src"
}

COMMON_FLAGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_SHARED_LIBS=ON
  -DGGML_NATIVE=OFF
  -DGGML_OPENMP=OFF
  -DCRISPASR_BUILD_TESTS=OFF
  -DCRISPASR_BUILD_EXAMPLES=OFF
  -DCRISPASR_BUILD_SERVER=OFF
  -DCRISPASR_OPUS=OFF
  -DCRISPASR_AMR=OFF
  -DCRISPASR_MEL_BLAS=OFF
  -DCRISPASR_WITH_ESPEAK_NG=OFF
  -DCMAKE_DISABLE_FIND_PACKAGE_OpenMP=ON
  -DCMAKE_DISABLE_FIND_PACKAGE_BLAS=ON
  -DCMAKE_DISABLE_FIND_PACKAGE_CBLAS=ON
  -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON
)

# Every shared library the build produced, symlinks resolved, into $1.
collect_libs() {
  local dest="$1" pattern="$2"
  rm -rf "$dest" && mkdir -p "$dest"
  find "$BUILD" -type f -name "$pattern" -print0 | while IFS= read -r -d '' f; do
    cp "$f" "$dest/"
  done
}

build_apple() {
  local dest="$HERE/apple/crispasr.xcframework"
  local zip="$WORK/crispasr-$CRISPASR_REF-xcframework.zip"
  mkdir -p "$WORK"
  if [ ! -f "$zip" ]; then
    log "downloading the $CRISPASR_REF xcframework"
    curl -fL --retry 3 -o "$zip.tmp" \
      "https://github.com/CrispStrobe/CrispASR/releases/download/$CRISPASR_REF/crispasr-$CRISPASR_REF-xcframework.zip"
    mv "$zip.tmp" "$zip"
  fi
  local keep=(ios-arm64 ios-arm64_x86_64-simulator macos-arm64_x86_64)
  local tmp="$WORK/xcf" && rm -rf "$tmp" && mkdir -p "$tmp"
  local patterns=("crispasr.xcframework/Info.plist")
  for slice in "${keep[@]}"; do
    patterns+=("crispasr.xcframework/$slice/crispasr.framework/*")
  done
  unzip -q "$zip" "${patterns[@]}" -d "$tmp"
  # The xcframework's own Info.plist still lists the slices that were left
  # behind; Xcode and `xcodebuild -create-xcframework` both read it, so it
  # has to describe what is actually there.
  python3 - "$tmp/crispasr.xcframework/Info.plist" "${keep[@]}" <<'PY'
import plistlib, sys
path, keep = sys.argv[1], set(sys.argv[2:])
with open(path, 'rb') as f:
    info = plistlib.load(f)
info['AvailableLibraries'] = [
    lib for lib in info['AvailableLibraries']
    if lib['LibraryIdentifier'] in keep
]
for lib in info['AvailableLibraries']:
    lib.pop('DebugSymbolsPath', None)
with open(path, 'wb') as f:
    plistlib.dump(info, f)
PY
  rm -rf "$dest" && mkdir -p "$(dirname "$dest")"
  mv "$tmp/crispasr.xcframework" "$dest"
  log "apple: $(du -sh "$dest" | cut -f1) at ${dest#"$ROOT"/}"
}

build_android() {
  checkout
  local ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
  [ -n "$ndk" ] && [ -d "$ndk" ] || die "set ANDROID_NDK_HOME to an NDK (r27+)"
  BUILD="$WORK/build-android"
  log "configuring android arm64-v8a"
  cmake -S "$SRC" -B "$BUILD" "${GENERATOR[@]}" "${COMMON_FLAGS[@]}" \
    -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-24 \
    -DANDROID_STL=c++_static \
    -DCRISPASR_MEDIA_NDK=OFF \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,max-page-size=16384"
  cmake --build "$BUILD" --parallel "$JOBS" --target crispasr-lib
  local dest="$ROOT/android/app/src/main/jniLibs/arm64-v8a"
  collect_libs "$dest" '*.so'
  local strip="$ndk/toolchains/llvm/prebuilt/$(ls "$ndk/toolchains/llvm/prebuilt" | head -1)/bin/llvm-strip"
  "$strip" --strip-unneeded "$dest"/*.so
  log "android: $(du -sh "$dest" | cut -f1) at ${dest#"$ROOT"/}"
}

build_linux() {
  checkout
  BUILD="$WORK/build-linux"
  log "configuring linux"
  cmake -S "$SRC" -B "$BUILD" "${GENERATOR[@]}" "${COMMON_FLAGS[@]}" \
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
    -DCMAKE_INSTALL_RPATH='$ORIGIN'
  cmake --build "$BUILD" --parallel "$JOBS" --target crispasr-lib
  local dest="$HERE/linux/lib"
  collect_libs "$dest" '*.so*'
  # Real files under their SONAMEs, so the loader finds each dependency by
  # the name the others ask for.
  ( cd "$dest" && for f in *.so*; do
      soname=$(objdump -p "$f" 2>/dev/null | awk '/SONAME/{print $2}')
      [ -n "$soname" ] && [ "$soname" != "$f" ] && mv -f "$f" "$soname"
    done; [ -f libcrispasr.so ] || ln -sf "$(ls libcrispasr.so.* | head -1)" libcrispasr.so )
  strip --strip-unneeded "$dest"/*.so.* 2>/dev/null || true
  log "linux: $(du -sh "$dest" | cut -f1) at ${dest#"$ROOT"/}"
}

build_windows() {
  checkout
  BUILD="$WORK/build-windows"
  # POSIX popen/pclose in a speech backend (zonos_tts.cpp at v0.8.41) do not
  # exist under MSVC. CrisperWeaver carries the same shim; upstream fix
  # pending.
  grep -rl --include='*.cpp' -E '\bpopen\b' "$SRC/src" | while read -r f; do
    grep -q '#define popen _popen' "$f" || {
      printf '#ifdef _MSC_VER\n#define popen _popen\n#define pclose _pclose\n#endif\n' | cat - "$f" > "$f.tmp"
      mv "$f.tmp" "$f"
    }
  done
  log "configuring windows"
  # GGML_NATIVE=OFF stops the runner's AVX-512 being baked in; AVX2+FMA
  # covers every x86-64 desktop of the last decade (CrisperWeaver #19).
  cmake -S "$SRC" -B "$BUILD" "${COMMON_FLAGS[@]}" \
    -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_AVX512=OFF
  cmake --build "$BUILD" --config Release --parallel "$JOBS" --target crispasr-lib
  collect_libs "$HERE/windows/bin" '*.dll'
  log "windows: $(du -sh "$HERE/windows/bin" | cut -f1) at tool/crispasr/windows/bin"
}

build_wasm() {
  checkout
  command -v emcc >/dev/null || die "emcc not found: source emsdk_env.sh first"
  if ! grep -q sessionPianoNotes "$SRC/bindings/javascript/emscripten.cpp"; then
    git -C "$SRC" apply "$HERE/wasm-piano-notes.patch"
  fi
  # Upstream's own script, so the compiler flags (SIMD128 and the rest)
  # are exactly those of CrispASR's published wasm build.
  log "building wasm (single-threaded)"
  ( cd "$SRC" && ./build-wasm.sh --single-thread -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON )
  BUILD="$SRC/build-wasm"
  local dest="$ROOT/web/crispasr"
  for f in libwhisper.js libwhisper.wasm; do
    cp "$(find "$BUILD" -name "$f" -type f | head -1)" "$dest/$f"
  done
  log "wasm: $(du -ch "$dest"/libwhisper.* | tail -1 | cut -f1) at web/crispasr/"
}

case "${1:-}" in
  apple) build_apple ;;
  android) build_android ;;
  linux) build_linux ;;
  windows) build_windows ;;
  wasm) build_wasm ;;
  *) die "usage: $0 apple|android|linux|windows|wasm" ;;
esac
