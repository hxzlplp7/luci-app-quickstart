(function() {
    'use strict';

    const API_BASE = window.location.pathname.replace(/\/+$/, '') + '/api';
    const REFRESH_RATE = 3000;
    const CIRCUMFERENCE = 2 * Math.PI * 100; // Radius=100

    function formatBytes(bytes) {
        if (bytes === 0) return '0 B';
        const k = 1024, units = ['B', 'KB', 'MB', 'GB', 'TB'];
        const i = Math.floor(Math.log(bytes) / Math.log(k));
        return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + units[i];
    }

    function formatSpeed(bps) {
        if (bps === 0) return '0';
        const mbps = (bps * 8) / 1000000;
        if (mbps < 0.1) return ((bps * 8) / 1000).toFixed(1) + ' Kbps';
        return mbps.toFixed(2);
    }

    function setGauge(id, value, max = 100) {
        const circle = document.querySelector(`#${id} .gauge-fill`);
        if (!circle) return;
        const progress = Math.min(value / max, 1);
        const offset = CIRCUMFERENCE - (progress * CIRCUMFERENCE);
        circle.style.strokeDashoffset = offset;
    }

    async function loadData() {
        try {
            const res = await fetch(`${API_BASE}/network_traffic`);
            const data = await res.json();
            if (data.success !== 200) return;
            const resData = data.result;

            // 1. Update Gauges
            // Max speed scaling logic (adaptive)
            const downMbps = (resData.speed.rx * 8) / 1000000;
            const upMbps = (resData.speed.tx * 8) / 1000000;
            const max = Math.max(10, state.maxSeenSpeed || 0, downMbps, upMbps);
            state.maxSeenSpeed = max * 0.95; // Decay max over time

            setGauge('gauge-down', downMbps, max);
            setGauge('gauge-up', upMbps, max);

            document.getElementById('val-down').textContent = downMbps.toFixed(1);
            document.getElementById('val-up').textContent = upMbps.toFixed(1);
            document.getElementById('total-rx').textContent = formatBytes(resData.totals.rx);
            document.getElementById('total-tx').textContent = formatBytes(resData.totals.tx);

            // 2. Render Top Domains
            const domainList = document.getElementById('domain-list');
            domainList.innerHTML = resData.top_domains.map(d => `
                <div class="stat-row">
                    <span class="stat-name">${d.name}</span>
                    <div class="stat-data">
                        <span class="stat-val">${formatBytes(d.value)}</span>
                    </div>
                </div>
            `).join('');

            // 3. Render Traffic Types
            const typeList = document.getElementById('type-list');
            const totalVolume = resData.traffic_types.reduce((acc, curr) => acc + curr.value, 0) || 1;
            typeList.innerHTML = resData.traffic_types.sort((a,b) => b.value - a.value).slice(0, 6).map(t => `
                <div class="stat-row">
                    <span class="stat-name">${t.name}</span>
                    <div class="stat-data">
                        <span class="stat-val">${formatBytes(t.value)}</span>
                        <span class="stat-pct">${Math.floor((t.value/totalVolume)*100)}%</span>
                    </div>
                </div>
            `).join('');

        } catch (e) { console.error('Data sync failed', e); }
    }

    async function loadSys() {
        const res = await fetch(`${API_BASE}/system_status`);
        const data = await res.json();
        if (data.success === 200) {
            document.getElementById('cpu-val').textContent = data.result.cpu_usage + '%';
            document.getElementById('mem-val').textContent = data.result.mem_usage + '%';
        }
    }

    const state = { maxSeenSpeed: 50 };

    // Initial load
    document.addEventListener('DOMContentLoaded', () => {
        // Setup SVG Dasharrays
        document.querySelectorAll('.gauge-fill').forEach(el => {
            el.style.strokeDasharray = CIRCUMFERENCE;
            el.style.strokeDashoffset = CIRCUMFERENCE;
        });
        
        loadData();
        loadSys();
        setInterval(loadData, REFRESH_RATE);
        setInterval(loadSys, 10000);
    });

})();
