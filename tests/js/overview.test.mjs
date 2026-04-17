import test from 'node:test';
import assert from 'node:assert/strict';

const overviewModuleUrl = new URL('../../htdocs/luci-static/dashboard/sections-overview.js', import.meta.url);

test('normalizeOverview fills missing nested defaults', async () => {
  const { normalizeOverview } = await import(overviewModuleUrl);

  const overview = normalizeOverview({
    system: { hostname: 'router' },
  });

  assert.equal(overview.system.hostname, 'router');
  assert.deepEqual(overview.network.dns, []);
  assert.equal(overview.capabilities.nlbwmon, false);
});

test('loadOverview requests overview endpoint and returns normalized data', async () => {
  const originalFetch = globalThis.fetch;
  const requests = [];

  globalThis.fetch = async (url, options = {}) => {
    requests.push({ url, options });

    return {
      ok: true,
      async json() {
        return {
          ok: true,
          data: {
            system: { hostname: 'edge-router' },
            network: {},
          },
        };
      },
    };
  };

  try {
    const { loadOverview } = await import(overviewModuleUrl);
    const overview = await loadOverview();

    assert.equal(requests.length, 1);
    assert.equal(requests[0].url, '/cgi-bin/luci/admin/dashboard/api/overview');
    assert.equal(requests[0].options.credentials, 'same-origin');
    assert.equal(requests[0].options.headers.Accept, 'application/json');
    assert.equal(overview.system.hostname, 'edge-router');
    assert.deepEqual(overview.network.dns, []);
    assert.equal(overview.capabilities.nlbwmon, false);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
