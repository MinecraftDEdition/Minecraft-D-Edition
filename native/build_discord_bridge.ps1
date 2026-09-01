$ErrorActionPreference = 'Stop'

$sdk = Join-Path $PSScriptRoot '..\third_party\discord\discord_social_sdk'
$include = Join-Path $sdk 'include'
$library = Join-Path $sdk 'lib\release\discord_partner_sdk.lib'
$runtime = Join-Path $sdk 'bin\release\discord_partner_sdk.dll'
foreach ($required in @($include, $library, $runtime)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required Discord Social SDK path is missing: $required"
    }
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$installation = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $installation) { throw 'Visual C++ build tools were not found.' }

$vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
$source = Join-Path $PSScriptRoot 'discord_abi_bridge.cpp'
$output = Join-Path $PSScriptRoot 'discord_abi_bridge.obj'
$command = '"' + $vcvars + '" >nul && cl /nologo /EHsc /std:c++17 /c "' `
    + $source + '" /I"' + $include + '" /Fo"' + $output + '"'
cmd.exe /d /s /c $command
if ($LASTEXITCODE -ne 0) {
    throw "Discord ABI bridge compilation failed with exit code $LASTEXITCODE"
}

Copy-Item -LiteralPath $runtime `
    -Destination (Join-Path $PSScriptRoot '..\discord_partner_sdk.dll') -Force
