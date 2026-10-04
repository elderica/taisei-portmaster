#!/bin/bash
# Build the Taisei PortMaster package for aarch64.
#
# Intended to run inside an arm64 debian:bullseye container (glibc 2.31), so the
# binary also runs on CFWs with an old glibc:
#
#   docker run --rm -v "$PWD:/src" -w /src arm64v8/debian:bullseye ./build.sh
#
# Output: ports/taisei/taisei/ is filled in, and dist/taisei.zip is created.

set -euo pipefail

TAISEI_REF=v1.4.6
# sdl3-sdl2-backend: SDL3 API on top of the device's own SDL2 (same commit as railroadrampage)
SHIM_REF=6057d79ba
# SPIRV-Cross for the shim's GLES GPU backend; same version as Taisei's SPIRV-Cross.wrap
SPIRV_CROSS_REF=vulkan-sdk-1.3.296.0
# PortMaster-New commit to take railroadrampage's shim fixes patch from
PM_COMMIT=12e229443e509d193456708a6dc43e4fc0104cd3
PM_RAW=https://raw.githubusercontent.com/PortsMaster/PortMaster-New/$PM_COMMIT/ports/railroadrampage/railroadrampage

ROOT=$(cd "$(dirname "$0")" && pwd)
WORK=$ROOT/work
PORT=$ROOT/ports/taisei
GAMEDIR=$PORT/taisei
ARCH=$(uname -m)
JOBS=$(nproc)

if [ "$(id -u)" = 0 ] && command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  # bullseye is EOL and its security pool is gone from deb.debian.org; use a fixed snapshot
  if grep -q bullseye /etc/os-release; then
    SNAP=http://snapshot.debian.org/archive
    cat > /etc/apt/sources.list <<EOF
deb $SNAP/debian/20260801T000000Z bullseye main
deb $SNAP/debian-security/20260801T000000Z bullseye-security main
EOF
    rm -f /etc/apt/sources.list.d/*
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99snapshot
  fi
  apt-get update
  apt-get install -y --no-install-recommends \
    build-essential git cmake ninja-build pkg-config gettext patchelf \
    python3 python3-pip python3-dev curl zip ca-certificates
fi
python3 -m pip install --upgrade 'meson>=1.8' backports.zstd

mkdir -p "$WORK"

# Taisei source
if [ ! -d "$WORK/taisei" ]; then
  git clone --depth 1 -b $TAISEI_REF --recurse-submodules --shallow-submodules \
    https://github.com/taisei-project/taisei.git "$WORK/taisei"
  # GCC 10 (bullseye) does not accept C23 `= {}` initializers on VLAs
  git -C "$WORK/taisei" apply "$ROOT/patches/taisei-gcc10-vla-init.patch"
  # Keep one GL window; the SDL3 shim loses the context when a window is destroyed
  git -C "$WORK/taisei" apply "$ROOT/patches/taisei-gles30-single-window.patch"
fi

# SDL3 shim, built the same way as railroadrampage
if [ ! -f "$WORK/sdl3/lib/pkgconfig/sdl3.pc" ]; then
  rm -rf "$WORK/shim" "$WORK/SPIRV-Cross"
  git clone --depth 1 -b $SPIRV_CROSS_REF https://github.com/KhronosGroup/SPIRV-Cross.git "$WORK/SPIRV-Cross"
  git clone -b sdl2-backend https://github.com/bmdhacks/SDL.git "$WORK/shim"
  git -C "$WORK/shim" checkout $SHIM_REF
  curl -fsSL "$PM_RAW/patches/sdl3-sdl2-backend-fixes.patch" | git -C "$WORK/shim" apply
  # Make SDL2 convert audio itself; the shim ignores the format SDL2 actually opened
  git -C "$WORK/shim" apply "$ROOT/patches/sdl3-shim-audio-keep-format.patch"
  cmake -S "$WORK/shim" -B "$WORK/shim/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WORK/sdl3" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_C_FLAGS="-march=armv8-a" \
    -DSDL_SDL2_BACKEND=ON \
    -DSDL_SPIRV_CROSS_DIR="$WORK/SPIRV-Cross" \
    -DSDL_X11=OFF -DSDL_WAYLAND=OFF -DSDL_KMSDRM=OFF \
    -DSDL_PIPEWIRE=OFF -DSDL_PULSEAUDIO=OFF -DSDL_ALSA=OFF \
    -DSDL_SNDIO=OFF -DSDL_OSS=OFF -DSDL_JACK=OFF \
    -DSDL_OFFSCREEN=OFF -DSDL_DUMMYVIDEO=OFF \
    -DSDL_DUMMYAUDIO=OFF -DSDL_DISKAUDIO=OFF \
    -DSDL_VULKAN=OFF -DSDL_GPU=ON -DSDL_RENDER_GPU=ON \
    -DSDL_UNIX_CONSOLE_BUILD=ON \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
  cmake --build "$WORK/shim/build" -j "$JOBS"
  cmake --install "$WORK/shim/build"
fi

# Taisei, with everything except SDL3 linked statically
rm -rf "$WORK/build" "$WORK/install"
PKG_CONFIG_PATH="$WORK/sdl3/lib/pkgconfig" meson setup "$WORK/build" "$WORK/taisei" \
  --buildtype=release -Dstrip=true --prefix="$WORK/install" --default-library=static \
  --force-fallback-for=freetype2,libpng,libwebp,libwebpdecoder,libzstd,cglm,libunibreak,zlib,opusfile \
  -Dinstall_relocatable=enabled -Dinstall_freedesktop=disabled -Ddocs=disabled \
  -Dr_default=gles30 -Dr_gl33=disabled -Dr_sdlgpu=disabled \
  -Dshader_transpiler=enabled -Dforce_vendored_shader_tools=true \
  -Duse_libcrypto=false -Dgamemode=disabled
meson install -C "$WORK/build"

# Assemble the port directory
rm -rf "$GAMEDIR/data" "$GAMEDIR"/data-part*.tar.gz "$GAMEDIR/libs.$ARCH" "$GAMEDIR"/taisei.* "$GAMEDIR/licenses"
mkdir -p "$GAMEDIR/libs.$ARCH" "$GAMEDIR/licenses"
cp "$WORK/install/taisei" "$GAMEDIR/taisei.$ARCH"
patchelf --remove-rpath "$GAMEDIR/taisei.$ARCH"

# Game data as data-partN.tar.gz (GitHub rejects files over 100 MB); the launcher extracts them.
# The main pack is shipped as loose files from its source pkgdir: Taisei reads loose and .zst
# files from data/ directly, like a -Dpackage_data=disabled build (which would drop the l10n pack).
rm -rf "$WORK/datastage"
mkdir -p "$WORK/datastage/data"
cp -r "$WORK/taisei/resources/00-taisei.pkgdir/." "$WORK/datastage/data/"
find "$WORK/datastage/data" \( -name meson.build -o -name .nocompress \) -delete
cp "$WORK/install/data/10-l10n.zip" "$WORK/install/data/gamecontrollerdb.txt" "$WORK/datastage/data/"
python3 - "$WORK/datastage" "$GAMEDIR" <<'EOF'
import os, sys, tarfile
stage, out = sys.argv[1:]
files = sorted(os.path.relpath(os.path.join(d, f), stage)
               for d, _, fs in os.walk(os.path.join(stage, 'data')) for f in fs)
parts, size = [[]], 0
for f in files:
    n = os.path.getsize(os.path.join(stage, f))
    if parts[-1] and size + n > 80 << 20:
        parts.append([])
        size = 0
    parts[-1].append(f)
    size += n
for i, part in enumerate(parts, 1):
    with tarfile.open(os.path.join(out, f'data-part{i}.tar.gz'), 'w:gz') as tar:
        for f in part:
            tar.add(os.path.join(stage, f), arcname=f)
EOF

cp -L "$WORK/sdl3/lib/libSDL3.so.0" "$GAMEDIR/libs.$ARCH/libSDL3.so.0"
strip "$GAMEDIR/libs.$ARCH/libSDL3.so.0"

S=$WORK/taisei/subprojects
cp "$WORK/taisei/COPYING.txt"         "$GAMEDIR/licenses/LICENSE.taisei.txt"
cp "$WORK/shim/LICENSE.txt"           "$GAMEDIR/licenses/LICENSE.SDL3.txt"
cp "$S/SPIRV-Cross/LICENSE"           "$GAMEDIR/licenses/LICENSE.SPIRV-Cross.txt"
cp "$S/basis_universal/LICENSE"       "$GAMEDIR/licenses/LICENSE.basis_universal.txt"
cp "$S/cglm/LICENSE"                  "$GAMEDIR/licenses/LICENSE.cglm.txt"
cp "$S/freetype/docs/FTL.TXT"         "$GAMEDIR/licenses/LICENSE.freetype.txt"
cp "$S/glslang/LICENSE.txt"           "$GAMEDIR/licenses/LICENSE.glslang.txt"
cp "$S/koishi/COPYING"                "$GAMEDIR/licenses/LICENSE.koishi.txt"
cp "$S/libpng/LICENSE"                "$GAMEDIR/licenses/LICENSE.libpng.txt"
cp "$S/libunibreak/LICENCE"           "$GAMEDIR/licenses/LICENSE.libunibreak.txt"
cp "$S/libwebp/COPYING"               "$GAMEDIR/licenses/LICENSE.libwebp.txt"
cp "$S/libzstd/LICENSE"               "$GAMEDIR/licenses/LICENSE.zstd.txt"
cp "$S/mimalloc/LICENSE"              "$GAMEDIR/licenses/LICENSE.mimalloc.txt"
cp "$S/ogg/COPYING"                   "$GAMEDIR/licenses/LICENSE.ogg.txt"
cp "$S/opus/COPYING"                  "$GAMEDIR/licenses/LICENSE.opus.txt"
cp "$S/opusfile/COPYING"              "$GAMEDIR/licenses/LICENSE.opusfile.txt"
cp "$S/shaderc/LICENSE"               "$GAMEDIR/licenses/LICENSE.shaderc.txt"
cp "$S/zlib/LICENSE"                  "$GAMEDIR/licenses/LICENSE.zlib.txt"
echo "glad-generated OpenGL loader: SPDX-License-Identifier: (WTFPL OR CC0-1.0) AND Apache-2.0" \
  > "$GAMEDIR/licenses/LICENSE.glad.txt"

# Zip in the same layout as PortMaster's build_release.py
rm -rf "$WORK/zip" "$ROOT/dist"
mkdir -p "$WORK/zip" "$ROOT/dist"
cp -r "$GAMEDIR" "$WORK/zip/taisei"
cp "$PORT/Taisei Project.sh" "$WORK/zip/"
cp "$PORT/port.json" "$PORT/gameinfo.xml" "$PORT/screenshot.png" "$WORK/zip/taisei/"
cp "$PORT/README.md" "$WORK/zip/taisei/taisei.md"
(cd "$WORK/zip" && zip -9 -r "$ROOT/dist/taisei.zip" "Taisei Project.sh" taisei)

echo "Done: $ROOT/dist/taisei.zip"
