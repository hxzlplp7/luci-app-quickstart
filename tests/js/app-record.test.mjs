import test from 'node:test';
import assert from 'node:assert/strict';

const appModuleUrl = new URL('../../htdocs/luci-static/dashboard/app.js', import.meta.url);

function createSectionElement() {
  return {
    innerHTML: '',
    querySelector() {
      return null;
    },
    querySelectorAll() {
      return [];
    },
  };
}

function installDashboardDom() {
  const originalDocument = globalThis.document;
  const originalWindow = globalThis.window;
  const sections = {
    overview: createSectionElement(),
  };

  globalThis.document = {
    getElementById(id) {
      if (id === 'dashboard-app') {
        return {
          dataset: {
            apiBase: '/proxy/base/admin/dashboard/api',
            sessionToken: 'csrf-token',
          },
        };
      }

      return null;
    },
    querySelector(selector) {
      const match = selector.match(/^\[data-section="([^"]+)"\]$/);
      if (match) {
        return sections[match[1]] || null;
      }

      return null;
    },
  };

  globalThis.window = {};

  return {
    sections,
    restore() {
      if (typeof originalDocument === 'undefined') {
        delete globalThis.document;
      } else {
        globalThis.document = originalDocument;
      }

      if (typeof originalWindow === 'undefined') {
        delete globalThis.window;
      } else {
        globalThis.window = originalWindow;
      }
    },
  };
}

test('app bootstrap renders the homepage dashboard without stage1 placeholder panels', async () => {
  const originalFetch = globalThis.fetch;
  const { sections, restore } = installDashboardDom();
  const requests = [];

  globalThis.fetch = async (url) => {
    requests.push(url);

    if (url.endsWith('/overview')) {
      return {
        ok: true,
        async json() {
          return {
            ok: true,
            data: {
              system: {
                model: 'FriendlyWrt R4S',
                firmware: '25.12.0',
                kernel: '6.12.71',
                uptime_raw: 3605,
                cpuUsage: 18,
                memUsage: 42,
                temp: 58,
              },
              network: {
                wanStatus: 'up',
                wanIp: '10.0.0.2',
                lanIp: '192.168.100.1',
                dns: ['223.5.5.5', '119.29.29.29'],
              },
              traffic: {
                rx_bytes: 2147483648,
                tx_bytes: 536870912,
              },
              devices: [
                { mac: 'AA:AA:AA:AA:AA:AA' },
                { mac: 'BB:BB:BB:BB:BB:BB' },
                { mac: 'CC:CC:CC:CC:CC:CC' },
              ],
              domains: {
                top: [
                  { domain: 'openwrt.org', count: 12 },
                  { domain: 'github.com', count: 8 },
                  { domain: 'bilibili.com', count: 5 },
                ],
                recent: [
                  { domain: 'downloads.openwrt.org', count: 1 },
                  { domain: 'api.github.com', count: 1 },
                ],
              },
              capabilities: {
                nlbwmon: true,
                domain_logs: true,
                feature_library: false,
                history_store: true,
              },
            },
          };
        },
      };
    }

    if (url.includes('/users?')) {
      return {
        ok: true,
        async json() {
          return {
            ok: true,
            data: {
              total_num: 3,
              list: [
                {
                  mac: 'AA:AA:AA:AA:AA:AA',
                  nickname: 'OpenWrt-PC',
                  traffic: {
                    today_down_bytes: 2147483648,
                    today_up_bytes: 134217728,
                  },
                },
                {
                  mac: 'BB:BB:BB:BB:BB:BB',
                  hostname: 'DEV-WIFI',
                  traffic: {
                    today_down_bytes: 1073741824,
                    today_up_bytes: 67108864,
                  },
                },
                {
                  mac: 'CC:CC:CC:CC:CC:CC',
                  hostname: 'Phone',
                  traffic: {
                    today_down_bytes: 268435456,
                    today_up_bytes: 16777216,
                  },
                },
              ],
            },
          };
        },
      };
    }

    throw new Error(`Unexpected URL: ${url}`);
  };

  try {
    await import(appModuleUrl);
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.deepEqual(requests, [
      '/proxy/base/admin/dashboard/api/overview',
      '/proxy/base/admin/dashboard/api/users?page=1&page_size=20',
    ]);
    assert.match(sections.overview.innerHTML, /dashboard-home/);
    assert.match(sections.overview.innerHTML, /终端流量排行/);
    assert.match(sections.overview.innerHTML, /活跃域名/);
    assert.match(sections.overview.innerHTML, /系统信息/);
    assert.doesNotMatch(sections.overview.innerHTML, /Pending integration/);
    assert.doesNotMatch(sections.overview.innerHTML, /Save Settings/);
    assert.doesNotMatch(sections.overview.innerHTML, /Clear History/);
  } finally {
    globalThis.fetch = originalFetch;
    restore();
  }
});
