$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
New-Item -ItemType Directory -Force test-output/zombie | Out-Null
& dmd '-i' '-Isource' '-of=test-output/zombie/network.exe' tests/zombie_network_smoke.d
if ($LASTEXITCODE -ne 0) { throw 'Zombie network test compilation failed' }
& './test-output/zombie/network.exe'
if ($LASTEXITCODE -ne 0) { throw 'Zombie multiplayer test failed' }
# Build native libraries first with the local-test build and Run-BlurSmoke.ps1.
$directx = Join-Path $env:LOCALAPPDATA 'dub/packages/directx-d/0.14.1/directx-d/src'
& dmd '-i' '-g' '-debug' '-version=CORRECT_ABI' '-version=BlurSmoke' '-Isource' "-I$directx" '-Jshaders' `
    '-of=test-output/zombie/render.exe' tests/zombie_render_smoke.d `
    native/dx12_abi_bridge.obj test-output/blur/vulkan_test.obj native/vulkan-1.lib `
    ole32.lib user32.lib d3dcompiler.lib d3d12.lib dxgi.lib windowscodecs.lib xaudio2.lib
if ($LASTEXITCODE -ne 0) { throw 'Zombie render test compilation failed' }
& './test-output/zombie/render.exe'
if ($LASTEXITCODE -ne 0) { throw 'Zombie render test failed' }
