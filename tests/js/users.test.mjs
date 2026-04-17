import test from 'node:test';
import assert from 'node:assert/strict';

const usersModuleUrl = new URL('../../htdocs/luci-static/dashboard/sections-users.js', import.meta.url);
const appModuleUrl = new URL('../../htdocs/luci-static/dashboard/app.js', import.meta.url);

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

test('normalizeUsers fills list defaults and traffic defaults', async () => {
  const { normalizeUsers } = await import(usersModuleUrl);

  const payload = normalizeUsers({
    list: [
      {
        mac: 'AA:BB:CC:DD:EE:FF',
        hostname: 'phone',
      },
    ],
  });

  assert.equal(payload.page, 1);
  assert.equal(payload.page_size, 20);
  assert.equal(payload.total_num, payload.list.length);
  assert.equal(payload.list[0].mac, 'AA:BB:CC:DD:EE:FF');
  assert.equal(payload.list[0].nickname, '');
  assert.equal(payload.list[0].hostname, 'phone');
  assert.equal(payload.list[0].traffic.supported, false);
  assert.equal(payload.list[0].traffic.today_down_bytes, 0);
});

test('normalizeUserDetail fills nested defaults', async () => {
  const { normalizeUserDetail } = await import(usersModuleUrl);

  const detail = normalizeUserDetail({
    device: {
      mac: 'AA:BB:CC:DD:EE:FF',
    },
  });

  assert.equal(detail.device.mac, 'AA:BB:CC:DD:EE:FF');
  assert.equal(detail.device.nickname, '');
  assert.deepEqual(detail.recent_domains, []);
  assert.deepEqual(detail.history, []);
  assert.equal(detail.traffic.supported, false);
});

test('loadUsers requests users endpoint with paging params and normalizes payload', async () => {
  const originalFetch = globalThis.fetch;
  const restoreDocument = installDashboardApp('/proxy/base/admin/dashboard/api');
  const requests = [];

  globalThis.fetch = async (url, options = {}) => {
    requests.push({ url, options });

    return {
      ok: true,
      async json() {
        return {
          ok: true,
          data: {
            total_num: 1,
            list: [
              {
                mac: 'AA:BB:CC:DD:EE:FF',
                nickname: 'Tablet',
                traffic: {
                  supported: true,
                  today_up_bytes: 12,
                },
              },
            ],
          },
        };
      },
    };
  };

  try {
    const { loadUsers } = await import(usersModuleUrl);
    const payload = await loadUsers(3, 50);

    assert.equal(requests.length, 1);
    assert.equal(requests[0].url, '/proxy/base/admin/dashboard/api/users?page=3&page_size=50');
    assert.equal(payload.total_num, 1);
    assert.equal(payload.list[0].nickname, 'Tablet');
    assert.equal(payload.list[0].traffic.today_up_bytes, 12);
    assert.equal(payload.list[0].traffic.today_down_bytes, 0);
  } finally {
    globalThis.fetch = originalFetch;
    restoreDocument();
  }
});

test('loadUserDetail requests encoded mac detail endpoint', async () => {
  const originalFetch = globalThis.fetch;
  const restoreDocument = installDashboardApp('/proxy/base/admin/dashboard/api');
  const requests = [];

  globalThis.fetch = async (url, options = {}) => {
    requests.push({ url, options });

    return {
      ok: true,
      async json() {
        return {
          ok: true,
          data: {
            device: {
              mac: 'AA:BB:CC:DD:EE:FF',
              hostname: 'phone',
            },
          },
        };
      },
    };
  };

  try {
    const { loadUserDetail } = await import(usersModuleUrl);
    const detail = await loadUserDetail('aa:bb:cc:dd:ee:ff');

    assert.equal(requests.length, 1);
    assert.equal(requests[0].url, '/proxy/base/admin/dashboard/api/users/detail?mac=aa%3Abb%3Acc%3Add%3Aee%3Aff');
    assert.equal(detail.device.hostname, 'phone');
    assert.equal(detail.traffic.supported, false);
  } finally {
    globalThis.fetch = originalFetch;
    restoreDocument();
  }
});

test('saveUserRemark posts mac and value form fields', async () => {
  const originalFetch = globalThis.fetch;
  const restoreDocument = installDashboardApp('/proxy/base/admin/dashboard/api', 'csrf-users-1');
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
    const { saveUserRemark } = await import(usersModuleUrl);
    const payload = await saveUserRemark('AA:BB:CC:DD:EE:FF', 'Desk Phone');

    assert.equal(requests.length, 1);
    assert.equal(requests[0].url, '/proxy/base/admin/dashboard/api/users/remark');
    assert.equal(requests[0].options.method, 'POST');
    assert.equal(
      requests[0].options.headers['Content-Type'],
      'application/x-www-form-urlencoded;charset=UTF-8'
    );
    assert.equal(requests[0].options.headers['X-Dashboard-CSRF-Token'], 'csrf-users-1');
    assert.equal(requests[0].options.body, 'mac=AA%3ABB%3ACC%3ADD%3AEE%3AFF&value=Desk+Phone');
    assert.deepEqual(payload, { saved: true });
  } finally {
    globalThis.fetch = originalFetch;
    restoreDocument();
  }
});

test('applySavedRemarkResult updates only the saved target user', async () => {
  const { applySavedRemarkResult } = await import(appModuleUrl);

  const dashboard = {
    users: {
      list: [
        { mac: 'AA:AA:AA:AA:AA:AA', nickname: 'Alpha' },
        { mac: 'BB:BB:BB:BB:BB:BB', nickname: 'Beta' },
      ],
    },
    userDrawer: {
      open: true,
      mac: 'BB:BB:BB:BB:BB:BB',
      detail: {
        device: {
          mac: 'BB:BB:BB:BB:BB:BB',
          nickname: 'Beta',
        },
      },
    },
  };

  applySavedRemarkResult(dashboard, 'AA:AA:AA:AA:AA:AA', 'Updated Alpha');

  assert.equal(dashboard.users.list[0].nickname, 'Updated Alpha');
  assert.equal(dashboard.users.list[1].nickname, 'Beta');
  assert.equal(dashboard.userDrawer.detail.device.nickname, 'Beta');
});
