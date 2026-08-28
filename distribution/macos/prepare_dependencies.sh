#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
deps="$script_dir/build/deps"
downloads="$script_dir/build/downloads"
mkdir -p "$deps/include" "$deps/lib" "$downloads"

verify_sha256() {
    local expected="$1"
    local file="$2"
    local actual
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "SHA-256 mismatch for $file" >&2
        echo "expected $expected" >&2
        echo "actual   $actual" >&2
        exit 1
    fi
}

sdl_dmg="$downloads/SDL3-3.4.14.dmg"
if [[ ! -f "$sdl_dmg" ]]; then
    curl --fail --location --retry 3 \
        'https://github.com/libsdl-org/SDL/releases/download/release-3.4.14/SDL3-3.4.14.dmg' \
        --output "$sdl_dmg"
fi
verify_sha256 bae77509ccddcc7a443bb09730ab854c976e8f8bcf57b66d6bad6af2e17f38c2 "$sdl_dmg"
if [[ ! -d "$deps/SDL3.framework" ]]; then
    mount="$script_dir/build/sdl-mount"
    mkdir -p "$mount"
    hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$sdl_dmg" >/dev/null
    trap 'hdiutil detach "$mount" >/dev/null 2>&1 || true' EXIT
    framework="$mount/SDL3.framework"
    if [[ ! -d "$framework" ]]; then
        framework="$(find "$mount" -path '*SDL3.xcframework/macos-*/SDL3.framework' \
            -type d | head -n 1)"
    fi
    [[ -n "$framework" ]] || { echo 'SDL3.framework was not found in the DMG' >&2; exit 1; }
    cp -R "$framework" "$deps/SDL3.framework"
    hdiutil detach "$mount" >/dev/null
    trap - EXIT
fi

molten_tar="$downloads/MoltenVK-macos-1.4.2.tar"
if [[ ! -f "$molten_tar" ]]; then
    curl --fail --location --retry 3 \
        'https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-macos.tar' \
        --output "$molten_tar"
fi
verify_sha256 f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e "$molten_tar"
if [[ ! -f "$deps/lib/libMoltenVK.dylib" ]]; then
    molten_extract="$script_dir/build/moltenvk"
    rm -rf "$molten_extract"
    mkdir -p "$molten_extract"
    tar -xf "$molten_tar" -C "$molten_extract"
    molten_lib="$(find "$molten_extract" -name libMoltenVK.dylib -type f | head -n 1)"
    molten_headers="$(find "$molten_extract" -path '*/include/vulkan/vulkan.h' -type f | head -n 1)"
    [[ -n "$molten_lib" && -n "$molten_headers" ]] || {
        echo 'MoltenVK library or Vulkan headers were not found' >&2
        exit 1
    }
    cp "$molten_lib" "$deps/lib/libMoltenVK.dylib"
    molten_include="$(dirname "$(dirname "$molten_headers")")"
    cp -R "$molten_include/vulkan" "$deps/include/vulkan"
    cp -R "$molten_include/vk_video" "$deps/include/vk_video"
fi

miniaudio="$deps/include/miniaudio.h"
if [[ ! -f "$miniaudio" ]]; then
    curl --fail --location --retry 3 \
        'https://raw.githubusercontent.com/mackron/miniaudio/0.11.25/miniaudio.h' \
        --output "$miniaudio"
fi
verify_sha256 ac7af4de748b7e26b777f37e01cee313a308a7296a3eb080e2906b320cc55c89 "$miniaudio"

stb_image="$deps/include/stb_image.h"
if [[ ! -f "$stb_image" ]]; then
    curl --fail --location --retry 3 \
        'https://raw.githubusercontent.com/nothings/stb/f58f558c120e9b32c217290b80bad1a0729fbb2c/stb_image.h' \
        --output "$stb_image"
fi
verify_sha256 594c2fe35d49488b4382dbfaec8f98366defca819d916ac95becf3e75f4200b3 "$stb_image"

echo "macOS dependencies prepared in $deps"
