param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$version = '3.4.14'
$expectedArchiveSha256 = '2fe279e70d426e9c644b625acb3083eb3cfb263a92f2c5718aff18d24a8b6e96'
$url = "https://github.com/libsdl-org/SDL/releases/download/release-$version/SDL3-devel-$version-VC.zip"
$dependencyRoot = Join-Path $ProjectRoot 'third_party\sdl3'
$downloadRoot = Join-Path $dependencyRoot 'downloads'
$runtimeRoot = Join-Path $dependencyRoot 'windows\x64'
$archive = Join-Path $downloadRoot "SDL3-devel-$version-VC.zip"
$library = Join-Path $runtimeRoot 'SDL3.lib'
$runtime = Join-Path $runtimeRoot 'SDL3.dll'
$projectRuntime = Join-Path $ProjectRoot 'SDL3.dll'

function Get-Sha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($algorithm.ComputeHash($stream)) `
                -replace '-', '').ToLowerInvariant()
        }
        finally { $algorithm.Dispose() }
    }
    finally { $stream.Dispose() }
}

New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null

if (-not (Test-Path -LiteralPath $archive -PathType Leaf) -or
    (Get-Sha256 $archive) -ne $expectedArchiveSha256) {
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
}

$actualHash = Get-Sha256 $archive
if ($actualHash -ne $expectedArchiveSha256) {
    throw "SDL3 archive checksum mismatch. Expected $expectedArchiveSha256 but received $actualHash."
}

if (-not (Test-Path -LiteralPath $library -PathType Leaf) -or
    -not (Test-Path -LiteralPath $runtime -PathType Leaf)) {
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("mde-sdl3-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    try {
        Expand-Archive -LiteralPath $archive -DestinationPath $temporaryRoot
        $sourceLibrary = Get-ChildItem -LiteralPath $temporaryRoot -Recurse -File |
            Where-Object { $_.FullName -match '[\\/]lib[\\/]x64[\\/]SDL3\.lib$' } |
            Select-Object -First 1
        $sourceRuntime = Get-ChildItem -LiteralPath $temporaryRoot -Recurse -File |
            Where-Object { $_.FullName -match '[\\/]lib[\\/]x64[\\/]SDL3\.dll$' } |
            Select-Object -First 1
        if (-not $sourceLibrary -or -not $sourceRuntime) {
            throw 'The pinned SDL3 archive does not contain the expected x64 Visual C++ runtime.'
        }
        Copy-Item -LiteralPath $sourceLibrary.FullName -Destination $library -Force
        Copy-Item -LiteralPath $sourceRuntime.FullName -Destination $runtime -Force
    }
    finally {
        $resolvedTemporary = [IO.Path]::GetFullPath($temporaryRoot)
        $resolvedSystemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolvedTemporary.StartsWith($resolvedSystemTemp,
                [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

Copy-Item -LiteralPath $runtime -Destination $projectRuntime -Force
