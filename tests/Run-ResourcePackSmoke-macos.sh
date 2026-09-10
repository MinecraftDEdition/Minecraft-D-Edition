#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$repo/distribution/macos/build"
deps="$build/deps"
native="$build/native"
out="$build/resourcepack-tests"
mkdir -p "$out/MacOS" "$out/Frameworks"
# The platform bridge deliberately finds MoltenVK relative to the executable,
# just as it does inside the shipped app bundle.
cp "$deps/lib/libMoltenVK.dylib" "$out/Frameworks/libMoltenVK.dylib"
ldc2 -i -I"$repo/source" "$repo/tests/resource_packs_smoke.d" -of="$out/packs"
"$out/packs"
ldc2 -i -I"$repo/source" "$repo/tests/texture_animation_smoke.d" \
    "$native/image_stb_bridge.o" -L-lc++ -of="$out/animation"
"$out/animation"
ldc2 -i --d-version=CORRECT_ABI -I"$repo/source" -J"$repo/shaders" \
    "$repo/tests/resource_pack_menu_smoke.d" \
    "$native/platform_sdl_bridge.o" "$native/vulkan_abi_bridge.o" \
    "$native/audio_miniaudio_bridge.o" "$native/image_stb_bridge.o" \
    "$native/web_cocoa_bridge.o" \
    -L-lc++ -L-L"$deps/lib" -L-lMoltenVK \
    -L-F"$deps" -L-framework -LSDL3 \
    -L-framework -LCocoa -L-framework -LFoundation \
    -L-framework -LQuartzCore -L-framework -LMetal \
    -L-framework -LCoreGraphics -L-framework -LIOKit \
    -L-framework -LIOSurface -L-framework -LCoreAudio -L-framework -LAudioToolbox \
    -L-rpath -L"$deps/lib" -L-rpath -L"$deps" -of="$out/MacOS/menu"
cd "$build/bundle/Minecraft D Edition.app/Contents/Resources"
"$out/MacOS/menu"
