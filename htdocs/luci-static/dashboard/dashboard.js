(function(window, document) {
    'use strict';

    const rawPath = window.location.pathname.replace(/\/api(\/.*)?$/, '');
    const pathMatch = rawPath.match(/(.+\/admin\/dashboard)/);
    const API_BASE = pathMatch ? pathMatch[1] + '/api' : '';
    const API_OAF = API_BASE ? API_BASE + '/oaf' : '';
    const LUCI_TOKEN = (window.L && L.env && L.env.token) ? L.env.token : '';

    const MAX_TRAFFIC_POINTS = 50;
    const RING_CIRCUMFERENCE = 213.63;
    const OAF_MAX_SIZE = 32 * 1024 * 1024;
    const DOMAIN_REFRESH_INTERVAL = 5000;
    const DOMAIN_MAX_ROWS = 20;
    const CHART_TEXT_COLOR = '#5f6b7a';
    const CHART_GRID_COLOR = 'rgba(64, 89, 124, 0.18)';
    const BYTE_UNITS = ['B', 'KB', 'MB', 'GB', 'TB'];
    const I18N = Object.assign({
        uploadLabel: 'Upload',
        downloadLabel: 'Download',
        unknown: 'Unknown',
        online: 'Online',
        offline: 'Offline',
        noOnlineDeviceData: 'No online device data',
        noDomainActivity: 'No domain activity',
        noActiveAppData: 'No active app data',
        unavailable: 'Unavailable',
        updateFeatureLibrary: 'Update Feature Library',
        uploading: 'Uploading...',
        updateSuccess: 'Update Success',
        uploadFailed: 'Upload failed',
        unknownError: 'Unknown error',
        networkErrorWhileUploading: 'Network error while uploading.',
        fileTooLarge: 'File is too large (max 32MB).',
        unsupportedFileType: 'Unsupported file type. Use .bin or .zip',
        reasonRouteIp: 'Route + IP',
        reasonDefaultRoute: 'Default Route',
        reasonIpPresent: 'IP Present',
        reasonProbeOk: 'Probe Succeeded',
        reasonNoRouteNoIp: 'No Route / No IP',
        reasonFallback: 'Fallback',
        shortDay: 'd',
        shortHour: 'h',
        shortMinute: 'm'
    }, window.DASH_I18N || {});
    const ONLINE_REASON_MAP = {
        'route+ip': I18N.reasonRouteIp,
        'route-tip': I18N.reasonRouteIp,
        'default-route': I18N.reasonDefaultRoute,
        'ip-present': I18N.reasonIpPresent,
        'ip-tip': I18N.reasonIpPresent,
        'probe-ok': I18N.reasonProbeOk,
        'no-route-no-ip': I18N.reasonNoRouteNoIp,
        fallback: I18N.reasonFallback
    };

    let trafficChart = null;
    let appUsageChart = null;
    const trafficUp = [];
    const trafficDown = [];
    const trafficLabels = [];
    let domainRequestInFlight = false;
    let prevTx = 0;
    let prevRx = 0;
    let prevAt = 0;

    function byId(id) {
        return document.getElementById(id);
    }

    function setText(id, value) {
        const el = byId(id);
        if (el) {
            el.textContent = (value === undefined || value === null || value === '') ? '-' : String(value);
        }
    }

    function escapeHtml(str) {
        if (!str) {
            return '';
        }
        const div = document.createElement('div');
        div.textContent = str;
        return div.innerHTML;
    }

    function clamp(value, min, max) {
        return Math.max(min, Math.min(max, value));
    }

    function formatBytes(bytes) {
        const num = Number(bytes);
        if (!Number.isFinite(num) || num <= 0) {
            return `0 ${BYTE_UNITS[0]}`;
        }
        const idxRaw = Math.floor(Math.log(num) / Math.log(1024));
        const idx = Number.isFinite(idxRaw) ? clamp(idxRaw, 0, BYTE_UNITS.length - 1) : 0;
        const val = num / Math.pow(1024, idx);
        const fixed = val >= 100 ? 0 : val >= 10 ? 1 : 2;
        const unit = BYTE_UNITS[idx] || BYTE_UNITS[0];
        return `${val.toFixed(fixed)} ${unit}`;
    }

    function formatUptime(seconds) {
        const s = Number(seconds);
        if (!Number.isFinite(s) || s <= 0) {
            return '-';
        }
        const days = Math.floor(s / 86400);
        const hours = Math.floor((s % 86400) / 3600);
        const mins = Math.floor((s % 3600) / 60);
        return `${days > 0 ? `${days}${I18N.shortDay} ` : ''}${hours}${I18N.shortHour} ${mins}${I18N.shortMinute}`;
    }

    function formatOnlineReason(rawReason) {
        const key = String(rawReason || '').trim();
        if (!key) {
            return '';
        }
        return ONLINE_REASON_MAP[key] || key;
    }

    async function apiRequest(endpoint, base) {
        const root = base || API_BASE;
        if (!root) {
            return null;
        }
        try {
            const response = await fetch(`${root}/${endpoint}`, {
                credentials: 'same-origin',
                cache: 'no-store'
            });
            if (!response.ok) {
                return null;
            }
            return await response.json();
        } catch (error) {
            return null;
        }
    }

    function setInternetStatus(data) {
        const el = byId('internet-status');
        if (!el) {
            return;
        }
        const reasonText = data && data.onlineReason ? formatOnlineReason(data.onlineReason) : '';
        const reason = reasonText ? ` (${reasonText})` : '';
        if (!data) {
            el.textContent = I18N.unknown;
            el.className = 'stat-value internet-pending';
            el.title = '';
            return;
        }
        if (data.wanStatus === 'up') {
            el.textContent = `${I18N.online}${reason}`;
            el.className = 'stat-value internet-up';
            el.title = reasonText;
            return;
        }
        el.textContent = `${I18N.offline}${reason}`;
        el.className = 'stat-value internet-down';
        el.title = reasonText;
    }

    function updateGauge(ringId, textId, value) {
        const ring = byId(ringId);
        const text = byId(textId);
        const pct = clamp(Number(value) || 0, 0, 100);
        if (text) {
            text.textContent = `${Math.round(pct)}%`;
        }
        if (ring) {
            ring.style.strokeDashoffset = String(RING_CIRCUMFERENCE * (1 - pct / 100));
        }
    }

    function initTrafficChart() {
        const canvas = byId('trafficChart');
        if (!canvas || !window.Chart) {
            return;
        }
        trafficChart = new Chart(canvas.getContext('2d'), {
            type: 'line',
            data: {
                labels: trafficLabels,
                datasets: [
                    {
                        label: I18N.uploadLabel,
                        data: trafficUp,
                        borderColor: '#61a7ff',
                        backgroundColor: 'rgba(97,167,255,0.18)',
                        pointRadius: 0,
                        borderWidth: 2,
                        tension: 0.35,
                        fill: true
                    },
                    {
                        label: I18N.downloadLabel,
                        data: trafficDown,
                        borderColor: '#29c677',
                        backgroundColor: 'rgba(41,198,119,0.16)',
                        pointRadius: 0,
                        borderWidth: 2,
                        tension: 0.35,
                        fill: true
                    }
                ]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                animation: false,
                plugins: {
                    legend: { display: false }
                },
                scales: {
                    x: {
                        display: false
                    },
                    y: {
                        ticks: {
                            color: CHART_TEXT_COLOR,
                            callback: (value) => formatBytes(value)
                        },
                        grid: {
                            color: CHART_GRID_COLOR
                        }
                    }
                }
            }
        });
    }

    function initAppUsageChart() {
        const canvas = byId('appUsageChart');
        if (!canvas || !window.Chart) {
            return;
        }
        appUsageChart = new Chart(canvas.getContext('2d'), {
            type: 'doughnut',
            data: {
                labels: [],
                datasets: [
                    {
                        data: [],
                        backgroundColor: [
                            '#61a7ff',
                            '#29c677',
                            '#38d6d9',
                            '#ff9b54',
                            '#ffd166',
                            '#ef476f'
                        ],
                        borderWidth: 0
                    }
                ]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                cutout: '66%',
                plugins: {
                    legend: {
                        position: 'right',
                        labels: {
                            color: CHART_TEXT_COLOR,
                            boxWidth: 11,
                            boxHeight: 11,
                            font: { size: 11 }
                        }
                    }
                }
            }
        });
    }

    async function refreshTraffic() {
        const data = await apiRequest('traffic');
        if (!data) {
            return;
        }
        const now = Date.now();
        const tx = Number(data.tx_bytes) || 0;
        const rx = Number(data.rx_bytes) || 0;

        setText('stat-total-up', formatBytes(tx));
        setText('stat-total-down', formatBytes(rx));

        if (!prevAt) {
            prevTx = tx;
            prevRx = rx;
            prevAt = now;
            return;
        }

        const deltaSec = Math.max((now - prevAt) / 1000, 1);
        const upRate = Math.max(0, (tx - prevTx) / deltaSec);
        const downRate = Math.max(0, (rx - prevRx) / deltaSec);

        setText('wan-up-rate', `${formatBytes(upRate)}/s`);
        setText('wan-down-rate', `${formatBytes(downRate)}/s`);

        prevTx = tx;
        prevRx = rx;
        prevAt = now;

        if (!trafficChart) {
            return;
        }

        trafficLabels.push('');
        trafficUp.push(upRate);
        trafficDown.push(downRate);

        if (trafficLabels.length > MAX_TRAFFIC_POINTS) {
            trafficLabels.shift();
            trafficUp.shift();
            trafficDown.shift();
        }

        trafficChart.update('none');
    }

    async function loadSysInfo() {
        const data = await apiRequest('sysinfo');
        if (!data) {
            return;
        }

        setText('sys-hostname', data.hostname || '-');
        setText('sys-model', data.model || '-');
        setText('sys-firmware', data.firmware || '-');
        setText('sys-kernel', data.kernel || '-');
        setText('sys-uptime', formatUptime(data.uptime_raw));

        updateGauge('cpu-ring', 'cpu-text', Number(data.cpuUsage) || 0);
        updateGauge('mem-ring', 'mem-text', Number(data.memUsage) || 0);

        const temp = Number(data.temp) || 0;
        setText('cpu-temp', temp > 0 ? `${temp} C` : '-');
        const tempBar = byId('temp-bar');
        if (tempBar) {
            tempBar.style.width = `${clamp(temp, 0, 100)}%`;
        }
    }

    async function loadNetInfo() {
        const data = await apiRequest('netinfo');
        setInternetStatus(data);
        if (!data) {
            return;
        }
        setText('lan-ip', data.lanIp || '-');
        setText('wan-ip', data.wanIp || '-');
        setText('gateway', data.gateway || '-');
        setText('interface-name', data.interfaceName || '-');
        setText('conn-count', Number(data.connCount) || 0);
    }

    function renderDevices(devices) {
        const body = byId('devices-list');
        if (!body) {
            return;
        }
        if (!devices || !devices.length) {
            body.innerHTML = `<tr><td colspan="3">${escapeHtml(I18N.noOnlineDeviceData)}</td></tr>`;
            return;
        }
        body.innerHTML = devices.map((dev) => {
            const name = escapeHtml(dev.name || dev.mac || '-');
            const ip = escapeHtml(dev.ip || '-');
            const dotClass = dev.active ? 'status-dot' : 'status-dot off';
            return `<tr><td title="${name}">${name}</td><td>${ip}</td><td><span class="${dotClass}"></span></td></tr>`;
        }).join('');
    }

    async function loadDevices() {
        const data = await apiRequest('devices');
        if (!Array.isArray(data)) {
            renderDevices([]);
            setText('active-device-count', 0);
            return;
        }
        const activeCount = data.filter((dev) => !!dev.active).length;
        setText('active-device-count', activeCount);
        renderDevices(data.slice(0, 16));
    }

    function normalizeDomainRows(rows) {
        const merged = [];
        const seen = new Set();
        (Array.isArray(rows) ? rows : []).forEach((item) => {
            const domain = String((item && item.domain) || '').trim();
            if (!domain || seen.has(domain)) {
                return;
            }
            seen.add(domain);
            merged.push({
                domain,
                count: Number(item.count) || 0
            });
        });
        return merged;
    }

    function renderDomainRows(targetId, rows, emptyText) {
        const list = byId(targetId);
        if (!list) {
            return;
        }
        if (!rows.length) {
            list.innerHTML = `<div class="domain-row">${escapeHtml(emptyText)}</div>`;
            return;
        }
        const max = Math.max(1, Number(rows[0].count) || 1);
        list.innerHTML = rows.slice(0, DOMAIN_MAX_ROWS).map((item) => {
            const name = escapeHtml(item.domain || '-');
            const count = Number(item.count) || 0;
            const pct = Math.round((count / max) * 100);
            return `
                <div class="domain-row">
                    <div class="domain-meta">
                        <span class="domain-name" title="${name}">${name}</span>
                        <span class="domain-count">${count}</span>
                    </div>
                    <div class="domain-track"><div class="domain-fill" data-pct="${pct}"></div></div>
                </div>
            `;
        }).join('');
        list.querySelectorAll('.domain-fill').forEach((el) => {
            const pct = Number(el.getAttribute('data-pct')) || 0;
            el.style.width = `${pct}%`;
        });
    }

    function renderDomains(data) {
        const topList = data && Array.isArray(data.top) ? data.top : [];
        const recentList = data && Array.isArray(data.recent) ? data.recent : [];
        const realtimeList = data && Array.isArray(data.realtime) ? data.realtime : [];

        const hotRows = normalizeDomainRows(topList.concat(recentList));
        const realtimeRows = normalizeDomainRows(realtimeList);

        renderDomainRows('domains-list', hotRows, I18N.noDomainActivity);
        renderDomainRows('realtime-domains-list', realtimeRows, I18N.noDomainActivity);

        setText('domain-source', data && data.source ? data.source : '-');
        setText('realtime-domain-source', data && data.realtime_source ? data.realtime_source : '-');
    }

    async function loadDomains() {
        if (domainRequestInFlight) {
            return;
        }
        domainRequestInFlight = true;
        try {
            const data = await apiRequest(`domains?_=${Date.now()}`);
            renderDomains(data);
        } finally {
            domainRequestInFlight = false;
        }
    }

    function renderActiveApps(apps) {
        const box = byId('oaf-apps-list');
        if (!box) {
            return;
        }
        if (!apps || !apps.length) {
            box.innerHTML = `<div class="app-item"><div class="app-name">${escapeHtml(I18N.noActiveAppData)}</div></div>`;
            return;
        }
        box.innerHTML = apps.slice(0, 20).map((app) => {
            const name = escapeHtml(app.name || '-');
            const icon = app.icon ? escapeHtml(app.icon) : '';
            const iconHtml = icon
                ? `<img class="app-icon" src="${icon}" alt="${name}">`
                : '<div class="app-icon"><i data-lucide="globe" class="w-4 h-4"></i></div>';
            return `<div class="app-item" title="${name}">${iconHtml}<div class="app-name">${name}</div></div>`;
        }).join('');
        if (window.lucide && typeof window.lucide.createIcons === 'function') {
            window.lucide.createIcons();
        }
    }

    async function loadOafStatus() {
        const data = await apiRequest('status', API_OAF);
        if (!data || data.error || data.available === false) {
            setText('oaf-version', I18N.unavailable);
            setText('oaf-engine', '-');
            setText('app-count', 0);
            renderActiveApps([]);
            if (appUsageChart) {
                appUsageChart.data.labels = [];
                appUsageChart.data.datasets[0].data = [];
                appUsageChart.update();
            }
            return;
        }

        setText('oaf-version', data.current_version || '-');
        setText('oaf-engine', data.engine || '-');

        const activeApps = Array.isArray(data.active_apps) ? data.active_apps : [];
        setText('app-count', activeApps.length);
        renderActiveApps(activeApps);

        if (appUsageChart && Array.isArray(data.class_stats)) {
            appUsageChart.data.labels = data.class_stats.map((item) => item.name || '-');
            appUsageChart.data.datasets[0].data = data.class_stats.map((item) => Number(item.time) || 0);
            appUsageChart.update();
        }
    }

    function resetUploadState() {
        const btn = byId('oaf-upload-btn');
        const bar = byId('oaf-bar');
        const progress = byId('oaf-progress-container');
        if (btn) {
            btn.disabled = false;
            btn.textContent = I18N.updateFeatureLibrary;
        }
        if (bar) {
            bar.style.width = '0%';
        }
        if (progress) {
            progress.classList.add('hidden');
        }
    }

    function uploadOafFeature() {
        const fileInput = byId('oaf-file-input');
        if (!fileInput || !fileInput.files || !fileInput.files[0]) {
            return;
        }
        const file = fileInput.files[0];
        if (file.size > OAF_MAX_SIZE) {
            alert(I18N.fileTooLarge);
            return;
        }
        if (!/\.(bin|zip)$/i.test(file.name)) {
            alert(I18N.unsupportedFileType);
            return;
        }

        const btn = byId('oaf-upload-btn');
        const bar = byId('oaf-bar');
        const progress = byId('oaf-progress-container');
        if (btn) {
            btn.disabled = true;
            btn.textContent = I18N.uploading;
        }
        if (progress) {
            progress.classList.remove('hidden');
        }
        if (bar) {
            bar.style.width = '0%';
        }

        const formData = new FormData();
        formData.append('token', LUCI_TOKEN);
        formData.append('file', file);

        const xhr = new XMLHttpRequest();
        xhr.open('POST', `${API_OAF}/upload?token=${encodeURIComponent(LUCI_TOKEN)}`, true);

        xhr.upload.onprogress = (event) => {
            if (event.lengthComputable && bar) {
                const pct = Math.round((event.loaded / event.total) * 100);
                bar.style.width = `${pct}%`;
            }
        };

        xhr.onload = () => {
            let payload = {};
            try {
                payload = JSON.parse(xhr.responseText || '{}');
            } catch (error) {
                payload = {};
            }
            if (xhr.status === 200 && payload.success) {
                if (btn) {
                    btn.textContent = I18N.updateSuccess;
                }
                setTimeout(() => window.location.reload(), 1200);
                return;
            }
            resetUploadState();
            alert(`${I18N.uploadFailed}: ${payload.message || I18N.unknownError}`);
        };

        xhr.onerror = () => {
            resetUploadState();
            alert(I18N.networkErrorWhileUploading);
        };

        xhr.send(formData);
    }

    function init() {
        initTrafficChart();
        initAppUsageChart();

        const uploadBtn = byId('oaf-upload-btn');
        if (uploadBtn) {
            uploadBtn.addEventListener('click', uploadOafFeature);
        }

        if (window.lucide && typeof window.lucide.createIcons === 'function') {
            window.lucide.createIcons();
        }

        refreshTraffic();
        loadSysInfo();
        loadNetInfo();
        loadDevices();
        loadDomains();
        loadOafStatus();

        window.setInterval(refreshTraffic, 3000);
        window.setInterval(loadSysInfo, 10000);
        window.setInterval(loadNetInfo, 12000);
        window.setInterval(loadDevices, 15000);
        window.setInterval(loadDomains, DOMAIN_REFRESH_INTERVAL);
        window.setInterval(loadOafStatus, 60000);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})(window, document);
