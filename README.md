# Taisei Project for PortMaster

[PortMaster](https://portmaster.games/) packaging of [Taisei Project](https://github.com/taisei-project/taisei) v1.4.6 for aarch64 Linux handhelds.

- Ready to run: all game data is open source and included.
- OpenGL ES 3.0 renderer.
- SDL3 is provided at runtime by the [sdl3-sdl2-backend](https://github.com/bmdhacks/SDL/tree/sdl2-backend) `libSDL3.so.0` shim, so the game uses the device's own SDL2. It is built from commit `6057d79` with railroadrampage's `sdl3-sdl2-backend-fixes.patch` from PortMaster-New, the same way as that port.
- Built in `debian:bullseye` (glibc 2.31). Every dependency except SDL3 is linked statically.

## Download

Get `taisei.zip` from the Releases page and extract it into your `ports` folder.

## Build

```bash
docker run --rm -v "$PWD:/src" -w /src arm64v8/debian:bullseye ./build.sh
```

The result is `dist/taisei.zip`. GitHub Actions runs the same command on an arm64 runner and attaches the zip to a release when a `v*` tag is pushed.

`patches/taisei-gcc10-vla-init.patch` replaces four C23 `= {}` initializers on variable-length arrays with `memset`, which GCC 10 requires.

## Layout

`ports/taisei/` follows the PortMaster-New port layout and can be copied into a PortMaster-New checkout after running `build.sh`.
