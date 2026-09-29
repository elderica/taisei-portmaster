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
SDL_REF=release-3.4.16
# PortMaster-New commit to take the sdl3-sdl2-backend libSDL3.so.0 shim from
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
  apt-get update
  apt-get install -y --no-install-recommends \
    build-essential git cmake ninja-build pkg-config gettext patchelf \
    python3 python3-pip python3-dev curl zip ca-certificates
fi
python3 -m pip install --upgrade 'meson>=1.8' backports.zstd

mkdir -p "$WORK"

# SDL3, as a shared library to link against. At runtime it is replaced by the shim.
if [ ! -f "$WORK/sdl3/lib/pkgconfig/sdl3.pc" ]; then
  rm -rf "$WORK/SDL"
  git clone --depth 1 -b $SDL_REF https://github.com/libsdl-org/SDL.git "$WORK/SDL"
  cmake -S "$WORK/SDL" -B "$WORK/SDL/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WORK/sdl3" -DCMAKE_INSTALL_LIBDIR=lib \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_UNIX_CONSOLE_BUILD=ON
  cmake --build "$WORK/SDL/build" -j "$JOBS"
  cmake --install "$WORK/SDL/build"
fi

# Taisei, with everything except SDL3 linked statically
if [ ! -d "$WORK/taisei" ]; then
  git clone --depth 1 -b $TAISEI_REF --recurse-submodules --shallow-submodules \
    https://github.com/taisei-project/taisei.git "$WORK/taisei"
  # GCC 10 (bullseye) does not accept C23 `= {}` initializers on VLAs
  git -C "$WORK/taisei" apply "$ROOT/patches/taisei-gcc10-vla-init.patch"
fi
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
rm -rf "$GAMEDIR/data" "$GAMEDIR/libs.$ARCH" "$GAMEDIR"/taisei.* "$GAMEDIR/licenses"
mkdir -p "$GAMEDIR/libs.$ARCH" "$GAMEDIR/licenses"
cp "$WORK/install/taisei" "$GAMEDIR/taisei.$ARCH"
patchelf --remove-rpath "$GAMEDIR/taisei.$ARCH"
cp -r "$WORK/install/data" "$GAMEDIR/data"

curl -fsSL -o "$GAMEDIR/libs.$ARCH/libSDL3.so.0" "$PM_RAW/libs.aarch64/libSDL3.so.0"

S=$WORK/taisei/subprojects
cp "$WORK/taisei/COPYING.txt"         "$GAMEDIR/licenses/LICENSE.taisei.txt"
curl -fsSL -o "$GAMEDIR/licenses/LICENSE.SDL3.txt" "$PM_RAW/licenses/SDL3-sdl2backend-LICENSE.txt"
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
