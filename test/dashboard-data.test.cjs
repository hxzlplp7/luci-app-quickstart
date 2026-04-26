const test = require('node:test');
const assert = require('node:assert/strict');

const helpers = require('../htdocs/luci-static/dashboard/dashboard-data.js');

test('prefers databus active apps when available', () => {
    const state = helpers.pickActiveAppState({
        online_apps: {
            total: 2,
            list: [
                { name: 'Microsoft', source: 'domain-heuristic' },
                { name: 'Google', source: 'domain-heuristic' },
            ],
        },
        app_recognition: {
            available: true,
            source: 'domain-heuristic',
            engine: 'domain-heuristic',
            class_stats: [{ name: 'cloud', time: 9 }],
        },
    }, {
        active_apps: [],
        class_stats: [],
    });

    assert.equal(state.apps.length, 2);
    assert.equal(state.apps[0].name, 'Microsoft');
    assert.equal(state.classStats[0].name, 'cloud');
    assert.equal(state.source, 'domain-heuristic');
});

test('falls back to oaf payload when databus has no active apps', () => {
    const state = helpers.pickActiveAppState({
        online_apps: { total: 0, list: [] },
        app_recognition: {
            available: false,
            source: 'none',
            engine: '',
            class_stats: [],
        },
    }, {
        active_apps: [{ name: 'WeChat', source: 'oaf' }],
        class_stats: [{ name: 'social', time: 5 }],
        active_source: 'oaf',
        engine: 'OpenAppFilter',
    });

    assert.equal(state.apps.length, 1);
    assert.equal(state.apps[0].name, 'WeChat');
    assert.equal(state.classStats[0].name, 'social');
    assert.equal(state.source, 'oaf');
});

test('uses backend rates when present', () => {
    const sample = helpers.deriveTrafficSnapshot({
        interface: 'eth0',
        tx_bytes: 5000,
        rx_bytes: 7000,
        tx_rate: 123,
        rx_rate: 456,
    }, null, 2000);

    assert.equal(sample.txRate, 123);
    assert.equal(sample.rxRate, 456);
    assert.equal(sample.nextState.tx_bytes, 5000);
    assert.equal(sample.nextState.interface, 'eth0');
});

test('computes fallback rates from byte deltas when backend rate is absent', () => {
    const previous = { interface: 'eth0', tx_bytes: 1000, rx_bytes: 2000, at: 1000 };
    const sample = helpers.deriveTrafficSnapshot({
        interface: 'eth0',
        tx_bytes: 1600,
        rx_bytes: 3200,
    }, previous, 3000);

    assert.equal(sample.txRate, 300);
    assert.equal(sample.rxRate, 600);
});

test('resets rates on interface switch to avoid bogus spikes', () => {
    const previous = { interface: 'eth0', tx_bytes: 1000, rx_bytes: 2000, at: 1000 };
    const sample = helpers.deriveTrafficSnapshot({
        interface: 'wwan0',
        tx_bytes: 200,
        rx_bytes: 300,
    }, previous, 3000);

    assert.equal(sample.txRate, 0);
    assert.equal(sample.rxRate, 0);
    assert.equal(sample.nextState.interface, 'wwan0');
});

test('filters non-domain tokens from domain rows', () => {
    const rows = helpers.filterDomainRows([
        { domain: '8.0mb', count: 3188 },
        { domain: '12.627884932z', count: 1 },
        { domain: '4.523234ms', count: 1 },
        { domain: 'analytics.apis.mcafee.com', count: 5 },
        { domain: 'www.msftconnecttest.com', count: 28 },
        { domain: '127.0.0.1', count: 3 },
    ]);

    assert.deepEqual(rows.map((item) => item.domain), [
        'analytics.apis.mcafee.com',
        'www.msftconnecttest.com',
    ]);
});

test('accepts common and punycode domain shapes', () => {
    assert.equal(helpers.isLikelyDomain('chatgpt.com'), true);
    assert.equal(helpers.isLikelyDomain('xn--fiqs8s.cn'), true);
    assert.equal(helpers.isLikelyDomain('edge.microsoft.com'), true);
});
