param([switch]$SkipRender)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
New-Item -ItemType Directory -Force test-output/terrain | Out-Null
foreach ($test in @('overworld_v2_smoke', 'world_generation_smoke', 'terrain_streaming_smoke', 'interaction_pause_smoke')) {
    & dmd '-i' '-O' '-Isource' "-of=test-output/terrain/$test.exe" "tests/$test.d"
    if ($LASTEXITCODE -ne 0) { throw "$test compilation failed" }
    & "./test-output/terrain/$test.exe"
    if ($LASTEXITCODE -ne 0) { throw "$test failed" }
}
if ($SkipRender) { return }
# The native readback bridge is built by Run-BlurSmoke.ps1.
if (-not (Test-Path test-output/blur/vulkan_test.obj)) {
    & ./tests/Run-BlurSmoke.ps1
}
& ./native/build_vulkan_bridge.ps1
$directx = Join-Path $env:LOCALAPPDATA 'dub/packages/directx-d/0.14.1/directx-d/src'
& dmd '-i' '-O' '-version=CORRECT_ABI' '-version=BlurSmoke' '-Isource' "-I$directx" '-Jshaders' `
    '-of=test-output/terrain/render.exe' tests/terrain_render_smoke.d `
    native/dx12_abi_bridge.obj test-output/blur/vulkan_test.obj native/vulkan-1.lib `
    ole32.lib user32.lib d3dcompiler.lib d3d12.lib dxgi.lib windowscodecs.lib xaudio2.lib
if ($LASTEXITCODE -ne 0) { throw 'Terrain render test compilation failed' }
& './test-output/terrain/render.exe'
if ($LASTEXITCODE -ne 0) { throw 'Terrain render tests failed' }
