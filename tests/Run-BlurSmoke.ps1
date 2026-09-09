$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
New-Item -ItemType Directory -Force 'test-output/blur' | Out-Null
$command = '"' + $vcvars + '" >nul && cl /nologo /EHsc /std:c++17 /c tests\blur_readback.cpp /I"' + $env:VULKAN_SDK + '\Include" /Fotest-output\blur\vulkan_test.obj'
cmd.exe /d /s /c $command
if ($LASTEXITCODE -ne 0) { throw 'Blur test bridge compilation failed' }
$directx = Join-Path $env:LOCALAPPDATA 'dub/packages/directx-d/0.14.1/directx-d/src'
& dmd '-i' '-g' '-debug' '-version=CORRECT_ABI' '-version=BlurSmoke' '-Isource' "-I$directx" '-Jshaders' `
    '-of=test-output/blur/blur_render_smoke.exe' tests/blur_render_smoke.d `
    native/dx12_abi_bridge.obj test-output/blur/vulkan_test.obj native/vulkan-1.lib `
    ole32.lib user32.lib d3dcompiler.lib d3d12.lib dxgi.lib windowscodecs.lib xaudio2.lib
if ($LASTEXITCODE -ne 0) { throw 'Blur test compilation failed' }
& './test-output/blur/blur_render_smoke.exe'
if ($LASTEXITCODE -ne 0) { throw 'Blur GPU regression failed' }
Get-ChildItem -LiteralPath 'test-output/blur' -Filter 'dx12-*.ppm' | ForEach-Object {
    $vulkanFile = Join-Path $_.DirectoryName ($_.Name -replace '^dx12-', 'vulkan-')
    if ((Get-FileHash -LiteralPath $_.FullName).Hash -ne (Get-FileHash -LiteralPath $vulkanFile).Hash) {
        throw "Renderer output mismatch: $($_.Name)"
    }
}
Write-Host 'DX12 and Vulkan blur readbacks match pixel for pixel.'
