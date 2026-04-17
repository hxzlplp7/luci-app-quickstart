import test from 'node:test';
import assert from 'node:assert/strict';

const shellModuleUrl = new URL('../../htdocs/luci-static/dashboard/shell.js', import.meta.url);
const appModuleUrl = new URL('../../htdocs/luci-static/dashboard/app.js', import.meta.url);

test('buildSectionState returns the expected shell defaults', async () => {
  const { buildSectionState } = await import(shellModuleUrl);

  const state = buildSectionState();
  const expectedSectionNames = ['overview', 'users', 'network', 'system', 'record', 'feature', 'settings'];

  assert.equal(state.overview.expanded, true);
  assert.equal(state.users.loaded, false);
  assert.equal(state.feature.expanded, false);
  assert.deepEqual(Object.keys(state), expectedSectionNames);

  for (const sectionName of expectedSectionNames) {
    assert.ok(state[sectionName], `missing section state for ${sectionName}`);
    assert.equal(typeof state[sectionName].expanded, 'boolean');
    assert.equal(typeof state[sectionName].loaded, 'boolean');
    assert.equal(state[sectionName].error, null);
  }
});

test('registeredSections exposes all stage1 modules', async () => {
  const { registeredSections } = await import(appModuleUrl);

  assert.deepEqual(
    [...registeredSections].sort(),
    ['feature', 'network', 'overview', 'record', 'settings', 'system', 'users'].sort()
  );
});
