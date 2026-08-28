param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Tag = 'Test'
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$dist = Join-Path $ProjectRoot 'dist'
$updates = Join-Path $dist 'updates'
$manifest = Join-Path $updates 'mde-update-manifest-v1.txt'
$pointer = Join-Path $updates 'mde-update-pointer-v1.txt'
$installer = Join-Path $dist 'Minecraft.D.Edition.Setup.exe'
foreach ($file in @($manifest, $pointer, $installer)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Distribution asset is missing: $file"
    }
}
if (-not (Get-Command gh.exe -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required to publish the release.'
}
& gh auth status
if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated.' }

$repository = 'MinecraftDEdition/Minecraft-D-Edition'
$newShards = @(Get-ChildItem -LiteralPath $updates -Filter 'mde-shard-*.zip' -File)
if ($newShards.Count -eq 0) { throw 'No update shards were produced.' }

$existingJson = & gh api "repos/$repository/releases/tags/$Tag"
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the existing release assets.' }
$existing = $existingJson | ConvertFrom-Json
$existingNames = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
foreach ($asset in $existing.assets) { [void]$existingNames.Add($asset.name) }
$shardsToUpload = @($newShards | Where-Object {
    -not $existingNames.Contains($_.Name)
})

# Upload content-addressed shards first. The pointer is deliberately after the
# manifest, and the public web installer is last, so new users cannot observe
# references to absent assets.
Write-Host ("Reusing {0} unchanged shards; uploading {1} changed shards." -f `
    ($newShards.Count - $shardsToUpload.Count), $shardsToUpload.Count)
foreach ($asset in $shardsToUpload) {
    & gh release upload $Tag $asset.FullName --repo $repository
    if ($LASTEXITCODE -ne 0) { throw "Failed to upload $($asset.Name)" }
}
& gh release upload $Tag $manifest --repo $repository --clobber
if ($LASTEXITCODE -ne 0) { throw 'Failed to publish the update manifest.' }
& gh release upload $Tag $pointer --repo $repository --clobber
if ($LASTEXITCODE -ne 0) { throw 'Failed to publish the update pointer.' }
& gh release upload $Tag $installer --repo $repository --clobber
if ($LASTEXITCODE -ne 0) { throw 'Failed to publish the web installer.' }

# Remove shards no longer referenced by the newly published manifest. A client
# interrupted in the narrow publication window simply retries with the current
# manifest on its next launch.
$keep = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($asset in $newShards) { [void]$keep.Add($asset.Name) }
$existingJson = & gh api "repos/$repository/releases/tags/$Tag"
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect published release assets.' }
$existing = $existingJson | ConvertFrom-Json
foreach ($asset in $existing.assets) {
    if ($asset.name -like 'mde-shard-*.zip' -and -not $keep.Contains($asset.name)) {
        & gh api --method DELETE "repos/$repository/releases/assets/$($asset.id)"
        if ($LASTEXITCODE -ne 0) { throw "Failed to remove obsolete shard $($asset.name)" }
    }
    if ($asset.name -eq 'Minecraft.D.Edition.zip') {
        & gh api --method DELETE "repos/$repository/releases/assets/$($asset.id)"
        if ($LASTEXITCODE -ne 0) { throw 'Failed to remove the legacy monolithic ZIP.' }
    }
}

Write-Host "Published installer and differential update feed to release $Tag."
