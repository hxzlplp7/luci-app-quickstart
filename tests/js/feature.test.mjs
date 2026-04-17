import test from 'node:test';
import assert from 'node:assert/strict';

const moduleUrl = new URL('../../htdocs/luci-static/dashboard/sections-feature.js', import.meta.url);

function installDashboardApp(apiBase, sessionToken = '') {
  const originalDocument = globalThis.document;

  globalThis.document = {
    getElementById(id) {
      if (id === 'dashboard-app') {
        return {
          dataset: {
            apiBase,
            sessionToken,
          },
        };
      }

      return null;
    },
  };

  return () => {
    if (typeof originalDocument === 'undefined') {
      delete globalThis.document;
      return;
    }

    globalThis.document = originalDocument;
  };
}

test('feature section helpers target expected endpoints', async () => {
  const originalFetch = globalThis.fetch;
  const restoreDocument = installDashboardApp('/proxy/base/admin/dashboard/api', 'csrf-token');
  const requests = [];

  globalThis.fetch = async (url, options = {}) => {
    requests.push({ url, options });
    return {
      ok: true,
      async json() {
        return {
          ok: true,
          data: {
            version: '2026.04.16',
            format: 'v3.0',
            app_count: 12,
            state: 'idle',
          },
        };
      },
    };
  };

  try {
    const { loadFeatureInfo, loadFeatureClasses, uploadFeatureBundle } = await import(moduleUrl);
    const fakeFile = { name: 'feature-pack.tar.gz' };

    await loadFeatureInfo();
    await loadFeatureClasses();
    await uploadFeatureBundle(fakeFile);

    assert.equal(requests[0].url, '/proxy/base/admin/dashboard/api/feature/info');
    assert.equal(requests[0].options.method, 'GET');

    assert.equal(requests[1].url, '/proxy/base/admin/dashboard/api/feature/classes');
    assert.equal(requests[1].options.method, 'GET');

    assert.equal(requests[2].url, '/proxy/base/admin/dashboard/api/feature/upload');
    assert.equal(requests[2].options.method, 'POST');
    assert.equal(requests[2].options.headers['X-Dashboard-CSRF-Token'], 'csrf-token');
    assert.ok(requests[2].options.body instanceof FormData, 'feature upload should use FormData');
  } finally {
    globalThis.fetch = originalFetch;
    restoreDocument();
  }
});
