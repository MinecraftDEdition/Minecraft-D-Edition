param(
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [Parameter(Mandatory = $true)][string]$Version,
    [ValidateRange(1, 512)][int]$ChunkCount = 128
)

$ErrorActionPreference = 'Stop'
$RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\')
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) {
    throw "Runtime folder does not exist: $RuntimeRoot"
}
if ($RuntimeRoot -eq $OutputRoot -or $OutputRoot.StartsWith($RuntimeRoot + '\',
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Update output must not be inside the runtime folder.'
}
if ($Version -match "[`r`n`t]") {
    throw 'Version may not contain tabs or line breaks.'
}

if (Test-Path -LiteralPath $OutputRoot) {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputRoot | Out-Null

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$sha256 = [Security.Cryptography.SHA256]::Create()

function Get-RelativeRuntimePath([string]$Path) {
    return $Path.Substring($RuntimeRoot.Length + 1).Replace('\', '/')
}

function Get-Sha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally { $stream.Dispose() }
}

function Get-ChunkIndex([string]$RelativePath) {
    $bytes = $utf8NoBom.GetBytes($RelativePath.ToLowerInvariant())
    $digest = $sha256.ComputeHash($bytes)
    return [BitConverter]::ToUInt32($digest, 0) % $ChunkCount
}

$excluded = @(
    'Minecraft D Edition Launcher.exe',
    '.mde-installed-manifest.txt'
)
$records = [Collections.Generic.List[object]]::new()
$hashedFiles = 0
foreach ($file in Get-ChildItem -LiteralPath $RuntimeRoot -Recurse -File |
    Sort-Object FullName) {
    $relative = Get-RelativeRuntimePath $file.FullName
    if ($excluded -contains $relative) { continue }
    if ($relative -match '(^|/)(saves|screenshots|eos-cache|cache)(/|$)' -or
        $relative -in @('data/options.txt', 'data/eos.local.json',
            'data/server_entry.txt', 'data/window_state.txt',
            'data/account_session.token')) {
        throw "User-owned file was accidentally staged for updating: $relative"
    }
    $records.Add([pscustomobject]@{
        Path = $relative
        FullName = $file.FullName
        Size = $file.Length
        Sha256 = Get-Sha256 $file.FullName
        ChunkIndex = Get-ChunkIndex $relative
        Chunk = $null
    })
    ++$hashedFiles
    if (($hashedFiles % 1000) -eq 0) {
        Write-Host "Hashed $hashedFiles runtime files..."
    }
}
if ($records.Count -eq 0) { throw 'No managed runtime files were found.' }

$chunkRecords = [Collections.Generic.List[object]]::new()
$builtChunks = 0
foreach ($group in $records | Group-Object ChunkIndex | Sort-Object { [int]$_.Name }) {
    $index = [int]$group.Name
    $temporaryName = 'mde-shard-{0:d3}.zip' -f $index
    $temporaryPath = Join-Path $OutputRoot $temporaryName
    $stream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream,
            [IO.Compression.ZipArchiveMode]::Create, $true, $utf8NoBom)
        try {
            foreach ($record in $group.Group | Sort-Object Path) {
                $entry = $archive.CreateEntry($record.Path,
                    [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0,
                    [TimeSpan]::Zero)
                $input = [IO.File]::OpenRead($record.FullName)
                $output = $entry.Open()
                try { $input.CopyTo($output) }
                finally { $output.Dispose(); $input.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }

    $chunkHash = Get-Sha256 $temporaryPath
    $finalName = 'mde-shard-{0:d3}-{1}.zip' -f $index,$chunkHash.Substring(0, 16)
    $finalPath = Join-Path $OutputRoot $finalName
    Move-Item -LiteralPath $temporaryPath -Destination $finalPath
    foreach ($record in $group.Group) { $record.Chunk = $finalName }
    $chunkRecords.Add([pscustomobject]@{
        Name = $finalName
        Size = (Get-Item -LiteralPath $finalPath).Length
        Sha256 = $chunkHash
    })
    ++$builtChunks
    if (($builtChunks % 16) -eq 0) {
        Write-Host "Built $builtChunks update shards..."
    }
}

$manifestLines = [Collections.Generic.List[string]]::new()
$manifestLines.Add("MDE-UPDATE-MANIFEST`t1")
$manifestLines.Add("version`t$Version")
foreach ($chunk in $chunkRecords | Sort-Object Name) {
    $manifestLines.Add("chunk`t$($chunk.Name)`t$($chunk.Size)`t$($chunk.Sha256)")
}
foreach ($record in $records | Sort-Object Path) {
    $manifestLines.Add("file`t$($record.Path)`t$($record.Size)`t$($record.Sha256)`t$($record.Chunk)")
}
$manifestPath = Join-Path $OutputRoot 'mde-update-manifest-v1.txt'
[IO.File]::WriteAllText($manifestPath, ($manifestLines -join "`n") + "`n", $utf8NoBom)
$pointerPath = Join-Path $OutputRoot 'mde-update-pointer-v1.txt'
& (Join-Path $PSScriptRoot 'Write-MdeUpdatePointer.ps1') `
    -ManifestPath $manifestPath -OutputPath $pointerPath -Version $Version

$summary = [pscustomobject]@{
    Version = $Version
    Files = $records.Count
    Shards = $chunkRecords.Count
    PayloadBytes = ($chunkRecords | Measure-Object Size -Sum).Sum
    Manifest = $manifestPath
    Pointer = $pointerPath
}
$summary | Format-List
$sha256.Dispose()
