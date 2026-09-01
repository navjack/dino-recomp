#!/usr/bin/env bash
# Package the macOS build into DinosaurPlanet.app.
#
# get_program_path() returns the bundle Resources directory on Apple (see the
# get_bundle_resource_directory() implementation in src/runtime/support_apple.mm), and
# get_asset_path() appends "assets", so the asset tree and the controller DB go there.
#
# The ROM is NOT bundled: pick it in the launcher's "Select ROM" entry. It must be the
# PATCHED December 2000 prototype (baserom.patched.z64, produced by the decomp's
# recomp_rom_patcher.py) -- the launcher rejects rom_crack.z64 by design.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${1:-$ROOT/build}"
OUTDIR="${2:-$ROOT}"
APP="$OUTDIR/DinosaurPlanet.app"

[ -x "$BUILD/DinosaurPlanetRecompiled" ] || { echo "error: DinosaurPlanetRecompiled not built" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BUILD/DinosaurPlanetRecompiled" "$APP/Contents/MacOS/DinosaurPlanet"
cp -R "$ROOT/assets" "$APP/Contents/Resources/assets"
cp "$ROOT/recompcontrollerdb.txt" "$APP/Contents/Resources/"

if [ -f "$ROOT/icons/512.png" ]; then
    ICONSET="$(mktemp -d)/Dino.iconset"; mkdir -p "$ICONSET"
    for sz in 16 32 128 256 512; do
        sips -z $sz $sz "$ROOT/icons/512.png" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
        sips -z $((sz*2)) $((sz*2)) "$ROOT/icons/512.png" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Dino.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Dinosaur Planet</string>
    <key>CFBundleDisplayName</key><string>Dinosaur Planet: Recompiled</string>
    <key>CFBundleExecutable</key><string>DinosaurPlanet</string>
    <key>CFBundleIdentifier</key><string>com.dinosaurplanetrecomp.DinosaurPlanet</string>
    <key>CFBundleIconFile</key><string>Dino</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
</dict>
</plist>
PLIST

FW="$APP/Contents/Frameworks"
cp "$(brew --prefix sdl2-compat)/lib/libSDL2-2.0.0.dylib" "$FW/"
cp "$(brew --prefix sdl3)/lib/libSDL3.0.dylib"            "$FW/libSDL3.dylib"
cp "$(brew --prefix freetype)/lib/libfreetype.6.dylib"    "$FW/"
cp "$(brew --prefix libpng)/lib/libpng16.16.dylib"        "$FW/"
chmod u+w "$FW"/*.dylib

install_name_tool -id @rpath/libSDL2-2.0.0.dylib     "$FW/libSDL2-2.0.0.dylib"
install_name_tool -id @rpath/libfreetype.6.dylib     "$FW/libfreetype.6.dylib"
install_name_tool -id @loader_path/libSDL3.dylib     "$FW/libSDL3.dylib"
install_name_tool -id @loader_path/libpng16.16.dylib "$FW/libpng16.16.dylib"
FT_PNG="$(otool -L "$FW/libfreetype.6.dylib" | awk '/libpng16\.16\.dylib/ {print $1; exit}')"
[ -n "$FT_PNG" ] && install_name_tool -change "$FT_PNG" @loader_path/libpng16.16.dylib "$FW/libfreetype.6.dylib"

BIN="$APP/Contents/MacOS/DinosaurPlanet"
BIN_SDL="$(otool -L "$BIN" | awk '/libSDL2-2\.0\.0\.dylib/ {print $1; exit}')"
[ -n "$BIN_SDL" ] && install_name_tool -change "$BIN_SDL" @rpath/libSDL2-2.0.0.dylib "$BIN"
BIN_FT="$(otool -L "$BIN" | awk '/libfreetype\.6\.dylib/ {print $1; exit}')"
[ -n "$BIN_FT" ] && install_name_tool -change "$BIN_FT" @rpath/libfreetype.6.dylib "$BIN"
install_name_tool -add_rpath @executable_path/../Frameworks "$BIN"

# The build bakes /opt/homebrew/lib in as the FIRST LC_RPATH. dyld searches rpaths in order,
# so @rpath/libSDL2-2.0.0.dylib resolved to Homebrew and the vendored copies were never used
# -- the bundle looked correct to `otool -L` (which only shows the @rpath load commands) while
# actually depending on /opt/homebrew. Drop every absolute Homebrew rpath.
while otool -l "$BIN" | grep -A2 LC_RPATH | grep -q "path $(brew --prefix)"; do
    RP="$(otool -l "$BIN" | grep -A2 LC_RPATH | awk -v p="$(brew --prefix)" '$1=="path" && index($2,p)==1 {print $2; exit}')"
    [ -n "$RP" ] || break
    install_name_tool -delete_rpath "$RP" "$BIN"
done

codesign --force --sign - "$FW"/*.dylib
codesign --force --sign - "$BIN"
codesign --force --sign - "$APP"

if otool -L "$BIN" "$FW"/*.dylib | grep -q "$(brew --prefix)"; then
    echo "error: bundle still references Homebrew paths" >&2; exit 1
fi
# Also check LC_RPATH: an @rpath load command is only as good as the search paths.
if otool -l "$BIN" | grep -A2 LC_RPATH | grep -q "path $(brew --prefix)"; then
    echo "error: bundle still has a Homebrew LC_RPATH; @rpath would resolve outside the app" >&2; exit 1
fi
echo "built $APP"
