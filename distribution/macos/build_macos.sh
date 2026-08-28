#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$script_dir/../.." && pwd)"
build="$script_dir/build"
deps="$build/deps"
native_out="$build/native"
bin_out="$build/bin"
bundle_out="$build/bundle"
version="${MDE_VERSION:-0.0.0-test}"
build_number="${MDE_BUILD_NUMBER:-1}"
arch="${MDE_MAC_ARCH:-$(uname -m)}"

if [[ "$arch" != arm64 && "$arch" != x86_64 ]]; then
    echo "Unsupported Mac architecture: $arch" >&2
    exit 1
fi

bash "$script_dir/prepare_dependencies.sh"
mkdir -p "$native_out" "$bin_out" "$bundle_out"

common_cxx=(clang++ -std=c++17 -O2 -fvisibility=hidden
    -mmacosx-version-min=12.0 -arch "$arch"
    -I"$deps/include" -I"$deps/SDL3.framework/Headers")

"${common_cxx[@]}" -c "$repo/native/macos/platform_sdl_bridge.cpp" \
    -o "$native_out/platform_sdl_bridge.o"
"${common_cxx[@]}" -c "$repo/native/vulkan_abi_bridge.cpp" \
    -o "$native_out/vulkan_abi_bridge.o"
"${common_cxx[@]}" -c "$repo/native/macos/audio_miniaudio_bridge.cpp" \
    -o "$native_out/audio_miniaudio_bridge.o"
"${common_cxx[@]}" -c "$repo/native/macos/image_stb_bridge.cpp" \
    -o "$native_out/image_stb_bridge.o"

native_objects=(
    "$native_out/platform_sdl_bridge.o"
    "$native_out/vulkan_abi_bridge.o"
    "$native_out/audio_miniaudio_bridge.o"
    "$native_out/image_stb_bridge.o"
)
d_versions=(--d-version=CORRECT_ABI)
eos_runtime=""
eos_root="${MDE_EOS_SDK_ROOT:-$repo/third_party/eos/SDK}"
if [[ -d "$eos_root/Include" && -f "$eos_root/Bin/libEOSSDK-Mac-Shipping.dylib" ]]; then
    "${common_cxx[@]}" -I"$eos_root/Include" \
        -c "$repo/native/eos_abi_bridge.cpp" -o "$native_out/eos_abi_bridge.o"
    native_objects+=("$native_out/eos_abi_bridge.o")
    d_versions+=(--d-version=MCD_EOS)
    eos_runtime="$eos_root/Bin/libEOSSDK-Mac-Shipping.dylib"
fi

command -v ldc2 >/dev/null || { echo 'LDC is required to build macOS' >&2; exit 1; }

ldc2 -O3 -release -boundscheck=off -i -I"$repo/source" -J"$repo/shaders" \
    "${d_versions[@]}" "$repo/source/app.d" "${native_objects[@]}" \
    -of="$bin_out/Minecraft D Edition" \
    -L-L"$deps/lib" -L-lMoltenVK \
    -L-F"$deps" -L-framework -LSDL3 \
    -L-framework -LCocoa -L-framework -LFoundation \
    -L-framework -LQuartzCore -L-framework -LMetal \
    -L-framework -LCoreGraphics -L-framework -LIOKit \
    -L-framework -LIOSurface -L-framework -LCoreAudio \
    -L-framework -LAudioToolbox \
    -L-rpath -L@executable_path/../Frameworks \
    ${eos_runtime:+-L"$eos_runtime"}

app="$bundle_out/Minecraft D Edition.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" \
    "$app/Contents/Frameworks"
cp "$bin_out/Minecraft D Edition" "$app/Contents/MacOS/Minecraft D Edition"
chmod +x "$app/Contents/MacOS/Minecraft D Edition"
sed -e "s/@MDE_VERSION@/$version/g" \
    -e "s/@MDE_BUILD_NUMBER@/$build_number/g" \
    "$script_dir/Info.plist.in" > "$app/Contents/Info.plist"
cp -R "$deps/SDL3.framework" "$app/Contents/Frameworks/SDL3.framework"
cp "$deps/lib/libMoltenVK.dylib" "$app/Contents/Frameworks/libMoltenVK.dylib"
if [[ -n "$eos_runtime" ]]; then
    cp "$eos_runtime" "$app/Contents/Frameworks/libEOSSDK-Mac-Shipping.dylib"
fi

content_root="${MDE_CONTENT_ROOT:-$repo}"
[[ -d "$content_root/assets" ]] && cp -R "$content_root/assets" "$app/Contents/Resources/assets"
if [[ -d "$content_root/data/minecraft" ]]; then
    mkdir -p "$app/Contents/Resources/data"
    cp -R "$content_root/data/minecraft" "$app/Contents/Resources/data/minecraft"
fi
if [[ -f "$content_root/data/eos.client.json" ]]; then
    mkdir -p "$app/Contents/Resources/data"
    cp "$content_root/data/eos.client.json" "$app/Contents/Resources/data/eos.client.json"
fi
mkdir -p "$app/Contents/Resources/shaders"
cp -R "$repo/shaders/spirv" "$app/Contents/Resources/shaders/spirv"

if [[ -n "${MDE_CODESIGN_IDENTITY:-}" ]]; then
    find "$app/Contents/Frameworks" -type f -perm -111 -print0 | \
        xargs -0 -I{} codesign --force --options runtime --timestamp \
            --sign "$MDE_CODESIGN_IDENTITY" "{}"
    codesign --force --options runtime --timestamp \
        --sign "$MDE_CODESIGN_IDENTITY" "$app"
else
    codesign --force --deep --sign - "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"

dmg_root="$build/dmg-root"
rm -rf "$dmg_root"
mkdir -p "$dmg_root"
cp -R "$app" "$dmg_root/Minecraft D Edition.app"
ln -s /Applications "$dmg_root/Applications"
dmg="$build/Minecraft.D.Edition-macOS-$arch.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname 'Minecraft D Edition' -srcfolder "$dmg_root" \
    -format UDZO -ov "$dmg"

echo "macOS app: $app"
echo "macOS DMG: $dmg"
