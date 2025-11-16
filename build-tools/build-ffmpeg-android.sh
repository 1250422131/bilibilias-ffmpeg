#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: build-ffmpeg-android.sh [--abi <abi>]... [options]

If no --abi flag is provided, all supported ABIs (arm64-v8a, armeabi-v7a, x86_64) are built.

Optional overrides (env vars also respected):
  --ffmpeg-tag <tag>       FFmpeg git tag/commit (default: ${FFMPEG_TAG:-n8.0})
  --ndk-version <ver>      Android NDK version (default: ${NDK_VERSION:-r27})
  --min-api-level <lvl>    Android min API level (default: ${MIN_API_LEVEL:-26})
  --internal-version <ver> Internal release marker written to as-ffmpeg-version (default: ${INTERNAL_VERSION:-1.0.0})
  --jobs <n>               Parallel make jobs (default: auto)

Environment toggles:
  SKIP_DEP_INSTALL=1       Skip apt-based dependency installation attempt

Examples:
  # Build all ABIs with defaults
  ./build-tools/build-ffmpeg-android.sh

  # Build a subset of ABIs with overrides
  ./build-tools/build-ffmpeg-android.sh --abi arm64-v8a --abi x86_64 \
    --ffmpeg-tag n8.0 --ndk-version r27 --min-api-level 26
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DEFAULT_ABIS=(arm64-v8a armeabi-v7a x86_64)
REQUESTED_ABIS=()
FFMPEG_TAG="${FFMPEG_TAG:-n8.0}"
NDK_VERSION="${NDK_VERSION:-r27}"
MIN_API_LEVEL="${MIN_API_LEVEL:-26}"
INTERNAL_VERSION="${INTERNAL_VERSION:-1.0.0}"
JOBS="${JOBS:-}"
FFMPEG_DIR=""

on_error() {
  local exit_code=$?
  local line="$1"
  echo "Build failed on line ${line} with exit code ${exit_code}" >&2
  local config_log
  if [[ -n "$FFMPEG_DIR" ]]; then
    config_log="$FFMPEG_DIR/ffbuild/config.log"
  fi
  if [[ -n "${config_log:-}" && -f "$config_log" ]]; then
    echo "=== Tail of ffbuild/config.log ===" >&2
    tail -200 "$config_log" >&2
  fi
  exit "$exit_code"
}

trap 'on_error $LINENO' ERR

while [[ $# -gt 0 ]]; do
  case "$1" in
    --abi)
      REQUESTED_ABIS+=("$2")
      shift 2
      ;;
    --ffmpeg-tag)
      FFMPEG_TAG="$2"
      shift 2
      ;;
    --ndk-version)
      NDK_VERSION="$2"
      shift 2
      ;;
    --min-api-level)
      MIN_API_LEVEL="$2"
      shift 2
      ;;
    --jobs)
      JOBS="$2"
      shift 2
      ;;
    --internal-version)
      INTERNAL_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$JOBS" ]]; then
  if command -v nproc >/dev/null 2>&1; then
    JOBS="$(nproc)"
  else
    JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
  fi
fi

NDK_ZIP="android-ndk-${NDK_VERSION}-linux.zip"
NDK_DIR="$ROOT_DIR/android-ndk-${NDK_VERSION}"
FFMPEG_DIR="$ROOT_DIR/ffmpeg-src"
DEPS_DIR="$ROOT_DIR/deps"
BIN_DIR="$ROOT_DIR/bin"
MESON_CROSS_DIR="$ROOT_DIR/meson-cross"
PKG_CONFIG_FAKE="$BIN_DIR/pkg-config-fake"
DAV1D_VERSION="1.2.1"
FFMPEG_STAGE_DIR="$ROOT_DIR/ffmpeg"
REFERENCE_INCLUDE_DIR=""
declare -a BUILD_ABIS=()

if [[ ${#REQUESTED_ABIS[@]} -eq 0 ]]; then
  BUILD_ABIS=("${DEFAULT_ABIS[@]}")
else
  BUILD_ABIS=("${REQUESTED_ABIS[@]}")
fi

mkdir -p "$DEPS_DIR" "$BIN_DIR" "$MESON_CROSS_DIR"
rm -rf "$FFMPEG_STAGE_DIR"
mkdir -p "$FFMPEG_STAGE_DIR"

install_dependencies() {
  if [[ "${SKIP_DEP_INSTALL:-0}" == "1" ]]; then
    echo "Skipping dependency installation as requested."
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    sudo dpkg --add-architecture i386 || true
    sudo apt-get update
    sudo apt-get install -y \
      git wget unzip build-essential pkg-config yasm nasm binutils \
      libc6:i386 libstdc++6:i386 lib32z1 gcc-multilib g++-multilib \
      ninja-build meson python3-pip
  else
    echo "apt-get not available; ensure required build dependencies are installed." >&2
  fi
}

install_dependencies

ensure_ndk() {
  if [[ -d "$NDK_DIR" ]]; then
    echo "Using existing NDK at $NDK_DIR"
    return
  fi
  echo "Downloading Android NDK ${NDK_VERSION}..."
  wget -q "https://dl.google.com/android/repository/${NDK_ZIP}"
  unzip -q -o "$NDK_ZIP"
  rm -f "$NDK_ZIP"
}

ensure_ffmpeg() {
  if [[ ! -d "$FFMPEG_DIR/.git" ]]; then
    git clone https://github.com/FFmpeg/FFmpeg "$FFMPEG_DIR"
  fi
  pushd "$FFMPEG_DIR" >/dev/null
  git fetch --tags
  git checkout "$FFMPEG_TAG"
  git rev-parse --short HEAD
  popd >/dev/null
}

ensure_pkg_config_fake() {
  cat > "$PKG_CONFIG_FAKE" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$PKG_CONFIG_FAKE"
}

set_paths_for_abi() {
  local abi="$1"
  ANDROID_LIBS_DIR="$ROOT_DIR/android-libs/$abi"
  ANDROID_BUILD_DIR="$ROOT_DIR/android-build/$abi"
  MESON_CROSS_FILE="$MESON_CROSS_DIR/android-${abi}.ini"
  DAV1D_PREFIX="$ANDROID_LIBS_DIR"
}

prepare_dirs_for_abi() {
  mkdir -p "$ANDROID_LIBS_DIR"
  rm -rf "$ANDROID_BUILD_DIR"
  mkdir -p "$ANDROID_BUILD_DIR"
}

setup_toolchain_env() {
  local abi="$1"
  local toolchain="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"
  case "$abi" in
    arm64-v8a)
      ARCH=arm64
      CPU=armv8-a
      TARGET_HOST=aarch64-linux-android
      CROSS_PREFIX="$toolchain/bin/aarch64-linux-android-"
      CC="$toolchain/bin/aarch64-linux-android${MIN_API_LEVEL}-clang"
      CXX="$toolchain/bin/aarch64-linux-android${MIN_API_LEVEL}-clang++"
      MESON_CPU_FAMILY=aarch64
      MESON_CPU=armv8-a
      ;;
    armeabi-v7a)
      ARCH=arm
      CPU=armv7-a
      TARGET_HOST=armv7a-linux-androideabi
      CROSS_PREFIX="$toolchain/bin/arm-linux-androideabi-"
      CC="$toolchain/bin/armv7a-linux-androideabi${MIN_API_LEVEL}-clang"
      CXX="$toolchain/bin/armv7a-linux-androideabi${MIN_API_LEVEL}-clang++"
      MESON_CPU_FAMILY=arm
      MESON_CPU=armv7-a
      ;;
    x86_64)
      ARCH=x86_64
      CPU=x86-64
      TARGET_HOST=x86_64-linux-android
      CROSS_PREFIX="$toolchain/bin/x86_64-linux-android-"
      CC="$toolchain/bin/x86_64-linux-android${MIN_API_LEVEL}-clang"
      CXX="$toolchain/bin/x86_64-linux-android${MIN_API_LEVEL}-clang++"
      MESON_CPU_FAMILY=x86_64
      MESON_CPU=x86-64
      ;;
    *)
      echo "Unsupported ABI: $abi" >&2
      exit 1
      ;;
  esac
  AR="$toolchain/bin/llvm-ar"
  RANLIB="$toolchain/bin/llvm-ranlib"
  STRIP="$toolchain/bin/llvm-strip"
  NM="$toolchain/bin/llvm-nm"
  LD="$toolchain/bin/ld"
  SYSROOT="$toolchain/sysroot"
}

write_meson_cross_file() {
  cat > "$MESON_CROSS_FILE" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkgconfig = '$PKG_CONFIG_FAKE'

[host_machine]
system = 'android'
cpu_family = '$MESON_CPU_FAMILY'
cpu = '$MESON_CPU'
endian = 'little'

[properties]
sys_root = '$SYSROOT'

[built-in options]
c_args = ['-fPIC']
cpp_args = ['-fPIC']
c_link_args = ['-Wl,-z,max-page-size=16384']
cpp_link_args = ['-Wl,-z,max-page-size=16384']
EOF
}

build_dav1d() {
  pushd "$DEPS_DIR" >/dev/null
  if [[ ! -d dav1d ]]; then
    git clone --branch "$DAV1D_VERSION" --depth 1 https://code.videolan.org/videolan/dav1d.git
  fi
  cd dav1d
  rm -rf build
  meson setup build \
    --cross-file "$MESON_CROSS_FILE" \
    --prefix="$DAV1D_PREFIX" \
    --libdir=lib \
    --buildtype=release \
    --default-library=shared
  ninja -C build
  ninja -C build install

  cat > "$DAV1D_PREFIX/lib/pkgconfig/dav1d.pc" <<EOF
prefix=$DAV1D_PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: dav1d
Description: AV1 decoding library
Version: $DAV1D_VERSION
Libs: -L\${libdir} -ldav1d
Libs.private: -ldl -lm
Cflags: -I\${includedir}
EOF
  popd >/dev/null
}

clean_ffmpeg() {
  pushd "$FFMPEG_DIR" >/dev/null
  make distclean || true
  git clean -xdf || true
  popd >/dev/null
}

configure_ffmpeg() {
  local neon_flag=()
  if [[ "$ARCH" == "arm" || "$ARCH" == "arm64" ]]; then
    neon_flag+=("--enable-neon")
  fi
  pushd "$FFMPEG_DIR" >/dev/null
  export PKG_CONFIG="$(command -v pkg-config)"
  export PKG_CONFIG_LIBDIR="$DAV1D_PREFIX/lib/pkgconfig"
  export PKG_CONFIG_PATH="$DAV1D_PREFIX/lib/pkgconfig"

  mkdir -p "$ANDROID_BUILD_DIR"
  ac_cv_func_glob=no ./configure \
    --prefix="$ANDROID_BUILD_DIR" \
    --target-os=android \
    --arch="$ARCH" \
    --cpu="$CPU" \
    --cross-prefix="$CROSS_PREFIX" \
    --cc="$CC" \
    --cxx="$CXX" \
    --ar="$AR" \
    --ranlib="$RANLIB" \
    --strip="$STRIP" \
    --nm="$NM" \
    --pkg-config="$PKG_CONFIG" \
    --sysroot="$SYSROOT" \
    --enable-cross-compile \
    --enable-shared \
    --disable-static \
    --disable-doc \
    --disable-programs \
    --enable-pic \
    --disable-debug \
    --disable-iconv \
    --enable-libdav1d \
    --enable-decoder=libdav1d \
    "${neon_flag[@]}" \
    --extra-cflags="-I$DAV1D_PREFIX/include -fPIC" \
    --extra-ldflags="-L$DAV1D_PREFIX/lib -Wl,-z,max-page-size=16384 -Wl,-rpath-link,$DAV1D_PREFIX/lib"
  popd >/dev/null
}

build_ffmpeg() {
  pushd "$FFMPEG_DIR" >/dev/null
  make -j"$JOBS"
  make install V=1
  popd >/dev/null
}

copy_dav1d_so() {
  mkdir -p "$ANDROID_BUILD_DIR/lib"
  cp -v "$DAV1D_PREFIX/lib"/libdav1d.so* "$ANDROID_BUILD_DIR/lib/" || true
}

verify_build() {
  pushd "$FFMPEG_DIR" >/dev/null
  if grep -q "CONFIG_LIBDAV1D_DECODER 1" config.h && grep -q "CONFIG_LIBDAV1D 1" config.h; then
    echo "libdav1d decoder verified in config.h"
  else
    echo "Warning: libdav1d not detected in config.h" >&2
  fi
  popd >/dev/null

  local so_dir="$ANDROID_BUILD_DIR/lib"
  shopt -s nullglob
  local so_files=("$so_dir"/libav*.so)
  shopt -u nullglob
  if [[ ${#so_files[@]} -eq 0 ]]; then
    echo "No libav*.so files produced in $so_dir" >&2
    exit 1
  fi
  for so in "${so_files[@]}"; do
    echo "Checking undefined iconv symbols in: $so"
    if readelf -Ws "$so" | grep -E "UND.*iconv_"; then
      echo "Error: $so still references iconv_* symbols" >&2
      exit 1
    fi
  done

  echo "=== Built FFmpeg libraries for $ABI ==="
  ls -lh "$so_dir"
  for so in "${so_files[@]}"; do
    echo "--- $so ---"
    readelf -d "$so" | grep NEEDED || true
  done
}

copy_headers() {
  cp -v "$FFMPEG_DIR/config.h" "$ANDROID_BUILD_DIR/config.h"
}

write_abi_version_file() {
  echo "$INTERNAL_VERSION" > "$ANDROID_BUILD_DIR/as-ffmpeg-version"
}

stage_final_outputs() {
  local abi="$1"
  local dest_lib_dir="$FFMPEG_STAGE_DIR/$abi/lib"
  mkdir -p "$dest_lib_dir"
  cp -v "$ANDROID_BUILD_DIR/lib"/*.so "$dest_lib_dir/"

  if [[ -z "$REFERENCE_INCLUDE_DIR" ]]; then
    REFERENCE_INCLUDE_DIR="$ANDROID_BUILD_DIR/include"
    mkdir -p "$FFMPEG_STAGE_DIR/include"
    cp -rv "$REFERENCE_INCLUDE_DIR/." "$FFMPEG_STAGE_DIR/include/"
  fi
}

write_package_version_file() {
  echo "$INTERNAL_VERSION" > "$FFMPEG_STAGE_DIR/as-ffmpeg-version"
}

ensure_ndk
ensure_ffmpeg
ensure_pkg_config_fake

for ABI in "${BUILD_ABIS[@]}"; do
  echo "=== Building ABI: $ABI ==="
  set_paths_for_abi "$ABI"
  prepare_dirs_for_abi
  setup_toolchain_env "$ABI"
  write_meson_cross_file
  build_dav1d
  clean_ffmpeg
  configure_ffmpeg
  build_ffmpeg
  copy_dav1d_so
  verify_build
  copy_headers
  write_abi_version_file
  stage_final_outputs "$ABI"
done

write_package_version_file

echo "All builds completed. Consolidated output: $FFMPEG_STAGE_DIR"
