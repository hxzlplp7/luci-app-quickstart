import test from 'node:test';
import assert from 'node:assert/strict';

const shellModuleUrl = new URL('../../htdocs/luci-static/dashboard/shell.js', import.meta.url);
const appModuleUrl = new URL('../../htdocs/luci-static/dashboard/app.js', import.meta.url);

test('buildSectionState returns the expected shell defaults', async () => {
  const { buildSectionState } = await import(shellModuleUrl);

  const state = buildSectionState();
  const expectedSectionNames = ['overview'];

  assert.equal(state.overview.expanded, true);
  assert.deepEqual(Object.keys(state), expectedSectionNames);

  for (const sectionName of expectedSectionNames) {
    assert.ok(state[sectionName], `missing section state for ${sectionName}`);
    assert.equal(typeof state[sectionName].expanded, 'boolean');
    assert.equal(typeof state[sectionName].loaded, 'boolean');
    assert.equal(state[sectionName].error, null);
  }
});

test('registeredSections exposes only the homepage overview section', async () => {
  const { registeredSections } = await import(appModuleUrl);

  assert.deepEqual([...registeredSections], ['overview']);
});
