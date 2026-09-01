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
sparkle_public_key="${MDE_SPARKLE_PUBLIC_KEY:-}"
arch="${MDE_MAC_ARCH:-$(uname -m)}"

if [[ "$arch" != arm64 && "$arch" != x86_64 ]]; then
    echo "Unsupported Mac architecture: $arch" >&2
    exit 1
fi
[[ -n "$sparkle_public_key" ]] || {
    echo 'MDE_SPARKLE_PUBLIC_KEY is required for a secure update-enabled build' >&2
    exit 1
}

bash "$script_dir/prepare_dependencies.sh"
mkdir -p "$native_out" "$bin_out" "$bundle_out"

common_cxx=(clang++ -std=c++17 -O2 -fvisibility=hidden
    -mmacosx-version-min=12.0 -arch "$arch"
    -I"$deps/include" -F"$deps")

"${common_cxx[@]}" -c "$repo/native/macos/platform_sdl_bridge.cpp" \
    -o "$native_out/platform_sdl_bridge.o"
"${common_cxx[@]}" -c "$repo/native/vulkan_abi_bridge.cpp" \
    -o "$native_out/vulkan_abi_bridge.o"
"${common_cxx[@]}" -c "$repo/native/macos/audio_miniaudio_bridge.cpp" \
    -o "$native_out/audio_miniaudio_bridge.o"
"${common_cxx[@]}" -c "$repo/native/macos/image_stb_bridge.cpp" \
    -o "$native_out/image_stb_bridge.o"
"${common_cxx[@]}" -fobjc-arc -c "$repo/native/macos/update_sparkle_bridge.mm" \
    -o "$native_out/update_sparkle_bridge.o"
"${common_cxx[@]}" -fobjc-arc -c "$repo/native/macos/web_cocoa_bridge.mm" \
    -o "$native_out/web_cocoa_bridge.o"

native_objects=(
    "$native_out/platform_sdl_bridge.o"
    "$native_out/vulkan_abi_bridge.o"
    "$native_out/audio_miniaudio_bridge.o"
    "$native_out/image_stb_bridge.o"
    "$native_out/update_sparkle_bridge.o"
    "$native_out/web_cocoa_bridge.o"
)
d_versions=(--d-version=CORRECT_ABI)
eos_runtime=""
discord_runtime=""
eos_root="${MDE_EOS_SDK_ROOT:-$repo/third_party/eos/SDK}"
if [[ -d "$eos_root/Include" && -f "$eos_root/Bin/libEOSSDK-Mac-Shipping.dylib" ]]; then
    "${common_cxx[@]}" -I"$eos_root/Include" \
        -c "$repo/native/eos_abi_bridge.cpp" -o "$native_out/eos_abi_bridge.o"
    native_objects+=("$native_out/eos_abi_bridge.o")
    d_versions+=(--d-version=MCD_EOS)
    eos_runtime="$eos_root/Bin/libEOSSDK-Mac-Shipping.dylib"
elif [[ "${MDE_REQUIRE_EOS:-0}" == 1 ]]; then
    echo "The licensed macOS EOS SDK is required but unavailable at $eos_root" >&2
    exit 1
fi

discord_root="${MDE_DISCORD_SDK_ROOT:-$repo/third_party/discord/discord_social_sdk}"
if [[ -f "$discord_root/include/discordpp.h" \
    && -f "$discord_root/lib/release/libdiscord_partner_sdk.dylib" ]]; then
    "${common_cxx[@]}" -I"$discord_root/include" \
        -c "$repo/native/discord_abi_bridge.cpp" \
        -o "$native_out/discord_abi_bridge.o"
    native_objects+=("$native_out/discord_abi_bridge.o")
    d_versions+=(--d-version=MCD_DISCORD)
    discord_runtime="$discord_root/lib/release/libdiscord_partner_sdk.dylib"
elif [[ "${MDE_REQUIRE_DISCORD:-0}" == 1 ]]; then
    echo "The Discord Social SDK is required but unavailable at $discord_root" >&2
    exit 1
fi

command -v ldc2 >/dev/null || { echo 'LDC is required to build macOS' >&2; exit 1; }

ldc2 -O3 -release -boundscheck=off -i -I"$repo/source" -J"$repo/shaders" \
    "${d_versions[@]}" "$repo/source/app.d" "${native_objects[@]}" \
    -of="$bin_out/Minecraft D Edition" \
    -L-lc++ \
    -L-L"$deps/lib" -L-lMoltenVK \
    -L-F"$deps" -L-framework -LSDL3 -L-framework -LSparkle \
    -L-framework -LCocoa -L-framework -LFoundation \
    -L-framework -LQuartzCore -L-framework -LMetal \
    -L-framework -LCoreGraphics -L-framework -LIOKit \
    -L-framework -LIOSurface -L-framework -LCoreAudio \
    -L-framework -LAudioToolbox \
    -L-rpath -L@executable_path/../Frameworks \
    ${eos_runtime:+-L"$eos_runtime"} \
    ${discord_runtime:+-L"$discord_runtime"}

app="$bundle_out/Minecraft D Edition.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" \
    "$app/Contents/Frameworks"
cp "$bin_out/Minecraft D Edition" "$app/Contents/MacOS/Minecraft D Edition"
chmod +x "$app/Contents/MacOS/Minecraft D Edition"
sed -e "s/@MDE_VERSION@/$version/g" \
    -e "s/@MDE_BUILD_NUMBER@/$build_number/g" \
    -e "s|@MDE_SPARKLE_PUBLIC_KEY@|$sparkle_public_key|g" \
    "$script_dir/Info.plist.in" > "$app/Contents/Info.plist"

icon_source="$repo/branding/minecraft_d_edition.png"
iconset="$build/minecraft_d_edition.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
sips -z 16 16 "$icon_source" --out "$iconset/icon_16x16.png" >/dev/null
sips -z 32 32 "$icon_source" --out "$iconset/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$icon_source" --out "$iconset/icon_32x32.png" >/dev/null
sips -z 64 64 "$icon_source" --out "$iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$icon_source" --out "$iconset/icon_128x128.png" >/dev/null
sips -z 256 256 "$icon_source" --out "$iconset/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$icon_source" --out "$iconset/icon_256x256.png" >/dev/null
sips -z 512 512 "$icon_source" --out "$iconset/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$icon_source" --out "$iconset/icon_512x512.png" >/dev/null
cp "$icon_source" "$iconset/icon_512x512@2x.png"
iconutil -c icns "$iconset" \
    -o "$app/Contents/Resources/minecraft_d_edition.icns"
cp -R "$deps/SDL3.framework" "$app/Contents/Frameworks/SDL3.framework"
cp -R "$deps/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp "$deps/lib/libMoltenVK.dylib" "$app/Contents/Frameworks/libMoltenVK.dylib"
if [[ -n "$eos_runtime" ]]; then
    cp "$eos_runtime" "$app/Contents/Frameworks/libEOSSDK-Mac-Shipping.dylib"
fi
if [[ -n "$discord_runtime" ]]; then
    cp "$discord_runtime" \
        "$app/Contents/Frameworks/libdiscord_partner_sdk.dylib"
    chmod +x "$app/Contents/Frameworks/libdiscord_partner_sdk.dylib"
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
mkdir -p "$app/Contents/Resources/licenses"
cp "$repo/third_party/discord/License-Notices.txt" \
    "$app/Contents/Resources/licenses/Discord-Social-SDK-Notices.txt"

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
