import assert from 'node:assert/strict';
import test from 'node:test';
import { normalizeSkinModel } from '../src/skin_model.ts';

test('accepts the two Java-compatible arm styles', () => {
  assert.equal(normalizeSkinModel('classic'), 'classic');
  assert.equal(normalizeSkinModel('slim'), 'slim');
});

test('rejects missing and invented player models', () => {
  assert.equal(normalizeSkinModel(undefined), null);
  assert.equal(normalizeSkinModel('wide-ish'), null);
});
