/// D1 stores JavaScript ArrayBuffers as SQLite BLOBs, but reads BLOB columns
/// back as number arrays. Keep the conversion at the HTTP boundary so a
/// successful skin response can never silently contain an empty body.
export function d1BlobBytes(value: unknown): Uint8Array | null {
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (ArrayBuffer.isView(value))
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  if (!Array.isArray(value) || value.length === 0) return null;
  if (!value.every((byte) => Number.isInteger(byte) && byte >= 0 && byte <= 255))
    return null;
  return Uint8Array.from(value);
}
