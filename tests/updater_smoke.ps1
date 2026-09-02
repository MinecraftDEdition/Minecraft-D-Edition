$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('minecraft-d-updater-smoke-' + [Guid]::NewGuid().ToString('N'))
$oldRuntime = Join-Path $testRoot 'installed'
$newRuntime = Join-Path $testRoot 'new-runtime'
$oldPayload = Join-Path $testRoot 'old-payload'
$newPayload = Join-Path $testRoot 'new-payload'
$server = $null

function Write-Utf8([string]$Path, [string]$Value) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

try {
    New-Item -ItemType Directory -Path $oldRuntime,$newRuntime | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'Minecraft D Edition Launcher.exe') `
        -Destination (Join-Path $oldRuntime 'Minecraft D Edition Launcher.exe')

    Write-Utf8 (Join-Path $oldRuntime 'Minecraft D Edition.exe') 'old-game'
    Write-Utf8 (Join-Path $oldRuntime 'assets\unchanged.txt') 'same'
    Write-Utf8 (Join-Path $oldRuntime 'assets\changed.txt') 'old'
    Write-Utf8 (Join-Path $oldRuntime 'assets\removed.txt') 'remove-me'

    Copy-Item -LiteralPath (Join-Path $oldRuntime 'Minecraft D Edition.exe') `
        -Destination (Join-Path $newRuntime 'Minecraft D Edition.exe')
    Write-Utf8 (Join-Path $newRuntime 'Minecraft D Edition.exe') 'new-game'
    Copy-Item -LiteralPath (Join-Path $projectRoot `
        'Minecraft D Edition Launcher.exe') -Destination (Join-Path $newRuntime `
        'Minecraft D Edition Launcher.update.exe')
    # A PE image permits harmless overlay bytes. This produces a different but
    # still runnable launcher so the smoke test exercises deferred self-update.
    [IO.File]::AppendAllText((Join-Path $newRuntime `
        'Minecraft D Edition Launcher.update.exe'), 'self-update-smoke-marker',
        [Text.UTF8Encoding]::new($false))
    Write-Utf8 (Join-Path $newRuntime 'assets\unchanged.txt') 'same'
    Write-Utf8 (Join-Path $newRuntime 'assets\changed.txt') 'new'
    Write-Utf8 (Join-Path $newRuntime 'assets\added.txt') 'added'

    & (Join-Path $projectRoot 'tools\New-MdeUpdatePackage.ps1') `
        -RuntimeRoot $oldRuntime -OutputRoot $oldPayload -Version 'smoke-old' `
        -ChunkCount 4 | Out-Null
    Copy-Item -LiteralPath (Join-Path $oldPayload 'mde-update-manifest-v1.txt') `
        -Destination (Join-Path $oldRuntime '.mde-installed-manifest.txt')
    Write-Utf8 (Join-Path $oldRuntime 'saves\World\level.dat') 'precious-save'
    & (Join-Path $projectRoot 'tools\New-MdeUpdatePackage.ps1') `
        -RuntimeRoot $newRuntime -OutputRoot $newPayload -Version 'smoke-new' `
        -ChunkCount 4 | Out-Null

    $python = (Get-Command python.exe -ErrorAction Stop).Source
    $port = Get-Random -Minimum 41000 -Maximum 49000
    $server = Start-Process -FilePath $python -WindowStyle Hidden -PassThru `
        -WorkingDirectory $newPayload -ArgumentList @('-m','http.server',$port,
            '--bind','127.0.0.1')
    $baseUrl = "http://127.0.0.1:$port"
    foreach ($attempt in 1..30) {
        try {
            Invoke-WebRequest -UseBasicParsing `
                "$baseUrl/mde-update-manifest-v1.txt" | Out-Null
            break
        }
        catch {
            if ($attempt -eq 30) { throw }
            Start-Sleep -Milliseconds 100
        }
    }

    $env:MDE_UPDATE_ASSET_BASE_URL = $baseUrl
    $process = Start-Process -FilePath `
        (Join-Path $oldRuntime 'Minecraft D Edition Launcher.exe') `
        -WorkingDirectory $oldRuntime -ArgumentList '--updater-check-only' `
        -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Launcher exited with $($process.ExitCode)" }

    foreach ($attempt in 1..600) {
        $installedManifest = Join-Path $oldRuntime '.mde-installed-manifest.txt'
        $verifiedState = Join-Path $oldRuntime '.mde-verified-files-v1.txt'
        if ((Test-Path -LiteralPath $installedManifest) -and
            (Get-Content -Raw $installedManifest) -match "version`tsmoke-new" -and
            (Test-Path -LiteralPath $verifiedState)) {
            break
        }
        if ($attempt -eq 600) { throw 'Deferred launcher update did not complete.' }
        Start-Sleep -Milliseconds 100
    }

    if ((Get-Content -Raw (Join-Path $oldRuntime 'Minecraft D Edition.exe')) -ne 'new-game') {
        throw 'Game executable was not updated.'
    }
    if ((Get-Content -Raw (Join-Path $oldRuntime 'assets\changed.txt')) -ne 'new') {
        throw 'Changed content was not updated.'
    }
    if ((Get-Content -Raw (Join-Path $oldRuntime 'assets\unchanged.txt')) -ne 'same') {
        throw 'Unchanged content was modified.'
    }
    if ((Get-Content -Raw (Join-Path $oldRuntime 'assets\added.txt')) -ne 'added') {
        throw 'New content was not installed.'
    }
    if (Test-Path -LiteralPath (Join-Path $oldRuntime 'assets\removed.txt')) {
        throw 'Removed managed content was retained.'
    }
    if ((Get-Content -Raw (Join-Path $oldRuntime 'saves\World\level.dat')) -ne 'precious-save') {
        throw 'User save data was modified.'
    }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $oldRuntime `
        'Minecraft D Edition Launcher.exe')).Hash -ne
        (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $newRuntime `
        'Minecraft D Edition Launcher.update.exe')).Hash) {
        throw 'The installed launcher did not update itself.'
    }
    if ((Get-Content -Raw (Join-Path $oldRuntime '.mde-installed-manifest.txt')) `
        -notmatch "version`tsmoke-new") {
        throw 'Installed manifest was not advanced.'
    }

    # A matching version must still repair files that disappeared or were
    # corrupted after installation, without needing the original Setup EXE.
    # Normal launches use the verified cache immediately and refresh its full
    # SHA-256 audit in the background once per day; age it here to exercise the
    # synchronous repair path deterministically.
    Remove-Item -LiteralPath (Join-Path $oldRuntime 'assets\added.txt')
    Write-Utf8 (Join-Path $oldRuntime 'assets\changed.txt') 'corrupted'
    [IO.File]::SetLastWriteTimeUtc((Join-Path $oldRuntime `
        '.mde-verified-files-v1.txt'), [DateTime]::UtcNow.AddDays(-2))
    $repair = Start-Process -FilePath `
        (Join-Path $oldRuntime 'Minecraft D Edition Launcher.exe') `
        -WorkingDirectory $oldRuntime -ArgumentList '--updater-check-only' `
        -Wait -PassThru
    if ($repair.ExitCode -ne 0) { throw "Repair check exited with $($repair.ExitCode)" }
    $repairMarker = Join-Path $oldRuntime '.mde-verification-required'
    foreach ($attempt in 1..100) {
        if (Test-Path -LiteralPath $repairMarker) { break }
        if ($attempt -eq 100) { throw 'Background integrity audit did not request repair.' }
        Start-Sleep -Milliseconds 50
    }
    $repair = Start-Process -FilePath `
        (Join-Path $oldRuntime 'Minecraft D Edition Launcher.exe') `
        -WorkingDirectory $oldRuntime -ArgumentList '--updater-check-only' `
        -Wait -PassThru
    if ($repair.ExitCode -ne 0) { throw "Repair pass exited with $($repair.ExitCode)" }
    if ((Get-Content -Raw (Join-Path $oldRuntime 'assets\changed.txt')) -ne 'new' `
        -or (Get-Content -Raw (Join-Path $oldRuntime 'assets\added.txt')) -ne 'added') {
        throw 'A same-version integrity repair did not restore managed files.'
    }
    Write-Host 'Updater smoke test passed.'
}
finally {
    Remove-Item Env:MDE_UPDATE_ASSET_BASE_URL -ErrorAction SilentlyContinue
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) `
        -and (Split-Path -Leaf $resolvedTest).StartsWith('minecraft-d-updater-smoke-')) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force -ErrorAction SilentlyContinue
    }
}
