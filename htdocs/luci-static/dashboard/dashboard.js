(function(window, document) {
    'use strict';

    // 状态配置：从当前页面 URL 自动推导 API 基址
    // 匹配 /admin/dashboard 后确保不将子路径（如 /api）也匹配进去
    const _rawPath = window.location.pathname.replace(/\/api(\/.*)?$/, '');
    const pathMatch = _rawPath.match(/(.+\/admin\/dashboard)/);
    const API_BASE = pathMatch ? pathMatch[1] + '/api' : '';
    const API_OAF = API_BASE ? API_BASE + '/oaf' : '';
    const LUCI_TOKEN = (window.L && L.env && L.env.token) ? L.env.token : '';

    // 基础工具与安全性增强
    const escapeHtml = (str) => {
        if (!str) return '';
        const div = document.createElement('div');
        div.textContent = str;
        return div.innerHTML;
    };

    const formatBytes = (bytes) => {
        if (!bytes || bytes === 0) return '0 B';
        const k = 1024, sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
        const i = Math.floor(Math.log(bytes) / Math.log(k));
        return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
    };

    const formatUptime = (s) => {
        if (!s) return '-';
        const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
        return `${d > 0 ? d + 'd ' : ''}${h}h ${m}m`;
    };

    async function apiRequest(ep, base = API_BASE) {
        try { 
            const res = await fetch(`${base}/${ep}`, { credentials: 'same-origin' }); 
            return res.ok ? await res.json() : null; 
        } catch (e) { 
            return null; 
        }
    }

    // Chart.js 全局配置 (确保 Chart 已经加载)
    if (window.Chart) {
        Chart.defaults.color = '#9ca3af';
        Chart.defaults.borderColor = '#374151';
    }

    // 1. 流量图表
    let trafficChart;
    const initTrafficChart = () => {
        const ctx = document.getElementById('trafficChart');
        if (!ctx) return;
        const MAX_POINTS = 40;
        let trafficLabels = Array(MAX_POINTS).fill('');
        let dataDown = Array(MAX_POINTS).fill(0);
        let dataUp = Array(MAX_POINTS).fill(0);

        trafficChart = new Chart(ctx.getContext('2d'), {
            type: 'line',
            data: {
                labels: trafficLabels,
                datasets: [
                    { label: '下行', data: dataDown, borderColor: '#10b981', backgroundColor: 'rgba(16, 185, 129, 0.1)', fill: true, tension: 0.4, pointRadius: 0, borderWidth: 2 },
                    { label: '上行', data: dataUp, borderColor: '#3b82f6', backgroundColor: 'rgba(59, 130, 246, 0.1)', fill: true, tension: 0.4, pointRadius: 0, borderWidth: 2 }
                ]
            },
            options: {
                responsive: true, maintainAspectRatio: false,
                plugins: { legend: { display: false } },
                scales: { x: { display: false }, y: { grid: { color: '#2d2e34' }, ticks: { font: { size: 10 } } } },
                animation: false
            }
        });
        return { dataDown, dataUp };
    };

    const { dataDown, dataUp } = initTrafficChart() || { dataDown: [], dataUp: [] };
    let prevTx = 0, prevRx = 0, prevTime = 0;

    async function refreshTraffic() {
        const data = await apiRequest('traffic');
        if (data && trafficChart) {
            const now = Date.now();
            if (prevTime !== 0) {
                const diff = Math.max((now - prevTime) / 1000, 1);
                if (data.tx_bytes < prevTx || data.rx_bytes < prevRx) {
                    prevTx = data.tx_bytes; prevRx = data.rx_bytes; prevTime = now;
                    return;
                }
                const upSpeed = Math.max(0, (data.tx_bytes - prevTx) / diff);
                const downSpeed = Math.max(0, (data.rx_bytes - prevRx) / diff);
                dataUp.push(upSpeed); dataDown.push(downSpeed);
                dataUp.shift(); dataDown.shift();
                trafficChart.update();
                const upEl = document.getElementById('cur-up-speed');
                const downEl = document.getElementById('cur-down-speed');
                if (upEl) upEl.innerText = formatBytes(upSpeed) + '/s';
                if (downEl) downEl.innerText = formatBytes(downSpeed) + '/s';
            }
            document.getElementById('total-up').innerText = formatBytes(data.tx_bytes);
            document.getElementById('total-down').innerText = formatBytes(data.rx_bytes);
            prevTx = data.tx_bytes; prevRx = data.rx_bytes; prevTime = now;
        }
    }

    // 2. Dials (CPU/Mem)
    let cpuDial, memDial;
    const initDials = () => {
        const cCtx = document.getElementById('cpuDial');
        const mCtx = document.getElementById('memDial');
        if (!cCtx || !mCtx) return;

        cpuDial = new Chart(cCtx.getContext('2d'), {
            type: 'doughnut', data: { datasets: [{ data: [0, 100], backgroundColor: ['#10b981', '#2d2e34'], borderWidth: 0 }] },
            options: { responsive: true, cutout: '85%', plugins: { tooltip: false } }
        });
        memDial = new Chart(mCtx.getContext('2d'), {
            type: 'doughnut', data: { datasets: [{ data: [0, 100], backgroundColor: ['#3b82f6', '#2d2e34'], borderWidth: 0 }] },
            options: { responsive: true, cutout: '85%', plugins: { tooltip: false } }
        });
    };

    // 3. App Usage / Distribution
    let appUsageChart;
    const initAppUsageChart = () => {
        const ctx = document.getElementById('appUsageChart');
        if (!ctx) return;
        appUsageChart = new Chart(ctx.getContext('2d'), {
            type: 'doughnut', data: { labels: ['视频', '下载', '聊天', '购物'], datasets: [{ data: [40, 30, 20, 10], backgroundColor: ['#10b981','#8b5cf6','#3b82f6','#f97316'], borderWidth: 0 }] },
            options: { responsive: true, maintainAspectRatio: false, cutout: '70%', plugins: { legend: { position: 'right', labels: { boxWidth: 10, font: { size: 10 } } } } }
        });
    };

    // 4. Data Loading
    async function loadSysInfo() {
        const data = await apiRequest('sysinfo');
        if (data) {
            document.getElementById('sys-hostname').innerText = data.hostname || '-';
            document.getElementById('sys-model').innerText = data.model || '-';
            document.getElementById('sys-firmware').innerText = data.firmware || '-';
            document.getElementById('sys-kernel').innerText = data.kernel || '-';
            document.getElementById('sys-uptime').innerText = formatUptime(data.uptime_raw);
            document.getElementById('cpu-text').innerText = (data.cpuUsage || 0) + '%';
            if (cpuDial) {
                cpuDial.data.datasets[0].data = [data.cpuUsage, 100 - data.cpuUsage]; cpuDial.update();
            }
            document.getElementById('mem-text').innerText = (data.memUsage || 0) + '%';
            if (memDial) {
                memDial.data.datasets[0].data = [data.memUsage, 100 - data.memUsage]; memDial.update();
            }
            document.getElementById('cpu-temp').innerText = (data.temp > 0 ? data.temp + '°C' : '-');
            const tempBar = document.getElementById('temp-bar');
            if (tempBar) tempBar.style.width = Math.min(data.temp || 0, 100) + '%';
        }
    }

    async function loadNetInfo() {
        const data = await apiRequest('netinfo');
        const statusText = document.getElementById('wan-status-text');
        if (!data) {
            // API 请求失败降级处理
            if (statusText) {
                statusText.innerText = '检测失败';
                statusText.className = 'text-yellow-500 font-semibold text-sm';
            }
            return;
        }
        if (data.wanStatus === 'up') {
            statusText.innerText = '已联网';
            statusText.className = 'text-accentGreen font-semibold text-sm';
        } else {
            statusText.innerText = '未连接';
            statusText.className = 'text-red-500 font-semibold text-sm';
        }
        document.getElementById('lan-ip').innerText = data.lanIp || '-';
        document.getElementById('wan-ip').innerText = data.wanIp || '-';
        if (document.getElementById('conn-count')) {
            document.getElementById('conn-count').innerText = data.connCount || '-';
        }
    }

    async function loadDevices() {
        const devices = await apiRequest('devices');
        if (!devices) return;
        document.getElementById('active-device-count').innerText = devices.filter(d => d.active).length;
        const html = devices.slice(0, 10).map(dev => `
            <div class="flex items-center justify-between text-xxs group">
                <span class="text-gray-400 truncate w-32" title="${escapeHtml(dev.name || dev.mac)}">${escapeHtml(dev.name || dev.mac)}</span>
                <span class="text-textMuted font-mono">${escapeHtml(dev.ip)}</span>
                <span class="w-1.5 h-1.5 rounded-full ${dev.active ? 'bg-accentGreen' : 'bg-gray-600'}"></span>
            </div>
        `).join('');
        document.getElementById('devices-list').innerHTML = html;
        if (window.lucide) lucide.createIcons();
    }

    async function loadDomains() {
        const data = await apiRequest('domains');
        if (!data || !data.top) return;
        const max = data.top[0] ? data.top[0].count : 1;
        // 进度条宽度通过 CSS 自定义属性注入，避免内联 style 触发 style-src CSP
        const html = data.top.slice(0, 8).map(item => {
            const pct = Math.round((item.count / max) * 100);
            return `<div class="space-y-1 domain-bar-item" data-pct="${pct}">
                <div class="flex justify-between text-xxs"><span class="truncate w-40 font-mono" title="${escapeHtml(item.domain)}">${escapeHtml(item.domain)}</span><span class="text-accentBlue">${item.count}</span></div>
                <div class="w-full bg-bgBase h-0.5"><div class="bg-accentBlue h-full domain-bar-fill"></div></div>
            </div>`;
        }).join('');
        const listEl = document.getElementById('domains-list');
        if (!listEl) return;
        listEl.innerHTML = html;
        // 渲染后通过 JS 设置宽度（style.setProperty 不受 CSP 限制）
        listEl.querySelectorAll('.domain-bar-item').forEach(el => {
            const fill = el.querySelector('.domain-bar-fill');
            if (fill) fill.style.width = el.dataset.pct + '%';
        });
    }

    async function loadOafStatus() {
        const data = await apiRequest('status', API_OAF);
        const listEl = document.getElementById('oaf-apps-list');
        const versionEl = document.getElementById('oaf-version');
        const engineEl = document.getElementById('oaf-engine');

        // 情况1: API 请求失败 (OAF 模块未安装 / 后端异常)
        if (!data || data.error) {
            if (versionEl) versionEl.innerText = '未安装';
            if (engineEl) engineEl.innerText = '不可用';
            if (listEl) listEl.innerHTML = '<span class="text-xxs text-textMuted italic">OAF 未安装或不可用</span>';
            return;
        }

        // 情况2: API 正常返回，但 OAF 服务不可用
        if (data.available === false) {
            if (versionEl) versionEl.innerText = '未检测到';
            if (engineEl) engineEl.innerText = '未运行';
            if (listEl) listEl.innerHTML = '<span class="text-xxs text-textMuted italic">OAF 特征库未加载</span>';
            return;
        }

        // 正常状态
        if (versionEl) versionEl.innerText = data.current_version || '-';
        if (engineEl) engineEl.innerText = data.engine || '-';

        if (data.class_stats && data.class_stats.length > 0 && appUsageChart) {
            appUsageChart.data.labels = data.class_stats.map(item => item.name || '-');
            appUsageChart.data.datasets[0].data = data.class_stats.map(item => item.time || 0);
            appUsageChart.update();
        }

        if (data.active_apps && data.active_apps.length > 0) {
            const colors = ['bg-green-500', 'bg-blue-500', 'bg-purple-500', 'bg-orange-500', 'bg-cyan-500'];
            const icons = ['play', 'message-square', 'download', 'shopping-cart', 'globe'];
            listEl.innerHTML = data.active_apps.slice(0, 10).map((app, i) => `
                <div class="flex flex-col items-center gap-1 w-10 group cursor-help" title="${escapeHtml(app.name)}">
                    <div class="w-8 h-8 rounded ${colors[i % colors.length]} flex items-center justify-center text-white shadow-sm group-hover:scale-110 transition-transform">
                        <i data-lucide="${icons[i % icons.length]}" class="w-4 h-4"></i>
                    </div>
                    <span class="text-xxs text-textMuted truncate w-full text-center">${escapeHtml(app.name)}</span>
                </div>
            `).join('');
            if (window.lucide) lucide.createIcons();
        } else if (listEl) {
            listEl.innerHTML = '<span class="text-xxs text-textMuted italic">暂无活跃应用数据</span>';
        }
    }

    async function uploadOafFeature() {
        const fileInput = document.getElementById('oaf-file-input');
        if (!fileInput || !fileInput.files[0]) return;
        
        const file = fileInput.files[0];
        if (file.size > 32 * 1024 * 1024) {
            alert('文件过大：特征库文件不能超过 32MB');
            return;
        }
        if (!file.name.match(/\.(bin|zip)$/i)) {
            alert('文件格式错误：请上传 .bin 或 .zip 格式的特征库');
            return;
        }

        const formData = new FormData();
        formData.append('token', LUCI_TOKEN);
        formData.append('file', file);
        const btn = document.getElementById('oaf-upload-btn');
        const progress = document.getElementById('oaf-progress-container');
        const bar = document.getElementById('oaf-bar');
        
        btn.disabled = true; 
        btn.innerHTML = '<i data-lucide="loader-2" class="w-3 h-3 animate-spin"></i> 处理中...';
        if (window.lucide) lucide.createIcons();
        progress.classList.remove('hidden');

        const xhr = new XMLHttpRequest(); 
        xhr.open('POST', `${API_OAF}/upload`, true);
        xhr.upload.onprogress = (e) => { 
            if (e.lengthComputable) { bar.style.width = Math.round((e.loaded/e.total)*100) + '%'; } 
        };
        xhr.onload = () => { 
            let res = { success: false, message: '服务器响应异常' };
            try { res = JSON.parse(xhr.responseText); } catch(e) {}
            
            if (xhr.status === 200 && res.success) {
                btn.innerHTML = '<i data-lucide="check-circle" class="w-3 h-3"></i> 更新成功';
                if (window.lucide) lucide.createIcons();
                setTimeout(() => location.reload(), 1500); 
            } else {
                alert('上传失败: ' + (res.message || '未知错误'));
                btn.disabled = false;
                btn.innerHTML = '<i data-lucide="upload" class="w-3 h-3"></i> 立即更新';
                progress.classList.add('hidden');
                bar.style.width = '0%';
                if (window.lucide) lucide.createIcons();
            }
        };
        xhr.onerror = () => {
            alert('网络请求失败，请检查连接');
            btn.disabled = false;
            btn.innerHTML = '<i data-lucide="upload" class="w-3 h-3"></i> 立即更新';
            progress.classList.add('hidden');
            if (window.lucide) lucide.createIcons();
        };
        xhr.send(formData);
    }

    // 初始化与事件绑定
    const init = () => {
        initDials();
        initAppUsageChart();
        
        refreshTraffic();
        loadSysInfo(); 
        loadNetInfo(); 
        loadDevices(); 
        loadDomains(); 
        loadOafStatus();

        const uploadBtn = document.getElementById('oaf-upload-btn');
        if (uploadBtn) {
            uploadBtn.addEventListener('click', uploadOafFeature);
        }

        if (window.lucide) lucide.createIcons();

        setInterval(refreshTraffic, 3000);
        setInterval(loadSysInfo, 10000);   // 系统信息每10秒更新
        setInterval(loadNetInfo, 15000);   // 联网状态每15秒更新
        setInterval(loadDevices, 15000);   // 设备列表每15秒更新
    };

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

})(window, document);
