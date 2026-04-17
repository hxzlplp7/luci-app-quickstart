import test from 'node:test';
import assert from 'node:assert/strict';

const apiModuleUrl = new URL('../../htdocs/luci-static/dashboard/api.js', import.meta.url);

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

test('dashboardApi adds csrf token header to non-GET requests', async () => {
  const originalFetch = globalThis.fetch;
  const restoreDocument = installDashboardApp('/proxy/base/admin/dashboard/api', 'csrf-123');
  const requests = [];

  globalThis.fetch = async (url, options = {}) => {
    requests.push({ url, options });
    return {
      ok: true,
      async json() {
        return {
          ok: true,
          data: {
            saved: true,
          },
        };
      },
    };
  };

  try {
    const { dashboardApi } = await import(apiModuleUrl);
    const payload = await dashboardApi('/users/remark', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
      },
      body: 'mac=AA&value=Desk',
    });

    assert.equal(requests.length, 1);
    assert.equal(requests[0].options.headers['X-Dashboard-CSRF-Token'], 'csrf-123');
    assert.deepEqual(payload, { saved: true });
  } finally {
    globalThis.fetch = originalFetch;
    restoreDocument();
  }
});

test('dashboardApi does not attach csrf token header to GET requests', async () => {
  const originalFetch = globalThis.fetch;
  const restoreDocument = installDashboardApp('/proxy/base/admin/dashboard/api', 'csrf-456');
  const requests = [];

  globalThis.fetch = async (url, options = {}) => {
    requests.push({ url, options });
    return {
      ok: true,
      async json() {
        return {
          ok: true,
          data: {
            ok: true,
          },
        };
      },
    };
  };

  try {
    const { dashboardApi } = await import(apiModuleUrl);
    await dashboardApi('/overview');

    assert.equal(requests.length, 1);
    assert.equal(requests[0].options.headers['X-Dashboard-CSRF-Token'], undefined);
  } finally {
    globalThis.fetch = originalFetch;
    restoreDocument();
  }
});
