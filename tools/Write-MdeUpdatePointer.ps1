param(
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$Version
)

$ErrorActionPreference = 'Stop'
$manifest = Get-Item -LiteralPath ([IO.Path]::GetFullPath($ManifestPath))
$output = [IO.Path]::GetFullPath($OutputPath)
if ($Version -match "[`r`n`t]") { throw 'Version may not contain tabs or line breaks.' }
$hash = (Get-FileHash -LiteralPath $manifest.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$lines = @(
    "MDE-UPDATE-POINTER`t1",
    "version`t$Version",
    "manifest`t$($manifest.Name)",
    "size`t$($manifest.Length)",
    "sha256`t$hash"
)
[IO.File]::WriteAllText($output, ($lines -join "`n") + "`n",
    [Text.UTF8Encoding]::new($false))
