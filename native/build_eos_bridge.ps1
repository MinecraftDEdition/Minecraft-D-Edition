$ErrorActionPreference = 'Stop'

$sdk = Join-Path $PSScriptRoot '..\third_party\eos\SDK'
$include = Join-Path $sdk 'Include'
$library = Join-Path $sdk 'Lib\EOSSDK-Win64-Shipping.lib'
$runtime = Join-Path $sdk 'Bin\EOSSDK-Win64-Shipping.dll'
foreach ($required in @($include, $library, $runtime)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required EOS SDK path is missing: $required"
    }
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $installation) { throw 'Visual C++ build tools were not found.' }
$vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
$source = Join-Path $PSScriptRoot 'eos_abi_bridge.cpp'
$output = Join-Path $PSScriptRoot 'eos_abi_bridge.obj'
$command = '"' + $vcvars + '" >nul && cl /nologo /EHsc /std:c++17 /c "' + $source + '" /I"' + $include + '" /Fo"' + $output + '"'
cmd.exe /d /s /c $command
if ($LASTEXITCODE -ne 0) { throw "EOS ABI bridge compilation failed with exit code $LASTEXITCODE" }

Copy-Item -LiteralPath $runtime -Destination (Join-Path $PSScriptRoot '..\EOSSDK-Win64-Shipping.dll') -Force
