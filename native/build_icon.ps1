$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$sourcePng = Join-Path $PSScriptRoot '..\assets\minecraft_d\textures\gui\title\mcde_logo.png'
$iconPath = Join-Path $PSScriptRoot 'minecraft_d_edition.ico'
$resourceScript = Join-Path $PSScriptRoot 'app_icon.rc'
$resourceOutput = Join-Path $PSScriptRoot 'app_icon.res'

if (-not (Test-Path -LiteralPath $sourcePng)) {
    throw "Application logo was not found: $sourcePng"
}

$sourceImage = [System.Drawing.Image]::FromFile($sourcePng)
try {
    $sizes = @(16, 24, 32, 48, 64, 128, 256)
    $payloads = [System.Collections.Generic.List[byte[]]]::new()
    foreach ($size in $sizes) {
        $bitmap = [System.Drawing.Bitmap]::new($size, $size,
            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.Clear([System.Drawing.Color]::Transparent)
                $graphics.InterpolationMode =
                    [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
                $graphics.PixelOffsetMode =
                    [System.Drawing.Drawing2D.PixelOffsetMode]::Half
                $graphics.DrawImage($sourceImage, 0, 0, $size, $size)
            }
            finally { $graphics.Dispose() }
            $stream = [System.IO.MemoryStream]::new()
            try {
                $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
                $payloads.Add($stream.ToArray())
            }
            finally { $stream.Dispose() }
        }
        finally { $bitmap.Dispose() }
    }

    $file = [System.IO.File]::Create($iconPath)
    $writer = [System.IO.BinaryWriter]::new($file)
    try {
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($index = 0; $index -lt $sizes.Count; ++$index) {
            $size = $sizes[$index]
            $writer.Write([byte]$(if ($size -eq 256) { 0 } else { $size }))
            $writer.Write([byte]$(if ($size -eq 256) { 0 } else { $size }))
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]32)
            $writer.Write([uint32]$payloads[$index].Length)
            $writer.Write([uint32]$offset)
            $offset += $payloads[$index].Length
        }
        foreach ($payload in $payloads) { $writer.Write($payload) }
    }
    finally {
        $writer.Dispose()
        $file.Dispose()
    }
}
finally { $sourceImage.Dispose() }

$kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$resourceCompiler = Get-ChildItem $kitsRoot -Filter rc.exe -Recurse |
    Where-Object { $_.FullName -match '\\x64\\rc\.exe$' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1
if (-not $resourceCompiler) { throw 'The Windows resource compiler was not found.' }

& $resourceCompiler.FullName /nologo /fo $resourceOutput $resourceScript
if ($LASTEXITCODE -ne 0) {
    throw "Windows icon resource compilation failed with exit code $LASTEXITCODE"
}
