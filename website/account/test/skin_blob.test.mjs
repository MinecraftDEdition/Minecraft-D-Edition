import assert from 'node:assert/strict';
import test from 'node:test';
import { d1BlobBytes } from '../src/skin_blob.ts';

test('converts the number arrays returned for D1 BLOB columns', () => {
  assert.deepEqual([...d1BlobBytes([137, 80, 78, 71])], [137, 80, 78, 71]);
});

test('preserves ArrayBuffer and typed-array inputs', () => {
  assert.deepEqual([...d1BlobBytes(Uint8Array.from([1, 2, 3]).buffer)], [1, 2, 3]);
  assert.deepEqual([...d1BlobBytes(Uint8Array.from([4, 5, 6]))], [4, 5, 6]);
});

test('rejects empty and malformed BLOB values', () => {
  assert.equal(d1BlobBytes([]), null);
  assert.equal(d1BlobBytes([1, 300]), null);
  assert.equal(d1BlobBytes('not a blob'), null);
});
