import test from 'node:test';
import assert from 'node:assert/strict';
import { compareVersions, findUpgrade } from '../scripts/check-installer-release.mjs';

const release = (tag_name, overrides = {}) => ({ tag_name, draft: false, prerelease: false, published_at: '2026-11-08T00:00:00Z', ...overrides });

test('discovers v1.2.6 from the current v1.2.5 baseline', () => {
  assert.equal(findUpgrade([release('v1.2.5'), release('v1.2.6')], 'v1.2.5').tag_name, 'v1.2.6');
});

test('selects the highest stable version regardless of API or publication order', () => {
  const releases = [release('v1.2.9'), release('v1.2.10'), release('v1.2.6')];
  assert.equal(findUpgrade(releases, 'v1.2.5').tag_name, 'v1.2.10');
  assert.equal(findUpgrade(releases.reverse(), 'v1.2.5').tag_name, 'v1.2.10');
  assert.equal(compareVersions('v2.0.0', 'v1.99.99'), 1);
});

test('drafts, previews, unpublished releases and non-version tags cannot be promoted', () => {
  assert.equal(findUpgrade([
    release('v1.2.7', { draft: true }), release('v1.2.8', { prerelease: true }),
    release('v1.2.9', { published_at: null }), release('v2.0.0-rc.1'), release('main'),
  ], 'v1.2.5'), null);
});

test('unchanged or older upstream releases are a no-op, while a later release still upgrades', () => {
  assert.equal(findUpgrade([release('v1.2.6'), release('v1.2.5')], 'v1.2.6'), null);
  assert.equal(findUpgrade([release('v1.2.5')], 'v1.2.6'), null);
  assert.equal(findUpgrade([], 'v1.2.6'), null);
  assert.equal(findUpgrade([release('v1.2.6'), release('v1.2.7')], 'v1.2.6').tag_name, 'v1.2.7');
  assert.throws(() => findUpgrade([], 'latest'), /Invalid stable version/);
});
