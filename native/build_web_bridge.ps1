$ErrorActionPreference = 'Stop'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $installation) { throw 'Visual C++ build tools were not found.' }
$vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
$source = Join-Path $PSScriptRoot 'web_abi_bridge.cpp'
$output = Join-Path $PSScriptRoot 'web_abi_bridge.obj'
$command = '"' + $vcvars + '" >nul && cl /nologo /EHsc /std:c++17 /c "' + $source + '" /Fo"' + $output + '"'
cmd.exe /d /s /c $command
if ($LASTEXITCODE -ne 0) { throw "Web ABI bridge compilation failed with exit code $LASTEXITCODE" }
