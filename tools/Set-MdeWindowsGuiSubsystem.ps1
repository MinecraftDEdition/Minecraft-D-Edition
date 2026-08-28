param(
    [Parameter(Mandatory = $true)][string]$Path
)

$ErrorActionPreference = 'Stop'
$resolved = (Resolve-Path -LiteralPath $Path).Path
$bytes = [IO.File]::ReadAllBytes($resolved)

if ($bytes.Length -lt 256 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
    throw "Not a valid Windows PE executable: $resolved"
}

$peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
if ($peOffset -lt 0 -or ($peOffset + 96) -gt $bytes.Length -or
    $bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45 -or
    $bytes[$peOffset + 2] -ne 0 -or $bytes[$peOffset + 3] -ne 0) {
    throw "The executable has an invalid PE header: $resolved"
}

# IMAGE_OPTIONAL_HEADER.Subsystem is a 16-bit field at offset 68 in both
# PE32 and PE32+ optional headers. IMAGE_SUBSYSTEM_WINDOWS_GUI is 2.
$optionalHeader = $peOffset + 24
$magic = [BitConverter]::ToUInt16($bytes, $optionalHeader)
if ($magic -ne 0x10b -and $magic -ne 0x20b) {
    throw "Unsupported PE optional-header format 0x$($magic.ToString('x'))"
}
$subsystemOffset = $optionalHeader + 68
$bytes[$subsystemOffset] = 2
$bytes[$subsystemOffset + 1] = 0
[IO.File]::WriteAllBytes($resolved, $bytes)

$writtenSubsystem = [BitConverter]::ToUInt16(
    [IO.File]::ReadAllBytes($resolved), $subsystemOffset)
if ($writtenSubsystem -ne 2) {
    throw "Could not mark the executable as a Windows GUI application: $resolved"
}

Write-Host "Marked as Windows GUI (no console window): $resolved"
