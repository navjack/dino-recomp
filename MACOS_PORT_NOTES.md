# macOS port notes — Dinosaur Planet: Recompiled

Builds and runs on Apple Silicon; launcher, native file dialog, and Metal rendering all work.
Installed as `DinosaurPlanet.app`. This port needed the most work — two of the fixes below are
things upstream simply never wrote for macOS.

## ROM preparation

Requires the **unmodified December 2000 prototype** (MD5 `49f7bb346ade39d1915c22e090ffd748`),
patched before use. The launcher explicitly rejects `rom_crack.z64`.

```bash
cp <prototype> baserom.z64
python3 ./lib/dino-recomp-decomp-bridge/dinosaur-planet/tools/recomp_rom_patcher.py \
        -o baserom.patched.z64 baserom.z64
```

Then generate the C sources with the project's **own** vendored recompiler:

```bash
cmake -S lib/N64Recomp -B lib/N64Recomp/build -DCMAKE_BUILD_TYPE=Release
cmake --build lib/N64Recomp/build -j8
cp lib/N64Recomp/build/N64Recomp lib/N64Recomp/build/RSPRecomp .
./N64Recomp dino.toml && ./RSPRecomp aspMain.toml
```

## Changes made

**`CMakeLists.txt`** — `add_compile_options("SHELL:-include stdlib.h")`, `enable_language(OBJCXX)`,
and `src/runtime/support_apple.mm` appended to `SOURCES_EXTRA` on Apple (the existing globs only
collect `*.cpp`).

**`src/runtime/support_apple.mm`** — **written from scratch.** `src/runtime/support.hpp` declares
four Apple functions and says they are "Implemented in support_apple.mm", but that file does not
exist upstream, so the macOS link failed on `dispatch_on_ui_thread` and
`get_bundle_resource_directory`. Implements all four. `dispatch_on_ui_thread` runs inline when
already on the main thread and otherwise `dispatch_async`es to the main queue — AppKit requires
file dialogs and alerts on the main thread, and callers reach it from the game/UI threads.

**`src/runtime/gfx.cpp`** — replaced the `#else static_assert(false && "Unimplemented")` platform
gate with an Apple branch returning `{NSWindow*, CAMetalLayer*}`, plus `SDL_WINDOW_METAL`.

**`src/debug_ui/backend.cpp`** — `set_render_hooks()` no longer registers the debug overlay on
Apple. That backend only implements the D3D12 and Vulkan ImGui paths, and `get_graphics_api()`
returns Vulkan on Apple as an acknowledged placeholder (its own comment: *"TODO: Add MoltenVK
option for Mac?"*). The result was `ImGui_ImplVulkan_Init` running against a Metal device with no
Vulkan loader, so `vkGetInstanceProcAddr` was null and the Gfx Thread jumped to address `0x0`
during `RT64::Application::setup`. Also added a null guard to `begin()`, which dereferenced the
context and is reachable from the mod-facing recomp API.

**`src/config/config.cpp`** — added the missing `__APPLE__` branch to `get_app_folder_path()`.
It had branches for `_WIN32` and `__linux__` only, so it returned an **empty** path, making
librecomp's `create_directories(config_path / "mods")` a *relative* path. That silently worked
from a writable build directory but aborted from `/Applications`, where the working directory is
`/` — it tried to create `/mods` and the throwing overload killed the process before the window
opened. Now returns `~/Library/Application Support/DinoPlanetRecompiled`.

**`tools/make_macos_app.sh`** (new) — assets and controller DB into `Contents/Resources`
(`get_program_path()` returns the Resources dir on Apple via the `support_apple.mm`
implementation), dylibs vendored, Homebrew rpaths stripped, ad-hoc signed.

## Build

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 .
cmake --build build -j8
./tools/make_macos_app.sh
```

## Notes

The ROM is **not** bundled — pick `baserom.patched.z64` via the launcher's "Select ROM".

## Known issues

Crashes on quit in the shared plume Metal teardown path; gameplay is unaffected.

## Shared background (applies to every rt64-based port here)

**hlslpp `labs`** — rt64 forces `HLSLPP_SCALAR` on Apple Silicon and its `scalar.h` calls
`labs()` without including `<stdlib.h>`. Fix: `add_compile_options("SHELL:-include stdlib.h")`.
The `SHELL:` prefix matters — without it CMake de-duplicates the repeated `-include` token and
collapses it with any other `-include`, turning the following header into a bare input file.

**Window handle** — ultramodern's `WindowHandle` is platform-variant. On Apple it is
`{NSWindow*, CAMetalLayer*}`, and plume's Metal backend casts `.view` straight to
`CA::MetalLayer*`. Passing the `SDL_Window*` instead crashes in `objc_msgSend` the moment the
render thread starts. Correct form:

```cpp
flags |= SDL_WINDOW_METAL;
SDL_MetalView metal_view = SDL_Metal_CreateView(window);
return ultramodern::renderer::WindowHandle{ wmInfo.info.cocoa.window,
                                            SDL_Metal_GetLayer(metal_view) };
```

**Bundling rules learned the hard way**
- `codesign` treats *any* non-Mach-O file in `Contents/MacOS` as unsigned nested code and
  refuses to seal the bundle. Data files belong in `Contents/Resources`.
- Strip absolute Homebrew `LC_RPATH` entries. These builds bake `/opt/homebrew/lib` in as the
  **first** rpath; dyld searches rpaths in order, so `@rpath/libSDL2-2.0.0.dylib` resolves to
  Homebrew and the vendored copies are never loaded. `otool -L` still looks correct because it
  only shows the `@rpath` load commands — verify with
  `otool -l <bin> | grep -A2 LC_RPATH` instead.
- sdl2-compat `dlopen`s `libSDL3.dylib` at load time. Dependency walkers (including CMake's
  `fixup_bundle`) never see it, so it must be vendored explicitly or the app aborts in
  `dllinit` with "Failed loading SDL3 library" before `main()` runs.
- Test the **installed** copy from `/Applications`, not the build directory. A writable build
  dir hides any bug involving a read-only or relative config path.

**N64Recomp is per-project** — every project pins its own recompiler under `lib/N64Recomp` or
`lib/N64ModernRuntime/N64Recomp`. Build *that* copy and run it from the repo root (the build
shells out to a literal `./N64Recomp <game>.toml`). Reusing another project's binary appears to
work and emits a plausible file count, but the generated code targets a different runtime API
and fails much later with errors like `no member named 'nullopt' in namespace 'std'` inside
`recomp_overlays.inl`. Regenerate after `rm -rf RecompiledFuncs RecompiledPatches`.

**Known upstream issue (not fixed)** — rt64/plume's Metal backend over-releases metal-cpp
objects. It shows up as a crash on quit in the "RT64 Workload" thread inside `objc_release` /
`objc_autoreleasePoolPop`, with memory-poison values (`0xa1a1a1a1`, `0xa3a3a3a3a3a3a3a3`) in the
registers. Adding a per-iteration `NS::AutoreleasePool` to rt64's render thread loop makes it
**worse** — the crash moves to ~0.5s after launch and macOS reports "API MISUSE: Over-release of
an object", proving the missing pool was masking a genuine double-release rather than causing
it. Do not re-attempt that fix; the real bug is unbalanced retain/release inside plume.
