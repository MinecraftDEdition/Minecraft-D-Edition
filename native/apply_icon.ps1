param(
    [Parameter(Mandatory = $true)]
    [string[]] $Executable
)

$ErrorActionPreference = 'Stop'
$iconPath = Join-Path $PSScriptRoot 'minecraft_d_edition.ico'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public static class ExecutableIconResource {
    private struct IconEntry {
        public byte Width, Height, ColorCount, Reserved;
        public ushort Planes, BitCount;
        public uint Bytes, Offset;
    }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr BeginUpdateResource(string file, bool deleteExisting);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateResource(IntPtr update, IntPtr type,
        IntPtr name, ushort language, byte[] data, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool EndUpdateResource(IntPtr update, bool discard);

    private static IntPtr Id(int value) { return new IntPtr(value); }

    public static void Apply(string executable, string iconFile) {
        byte[] ico = File.ReadAllBytes(iconFile);
        using (var reader = new BinaryReader(new MemoryStream(ico))) {
            if (reader.ReadUInt16() != 0 || reader.ReadUInt16() != 1)
                throw new InvalidDataException("Not a Windows icon file.");
            ushort count = reader.ReadUInt16();
            var entries = new List<IconEntry>();
            for (int i = 0; i < count; ++i) {
                IconEntry entry = new IconEntry();
                entry.Width = reader.ReadByte(); entry.Height = reader.ReadByte();
                entry.ColorCount = reader.ReadByte(); entry.Reserved = reader.ReadByte();
                entry.Planes = reader.ReadUInt16(); entry.BitCount = reader.ReadUInt16();
                entry.Bytes = reader.ReadUInt32(); entry.Offset = reader.ReadUInt32();
                entries.Add(entry);
            }

            IntPtr handle = BeginUpdateResource(executable, false);
            if (handle == IntPtr.Zero)
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            bool success = false;
            try {
                var groupStream = new MemoryStream();
                using (var group = new BinaryWriter(groupStream, System.Text.Encoding.UTF8, true)) {
                    group.Write((ushort)0); group.Write((ushort)1); group.Write(count);
                    for (int i = 0; i < entries.Count; ++i) {
                        var entry = entries[i];
                        byte[] image = new byte[entry.Bytes];
                        Buffer.BlockCopy(ico, (int)entry.Offset, image, 0, image.Length);
                        int imageId = 201 + i;
                        if (!UpdateResource(handle, Id(3), Id(imageId), 0,
                            image, (uint)image.Length))
                            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                        group.Write(entry.Width); group.Write(entry.Height);
                        group.Write(entry.ColorCount); group.Write(entry.Reserved);
                        group.Write(entry.Planes); group.Write(entry.BitCount);
                        group.Write(entry.Bytes); group.Write((ushort)imageId);
                    }
                }
                byte[] groupData = groupStream.ToArray();
                if (!UpdateResource(handle, Id(14), Id(101), 0,
                    groupData, (uint)groupData.Length))
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                success = true;
            }
            finally {
                if (!EndUpdateResource(handle, !success))
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
        }
    }
}
'@

foreach ($path in $Executable) {
    $resolved = (Resolve-Path -LiteralPath $path).Path
    [ExecutableIconResource]::Apply($resolved, $iconPath)
}
