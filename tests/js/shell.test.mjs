import test from 'node:test';
import assert from 'node:assert/strict';

const shellModuleUrl = new URL('../../htdocs/luci-static/dashboard/shell.js', import.meta.url);

test('buildSectionState returns the expected shell defaults', async () => {
  const { buildSectionState } = await import(shellModuleUrl);

  const state = buildSectionState();

  assert.equal(state.overview.expanded, true);
  assert.equal(state.users.loaded, false);
  assert.equal(state.feature.expanded, false);
  assert.equal(state.features.expanded, false);
  assert.equal(state.feature, state.features);

  for (const sectionName of ['overview', 'users', 'network', 'system', 'records', 'features', 'settings']) {
    assert.ok(state[sectionName], `missing section state for ${sectionName}`);
    assert.equal(typeof state[sectionName].expanded, 'boolean');
    assert.equal(typeof state[sectionName].loaded, 'boolean');
    assert.equal(state[sectionName].error, null);
  }
});
