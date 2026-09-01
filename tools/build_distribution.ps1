param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Version = (Get-Date).ToUniversalTime().ToString('yyyy.MM.dd.HHmmss'),
    [ValidateRange(1, 512)][int]$ChunkCount = 128,
    [switch]$SkipGameBuild,
    [switch]$SkipInstaller,
    [switch]$BuildPortable,
    [switch]$BuildOfflineInstaller
)

# Windows distribution entry point. macOS and Linux packages have independent
# build/sign/update pipelines under distribution/<platform>.
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$dist = Join-Path $ProjectRoot 'dist'
$runtime = Join-Path $dist 'runtime'
$updates = Join-Path $dist 'updates'

if (-not $SkipGameBuild) {
    Push-Location $ProjectRoot
    try {
        & dub build --build=release --force
        if ($LASTEXITCODE -ne 0) { throw "Game build failed with exit code $LASTEXITCODE" }
    }
    finally { Pop-Location }
}

# Release copies are GUI-subsystem applications. Development builds remain
# console applications so command-line diagnostics still work in Admin.
& (Join-Path $ProjectRoot 'tools\Set-MdeWindowsGuiSubsystem.ps1') `
    -Path (Join-Path $ProjectRoot 'Minecraft D Edition.exe')

& (Join-Path $ProjectRoot 'distribution\windows\launcher\build_launcher.ps1') `
    -ProjectRoot $ProjectRoot

if (Test-Path -LiteralPath $dist) {
    $resolvedDist = [IO.Path]::GetFullPath($dist)
    if (-not $resolvedDist.StartsWith($ProjectRoot + '\',
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to clear a distribution folder outside the project.'
    }
    Remove-Item -LiteralPath $resolvedDist -Recurse -Force
}
New-Item -ItemType Directory -Path $runtime | Out-Null

$requiredFiles = @(
    'Minecraft D Edition.exe',
    'Minecraft D Edition Launcher.exe',
    'EOSSDK-Win64-Shipping.dll',
    'discord_partner_sdk.dll',
    'SDL3.dll'
)
foreach ($relative in $requiredFiles) {
    $source = Join-Path $ProjectRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Required runtime file is missing: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $runtime $relative)
}
# The running launcher is intentionally not a managed manifest target because
# older installed versions cannot overwrite their own executable. The updater
# downloads this sidecar normally; the game/new helper promotes it atomically
# after the original launcher process has exited.
Copy-Item -LiteralPath (Join-Path $ProjectRoot `
    'Minecraft D Edition Launcher.exe') -Destination (Join-Path $runtime `
    'Minecraft D Edition Launcher.update.exe')

Copy-Item -LiteralPath (Join-Path $ProjectRoot 'assets') -Destination $runtime -Recurse
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'shaders') -Destination $runtime -Recurse
New-Item -ItemType Directory -Path (Join-Path $runtime 'data') | Out-Null
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'data\minecraft') `
    -Destination (Join-Path $runtime 'data') -Recurse
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'data\eos.example.json') `
    -Destination (Join-Path $runtime 'data\eos.example.json')
$eosLocalConfig = Join-Path $ProjectRoot 'data\eos.local.json'
if (-not (Test-Path -LiteralPath $eosLocalConfig -PathType Leaf)) {
    throw 'A private data\eos.local.json is required to build a multiplayer release.'
}
try {
    $eosConfig = Get-Content -LiteralPath $eosLocalConfig -Raw | ConvertFrom-Json
    foreach ($field in @('productId','sandboxId','deploymentId','clientId','clientSecret')) {
        if ([String]::IsNullOrWhiteSpace([string]$eosConfig.$field)) {
            throw "EOS configuration is missing $field."
        }
    }
}
catch {
    throw "The private EOS configuration is invalid: $($_.Exception.Message)"
}
# The raw developer file remains ignored by Git. A release-only client copy is
# managed by the updater, while eos.local.json remains an optional local override.
Copy-Item -LiteralPath $eosLocalConfig `
    -Destination (Join-Path $runtime 'data\eos.client.json')

New-Item -ItemType Directory -Path (Join-Path $runtime 'licenses') | Out-Null
Copy-Item -LiteralPath (Join-Path $ProjectRoot `
    'third_party\discord\License-Notices.txt') `
    -Destination (Join-Path $runtime 'licenses\Discord-Social-SDK-Notices.txt')

# Deflate output differs between Windows PowerShell's .NET Framework and modern
# .NET. Always use PowerShell 7 so unchanged content keeps the same shard hash.
$pwshCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if (-not $pwshCommand) {
    throw 'PowerShell 7 (pwsh.exe) is required for stable differential release shards.'
}
& $pwshCommand.Source -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $ProjectRoot 'tools\New-MdeUpdatePackage.ps1') `
    -RuntimeRoot $runtime -OutputRoot $updates -Version $Version `
    -ChunkCount $ChunkCount
if ($LASTEXITCODE -ne 0) {
    throw "Update-package build failed with exit code $LASTEXITCODE"
}
Copy-Item -LiteralPath (Join-Path $updates 'mde-update-manifest-v1.txt') `
    -Destination (Join-Path $runtime '.mde-installed-manifest.txt')

if ($BuildPortable) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $portable = Join-Path $dist 'Minecraft.D.Edition.Portable.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($runtime, $portable,
        [IO.Compression.CompressionLevel]::Optimal, $false)
}

if (-not $SkipInstaller) {
    $isccCommand = Get-Command iscc.exe -ErrorAction SilentlyContinue
    $isccPath = if ($isccCommand) { $isccCommand.Source } else { $null }
    if (-not $isccPath) {
        $isccPath = @(
            "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
            "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
            "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if (-not $isccPath) {
        throw 'Inno Setup 6 is required to build the installer. Use -SkipInstaller only for update-payload testing.'
    }
    $env:MDE_VERSION = $Version
    if ($BuildOfflineInstaller) {
        & $isccPath (Join-Path $ProjectRoot `
            'distribution\windows\installer\MinecraftDEdition.iss')
        if ($LASTEXITCODE -ne 0) { throw "Offline installer build failed with exit code $LASTEXITCODE" }
    }
    & $isccPath (Join-Path $ProjectRoot `
        'distribution\windows\installer\MinecraftDEditionWeb.iss')
    if ($LASTEXITCODE -ne 0) { throw "Web installer build failed with exit code $LASTEXITCODE" }
}

Write-Host "Distribution ready in $dist"
