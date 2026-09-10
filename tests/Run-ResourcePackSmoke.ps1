$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
New-Item -ItemType Directory -Force test-output/resourcepacks | Out-Null
$directx = Join-Path $env:LOCALAPPDATA 'dub/packages/directx-d/0.14.1/directx-d/src'
& dmd '-i' '-Isource' '-of=test-output/resource_packs_smoke.exe' tests/resource_packs_smoke.d
if ($LASTEXITCODE -ne 0) { throw 'Resource pack test compilation failed' }
& './test-output/resource_packs_smoke.exe'
if ($LASTEXITCODE -ne 0) { throw 'Resource pack tests failed' }
& dmd '-i' '-Isource' "-I$directx" '-of=test-output/texture_animation_smoke.exe' tests/texture_animation_smoke.d ole32.lib windowscodecs.lib
if ($LASTEXITCODE -ne 0) { throw 'Animation test compilation failed' }
& './test-output/texture_animation_smoke.exe'
if ($LASTEXITCODE -ne 0) { throw 'Animation tests failed' }
# Run after a normal local-test build and Run-BlurSmoke.ps1 (native readback bridge).
& dmd '-i' '-g' '-debug' '-version=CORRECT_ABI' '-version=BlurSmoke' '-Isource' "-I$directx" '-Jshaders' `
    '-of=test-output/resourcepacks/menu_smoke.exe' tests/resource_pack_menu_smoke.d `
    native/dx12_abi_bridge.obj native/web_abi_bridge.obj test-output/blur/vulkan_test.obj native/vulkan-1.lib `
    ole32.lib user32.lib d3dcompiler.lib d3d12.lib dxgi.lib windowscodecs.lib xaudio2.lib winhttp.lib shell32.lib comdlg32.lib bcrypt.lib
if ($LASTEXITCODE -ne 0) { throw 'Pack menu test compilation failed' }
& './test-output/resourcepacks/menu_smoke.exe'
if ($LASTEXITCODE -ne 0) { throw 'Pack menu GPU test failed' }
