$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$id = [Guid]::NewGuid().ToString('N')
$testInstall = Join-Path ([IO.Path]::GetTempPath()) ('minecraft-d-web-install-' + $id)
$feedRuntime = Join-Path ([IO.Path]::GetTempPath()) ('minecraft-d-web-runtime-' + $id)
$feedOutput = Join-Path ([IO.Path]::GetTempPath()) ('minecraft-d-web-feed-' + $id)
$server = $null

function Assert-SafeTemporaryPath([string]$Path, [string]$Prefix) {
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($temporaryRoot,
            [StringComparison]::OrdinalIgnoreCase) -or
        -not (Split-Path -Leaf $resolved).StartsWith($Prefix)) {
        throw "Unsafe installer smoke-test path: $resolved"
    }
}

function Write-Utf8([string]$Path, [string]$Value) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

Assert-SafeTemporaryPath $testInstall 'minecraft-d-web-install-'
Assert-SafeTemporaryPath $feedRuntime 'minecraft-d-web-runtime-'
Assert-SafeTemporaryPath $feedOutput 'minecraft-d-web-feed-'
$setup = Join-Path $projectRoot 'dist\Minecraft.D.Edition.Setup.exe'

try {
    New-Item -ItemType Directory -Path $feedRuntime | Out-Null
    Write-Utf8 (Join-Path $feedRuntime 'Minecraft D Edition.exe') 'web-game'
    Write-Utf8 (Join-Path $feedRuntime 'assets\installed-from-github.txt') `
        'downloaded-content'
    & (Join-Path $projectRoot 'tools\New-MdeUpdatePackage.ps1') `
        -RuntimeRoot $feedRuntime -OutputRoot $feedOutput -Version 'web-smoke' `
        -ChunkCount 4 | Out-Null

    $python = (Get-Command python.exe -ErrorAction Stop).Source
    $port = Get-Random -Minimum 41000 -Maximum 49000
    $server = Start-Process -FilePath $python -WindowStyle Hidden -PassThru `
        -WorkingDirectory $feedOutput -ArgumentList @('-m','http.server',$port,
            '--bind','127.0.0.1')
    $baseUrl = "http://127.0.0.1:$port"
    foreach ($attempt in 1..30) {
        try {
            Invoke-WebRequest -UseBasicParsing `
                "$baseUrl/mde-update-pointer-v1.txt" | Out-Null
            break
        }
        catch {
            if ($attempt -eq 30) { throw }
            Start-Sleep -Milliseconds 100
        }
    }

    $install = Start-Process -FilePath $setup -ArgumentList @(
        '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/NOICONS',
        ('/DIR=' + $testInstall)) -Wait -PassThru
    if ($install.ExitCode -ne 0) {
        throw "Installer exited with $($install.ExitCode)"
    }
    if (-not (Test-Path -LiteralPath `
        (Join-Path $testInstall 'Minecraft D Edition Launcher.exe'))) {
        throw 'Web installer did not install the launcher.'
    }
    if (Test-Path -LiteralPath (Join-Path $testInstall 'Minecraft D Edition.exe')) {
        throw 'Web installer unexpectedly embedded the game executable.'
    }

    $env:MDE_UPDATE_ASSET_BASE_URL = $baseUrl
    $check = Start-Process -FilePath `
        (Join-Path $testInstall 'Minecraft D Edition Launcher.exe') `
        -WorkingDirectory $testInstall -ArgumentList '--updater-check-only' `
        -Wait -PassThru
    if ($check.ExitCode -ne 0) {
        throw "Installed launcher exited with $($check.ExitCode)"
    }
    if ((Get-Content -Raw (Join-Path $testInstall 'Minecraft D Edition.exe')) `
        -ne 'web-game') {
        throw 'Launcher did not install the game from the web feed.'
    }
    if ((Get-Content -Raw `
        (Join-Path $testInstall 'assets\installed-from-github.txt')) `
        -ne 'downloaded-content') {
        throw 'Launcher did not extract downloaded content into real files.'
    }

    $uninstaller = Join-Path $testInstall 'unins000.exe'
    $uninstall = Start-Process -FilePath $uninstaller -ArgumentList @(
        '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') -Wait -PassThru
    if ($uninstall.ExitCode -ne 0) {
        throw "Uninstaller exited with $($uninstall.ExitCode)"
    }
    [pscustomobject]@{
        WebSetupBytes = (Get-Item -LiteralPath $setup).Length
        DownloadedRealFiles = 2
        RemovedCleanly = -not (Test-Path -LiteralPath $testInstall)
    } | Format-List
}
finally {
    Remove-Item Env:MDE_UPDATE_ASSET_BASE_URL -ErrorAction SilentlyContinue
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    foreach ($path in @($testInstall,$feedRuntime,$feedOutput)) {
        if (Test-Path -LiteralPath $path) {
            Assert-SafeTemporaryPath $path 'minecraft-d-web-'
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}
