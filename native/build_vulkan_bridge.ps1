$ErrorActionPreference = 'Stop'

$sdk = $env:VULKAN_SDK
if ([String]::IsNullOrWhiteSpace($sdk) -or
    -not (Test-Path -LiteralPath (Join-Path $sdk 'Include\vulkan\vulkan.h'))) {
    throw 'Vulkan SDK is required. Install it and set VULKAN_SDK.'
}
$dxc = Join-Path $sdk 'Bin\dxc.exe'
$shaderSource = Join-Path $PSScriptRoot '..\shaders\world.hlsl'
$shaderOutput = Join-Path $PSScriptRoot '..\shaders\spirv'
New-Item -ItemType Directory -Path $shaderOutput -Force | Out-Null

& $dxc -spirv -D VULKAN=1 -T vs_6_0 -E VSMain `
    '-fspv-target-env=vulkan1.1' -fvk-use-dx-layout `
    -Fo (Join-Path $shaderOutput 'world.vert.spv') $shaderSource
if ($LASTEXITCODE -ne 0) { throw 'Vulkan vertex shader compilation failed.' }
& $dxc -spirv -D VULKAN=1 -T ps_6_0 -E PSMain `
    '-fspv-target-env=vulkan1.1' -fvk-use-dx-layout `
    -Fo (Join-Path $shaderOutput 'world.frag.spv') $shaderSource
if ($LASTEXITCODE -ne 0) { throw 'Vulkan pixel shader compilation failed.' }
& $dxc -spirv -D VULKAN=1 -T ps_6_0 -E PSBlur `
    '-fspv-target-env=vulkan1.1' -fvk-use-dx-layout `
    -Fo (Join-Path $shaderOutput 'world.blur.frag.spv') $shaderSource
if ($LASTEXITCODE -ne 0) { throw 'Vulkan blur shader compilation failed.' }

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$installation = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $installation) { throw 'Visual C++ build tools were not found.' }
$vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
$source = Join-Path $PSScriptRoot 'vulkan_abi_bridge.cpp'
$output = Join-Path $PSScriptRoot 'vulkan_abi_bridge.obj'
$include = Join-Path $sdk 'Include'
$command = '"' + $vcvars + '" >nul && cl /nologo /EHsc /std:c++17 /c "' `
    + $source + '" /I"' + $include + '" /Fo"' + $output + '"'
cmd.exe /d /s /c $command
if ($LASTEXITCODE -ne 0) { throw "Vulkan ABI bridge compilation failed with exit code $LASTEXITCODE" }

Copy-Item -LiteralPath (Join-Path $sdk 'Lib\vulkan-1.lib') `
    -Destination (Join-Path $PSScriptRoot 'vulkan-1.lib') -Force
