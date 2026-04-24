        if (typeof lucide !== 'undefined' && typeof lucide.createIcons === 'function') {
            lucide.createIcons();
        } else {
            console.warn('[Dashboard] lucide is not loaded.');
        }

        function initNavButtons() {
            const navButtons = document.querySelectorAll('.dash-nav-button[data-nav-target]');
            navButtons.forEach((button) => {
                button.addEventListener('click', () => {
                    const target = button.getAttribute('data-nav-target');
                    if (target) window.location.href = target;
                });
            });
        }

        const getApiBase = () => {
            const h = window.location.pathname;
            return h.includes('/admin/') ? h.split('/admin/')[0] + '/admin/dashboard/api' : '/cgi-bin/luci/admin/dashboard/api';
        };

        const dashboardData = window.DashboardData || {};
        const pickActiveAppState = typeof dashboardData.pickActiveAppState === 'function'
            ? dashboardData.pickActiveAppState
            : function(databus, oafData) {
                return {
                    apps: (databus && databus.online_apps && databus.online_apps.list) || (oafData && oafData.active_apps) || [],
                    classStats: (databus && databus.app_recognition && databus.app_recognition.class_stats) || (oafData && oafData.class_stats) || [],
                    source: (databus && databus.app_recognition && databus.app_recognition.source) || (oafData && oafData.active_source) || 'none',
                };
            };
        const deriveTrafficSnapshot = typeof dashboardData.deriveTrafficSnapshot === 'function'
            ? dashboardData.deriveTrafficSnapshot
            : function(sample, previousState, nowMs) {
                const now = Number(nowMs);
                const nextState = {
                    interface: sample && sample.interface ? String(sample.interface) : '',
                    tx_bytes: Math.max(0, Number(sample && sample.tx_bytes) || 0),
                    rx_bytes: Math.max(0, Number(sample && sample.rx_bytes) || 0),
                    at: Number.isFinite(now) && now > 0 ? now : Date.now(),
                };

                const backendTxRate = Number(sample && sample.tx_rate);
                const backendRxRate = Number(sample && sample.rx_rate);
                if (Number.isFinite(backendTxRate) || Number.isFinite(backendRxRate)) {
                    return {
                        txRate: Number.isFinite(backendTxRate) ? Math.max(0, backendTxRate) : 0,
                        rxRate: Number.isFinite(backendRxRate) ? Math.max(0, backendRxRate) : 0,
                        nextState: nextState,
                    };
                }

                if (!previousState || previousState.interface !== nextState.interface) {
                    return { txRate: 0, rxRate: 0, nextState: nextState };
                }

                const prevAt = Math.max(0, Number(previousState.at) || 0);
                const prevTx = Math.max(0, Number(previousState.tx_bytes) || 0);
                const prevRx = Math.max(0, Number(previousState.rx_bytes) || 0);
                const diffSeconds = (nextState.at - prevAt) / 1000;
                if (!(diffSeconds > 0)) {
                    return { txRate: 0, rxRate: 0, nextState: nextState };
                }

                const txDelta = nextState.tx_bytes - prevTx;
                const rxDelta = nextState.rx_bytes - prevRx;
                if (txDelta < 0 || rxDelta < 0) {
                    return { txRate: 0, rxRate: 0, nextState: nextState };
                }

                return {
                    txRate: txDelta / diffSeconds,
                    rxRate: rxDelta / diffSeconds,
                    nextState: nextState,
                };
            };

        let mockTx = 1024 * 1024 * 50;
        let mockRx = 1024 * 1024 * 300;
        const getMockData = (endpoint) => {
            switch(endpoint) {
                case 'netinfo': return { wanStatus: 'up', wanIp: '100.64.12.34', lanIp: '192.168.100.1', dns: ['202.103.24.68', '202.103.44.150'], network_uptime_raw: 445800, publicIp: '1.2.3.4', publicCountry: 'Local' };
                case 'sysinfo': return { model: '缂傚倷鑳堕搹搴ㄥ垂閹惰В鈧牠宕堕埡鍐╋紡闂佺鍕垫闁哄棙娲熼幃?闂備胶顭堥鍛洪敃鍌氭辈闁绘梻鍘х粻?', firmware: 'iStoreOS 24.10.2', kernel: '6.6.93', temp: 40, systime_raw: Math.floor(Date.now() / 1000), uptime_raw: 84942, cpuUsage: 3, memUsage: 12 };
                case 'traffic':
                    mockTx += Math.floor(Math.random() * 2000000);
                    mockRx += Math.floor(Math.random() * 15000000);
                    return { interface: 'eth0', tx_bytes: mockTx, rx_bytes: mockRx, tx_rate: 240000, rx_rate: 960000 };
                case 'devices': return [
                    { mac: 'AA:BB:CC:DD:EE:FF', ip: '192.168.100.101', name: 'iPhone-13', type: 'mobile', active: true },
                    { mac: '11:22:33:44:55:66', ip: '192.168.100.105', name: 'MacBook-Pro', type: 'laptop', active: true },
                    { mac: '22:33:44:55:66:77', ip: '192.168.100.120', name: 'Smart-TV', type: 'other', active: false }
                ];
                case 'domains': return { 
                    source: 'mock', 
                    top: [ { domain: 'daemon.info', count: 2514 }, { domain: 'apple.com', count: 201 } ],
                    realtime: [ { domain: 'baidu.com', count: 12 }, { domain: 'github.com', count: 843 } ]
                };
                case 'apps': return [
                    { name: 'Meituan', color: 'bg-yellow-400', text: 'M', textColor: 'text-black' },
                    { name: 'WeChat', color: 'bg-green-500', icon: 'message-circle', textColor: 'text-white' }
                ];
                case 'databus': return {
                    online_apps: {
                        total: 2,
                        list: [
                            { name: 'Microsoft', source: 'domain-heuristic' },
                            { name: 'Google', source: 'domain-heuristic' }
                        ]
                    },
                    app_recognition: {
                        available: true,
                        source: 'domain-heuristic',
                        engine: 'domain-heuristic',
                        class_stats: [
                            { name: 'cloud', time: 8 },
                            { name: 'search', time: 4 }
                        ]
                    }
                };
                default: return null;
            }
        };

        function extractDatabusEndpoint(endpoint, databus) {
            const data = databus || {};
            if (endpoint === 'databus' || endpoint === 'backend' || endpoint === 'common') return data;
            if (endpoint === 'sysinfo') return data.system_status || null;
            if (endpoint === 'traffic') return data.interface_traffic || null;
            if (endpoint === 'devices') return (data.devices && data.devices.list) || [];
            if (endpoint === 'domains') {
                const domains = data.domains || {};
                if (!domains.realtime && data.realtime_urls && Array.isArray(data.realtime_urls.list)) {
                    domains.realtime = data.realtime_urls.list.map((item) => ({
                        domain: item.domain,
                        count: Number(item.count || item.hits) || 0,
                    }));
                    domains.realtime_source = domains.realtime_source || data.realtime_urls.source || 'dashboard-core';
                }
                return domains;
            }
            if (endpoint === 'netinfo') {
                const status = data.status || {};
                const network = data.network_status || {};
                const lan = network.lan || {};
                const wan = network.wan || {};
                const online = Boolean(status.online);
                const internet = status.internet || (online ? 'up' : 'down');
                return {
                    wanStatus: internet === 'up' || online ? 'up' : 'down',
                    wanIp: wan.ip || '',
                    wanIpv6: wan.ipv6 || '',
                    lanIp: lan.ip || '',
                    dns: wan.dns || lan.dns || [],
                    network_uptime_raw: Number(network.network_uptime_raw || network.uptime_raw) || 0,
                    connCount: Number(status.conn_count || status.connCount) || 0,
                    interfaceName: network.interface || '',
                    gateway: wan.gateway || '',
                    linkUp: Boolean(status.link_up),
                    routeReady: Boolean(status.route_ready),
                    probeOk: Boolean(status.probe_ok),
                    onlineReason: status.online_reason || network.online_reason || '',
                };
            }
            return data;
        }

        async function apiRequest(ep) {
            const hostname = window.location.hostname || '';
            const protocol = window.location.protocol || '';
            const isLocalHtml = protocol === 'file:' || protocol === 'blob:' || hostname === 'localhost' || hostname === '' || hostname.includes('usercontent');
            const isLuciEnv = window.location.pathname.includes('/admin/');

            if (isLocalHtml && !isLuciEnv) return getMockData(ep);

            try {
                const API_BASE = getApiBase();
                const url = `${API_BASE}/databus?t=${Date.now()}`;
                const res = await fetch(url, { credentials: 'same-origin', headers: { 'Accept': 'application/json' } });
                if (!res.ok) throw new Error(`HTTP ${res.status}`);
                const databus = await res.json();
                if (databus && databus.error) throw new Error(databus.error);
                return extractDatabusEndpoint(ep, databus);
            } catch (e) {
                console.error(`[API Error] ${ep}:`, e.message);
                return null;
            }
        }

        // Normalize raw source labels.
        function formatSourceLabel(raw) {
            if (!raw || raw === 'none' || raw === '-') return '-';
            const SOURCE_MAP = {
                'conntrack+dnsmasq': 'conntrack', 'dnsmasq-logread': 'dnsmasq',
                'logread-dns': 'logread', 'logread-proxy': 'proxy', 'appfilter': 'appfilter',
                'smartdns': 'smartdns', 'adguardhome': 'AdGuardHome', 'mosdns': 'mosdns',
                'openclash': 'openclash', 'passwall': 'passwall', 'passwall2': 'passwall2',
                'homeproxy': 'homeproxy', 'mihomo': 'mihomo', 'sing-box': 'sing-box'
            };
            if (SOURCE_MAP[raw]) return SOURCE_MAP[raw];
            for (const key of Object.keys(SOURCE_MAP)) if (raw.indexOf(key) !== -1) return SOURCE_MAP[key];
            return raw.length > 20 ? raw.slice(0, 20) + '...' : raw;
        }

        function formatBytes(b) {
            const bytes = Number(b);
            if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
            const k = 1024, sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
        }

        function formatUptime(s) {
            if (!s || s <= 0) return '-';
            const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
            return `${d > 0 ? d + '天 ' : ''}${h}小时 ${m}分`;
        }

        function formatSysTime(unixSeconds) {
            const d = new Date(unixSeconds * 1000);
            return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')} ${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}:${String(d.getSeconds()).padStart(2,'0')}`;
        }

        let sysUptimeGlobal = 0, netUptimeGlobal = 0, sysTimeGlobal = 0;
        setInterval(() => {
            if (sysUptimeGlobal > 0) document.getElementById('sys-uptime').innerText = '在线时间: ' + formatUptime(++sysUptimeGlobal);
            if (netUptimeGlobal > 0) document.getElementById('network-uptime').innerText = formatUptime(++netUptimeGlobal);
            if (sysTimeGlobal > 0) document.getElementById('sys-time').innerText = formatSysTime(++sysTimeGlobal);
        }, 1000);

        async function loadStaticInfo() {
            const net = await apiRequest('netinfo');
            if (net) {
                document.getElementById('wan-ip').innerText = net.wanIp || '-';
                document.getElementById('lan-ip').innerText = net.lanIp || '-';
                document.getElementById('gateway').innerText = net.gateway || '-';
                document.getElementById('internet-status-text').innerText = net.wanStatus === 'up' ? (net.wanIp ? 'Internet Online' : 'Gateway Ready') : 'Internet Offline';
                document.getElementById('internet-status-desc').innerText = net.onlineReason ? net.onlineReason : '-';
                if(document.getElementById('summary-connections') && net.connCount) document.getElementById('summary-connections').innerText = net.connCount;

                document.getElementById('dns-servers').innerHTML = net.dns && net.dns.length > 0 ? net.dns.join(' ') : '-';
                netUptimeGlobal = net.network_uptime_raw;
                if(net.wanStatus === 'up') document.getElementById('wan-status-dot').classList.remove('hidden');
            }

            const sys = await apiRequest('sysinfo');
            if (sys) {
                document.getElementById('sys-model').innerText = sys.model || '-';
                document.getElementById('sys-firmware').innerText = sys.firmware || '-';
                sysUptimeGlobal = sys.uptime_raw;
                sysTimeGlobal = sys.systime_raw;
                updateCpuMem(sys);
            }
        }

        function updateCpuMem(s) {
            document.getElementById('cpu-text').innerText = s.cpuUsage + '%';
            document.getElementById('cpu-bar').style.width = s.cpuUsage + '%';
            document.getElementById('cpu-temp').innerText = s.temp > 0 ? s.temp + ' C' : '-';
            const tb = document.getElementById('temp-bar');
            const tv = s.temp || 0;
            tb.style.width = Math.min(tv, 100) + '%';
            tb.className = `h-1.5 rounded-full transition-all duration-500 ${tv > 75 ? 'bg-red-500' : (tv > 55 ? 'bg-orange-500' : 'bg-green-500')}`;
            document.getElementById('mem-text').innerText = s.memUsage + '%';
            const mb = document.getElementById('mem-bar');
            mb.style.width = s.memUsage + '%';
            mb.className = `h-1.5 rounded-full transition-all duration-500 ${s.memUsage > 85 ? 'bg-red-500' : 'bg-green-500'}`;
        }

        async function loadDevices() {
            const devs = await apiRequest('devices');
            if (!devs) return;
            const activeCount = devs.filter(d => d.active).length;
            document.getElementById('active-device-count').innerText = activeCount;
            if (document.getElementById('summary-devices')) document.getElementById('summary-devices').innerText = activeCount;

            document.getElementById('devices-list').innerHTML = devs.map(d => `
                <div class="flex items-center justify-between p-2 hover:bg-gray-50 rounded-lg">
                    <div class="flex items-center space-x-2">
                        <div class="${d.active ? 'text-blue-500' : 'text-gray-300'}"><i data-lucide="${d.type === 'mobile' ? 'smartphone' : 'laptop'}" class="w-4 h-4"></i></div>
                        <div>
                            <div class="text-xs font-medium ${d.active ? 'text-gray-800' : 'text-gray-400'}">${d.name || d.mac}</div>
                            <div class="text-[10px] text-gray-400 font-mono">${d.ip}</div>
                        </div>
                    </div>
                </div>`).join('');
            if (typeof lucide !== 'undefined' && typeof lucide.createIcons === 'function') {
                lucide.createIcons();
            }
        }

        let domainData = { top: [], recent: [], realtime: [] };
        async function loadDomains() {
            const res = await apiRequest('domains');
            if (res) domainData = res;
            
            document.getElementById('domain-source').innerText = formatSourceLabel(domainData.source);
            document.getElementById('realtime-domain-source').innerText = formatSourceLabel(domainData.realtime_source);

            // 婵犵數鍋為幐绋款嚕閸洘鍋?闂備胶绮崺鍫ュ矗閸愩剮娑㈩敆閸曨偅妲梺缁樻閺€閬嶅磹?
            const topList = domainData.top || [];
            const maxTopCount = topList.reduce((max, item) => Math.max(max, item.count), 0);
            document.getElementById('top-domains-list').innerHTML = topList.slice(0, 10).map((item) => {
                const percent = maxTopCount > 0 ? (item.count / maxTopCount) * 100 : 0;
                return `
                <div class="mb-3 px-1 group cursor-default">
                    <div class="flex justify-between text-xs mb-1.5">
                        <span class="text-gray-600 truncate max-w-[75%] font-mono group-hover:text-blue-600 transition-colors">${item.domain}</span>
                        <span class="text-gray-800 font-medium">${item.count}</span>
                    </div>
                    <div class="w-full bg-gray-100 rounded-full h-1.5 overflow-hidden">
                        <div class="bg-blue-400 h-full rounded-full transition-all duration-700" style="width: ${percent}%"></div>
                    </div>
                </div>`;
            }).join('') || '<div class="text-center text-gray-400 text-xs mt-4">闂備礁鎼Λ妤呭磹閻熸嫈娑㈠Χ婢跺﹥鐎梺缁橆殔閻楀棛绮?/div>';

            // 婵犵數鍋為幐绋款嚕閸洘鍋?闂佽楠稿﹢閬嶅磻閻愬樊娓婚柛宀€鍋涢弰銉╂煟閺冨牊鏁遍柛?
            const rtList = domainData.realtime && domainData.realtime.length > 0 ? domainData.realtime : (domainData.recent || []);
            document.getElementById('recent-domains-list').innerHTML = rtList.slice(0, 25).map((item) => `
                <div class="flex items-center justify-between px-2 py-1.5 hover:bg-teal-50 rounded-md group transition-colors">
                    <div class="flex items-center space-x-2 truncate">
                        <div class="w-1.5 h-1.5 rounded-full bg-gray-300 group-hover:bg-teal-400"></div>
                        <div class="text-[11px] text-gray-600 truncate font-mono">${item.domain}</div>
                    </div>
                    <div class="text-[10px] text-gray-400 font-mono">${item.count}</div>
                </div>`).join('') || '<div class="text-center text-gray-400 text-xs mt-4">闂備礁鎼Λ妤呭磹閻熸嫈娑㈠Χ閸氥倛娅ｉ幏鐘诲箵閹?/div>';
        }

        const OAF_COLORS = ['bg-orange-500','bg-green-500','bg-blue-500','bg-pink-500','bg-yellow-400','bg-indigo-500'];
        async function loadActiveApps() {
            // Active app list now comes from unified databus payload.
            const databus = await apiRequest('databus');
            const appsElement = document.getElementById('active-apps-container');
            const cntElement = document.getElementById('app-count');
            const appState = pickActiveAppState(databus, null);
            const apps = appState.apps || [];
            const classStats = appState.classStats || [];
            
            if (apps.length > 0) {
                if (cntElement) cntElement.innerText = apps.length;
                appsElement.innerHTML = apps.slice(0, 12).map((app, i) => {
                    const color = OAF_COLORS[i % OAF_COLORS.length];
                    const iconHtml = app.icon 
                        ? `<img src="${app.icon}" class="w-8 h-8 rounded-lg" alt="${app.name}">` 
                        : `<span class="text-white text-lg font-bold">${app.name.charAt(0)}</span>`;
                        
                    return `
                    <div class="flex flex-col items-center gap-2 cursor-pointer group">
                        <div class="w-12 h-12 rounded-[14px] ${color} flex items-center justify-center shadow-sm group-hover:shadow-md transition-all duration-300 group-hover:-translate-y-1">
                            ${iconHtml}
                        </div>
                        <span class="text-[11px] font-medium text-gray-500 group-hover:text-gray-800 transition-colors w-14 text-center truncate">${app.name}</span>
                    </div>
                `}).join('');
            } else {
                if (cntElement) cntElement.innerText = "0";
                appsElement.innerHTML = '<div class="w-full text-center text-gray-400 text-xs mt-4">No active app data</div>';
            }
            
            // Update app distribution chart using normalized class stats from databus.
            if (typeof donutChart !== 'undefined' && classStats.length > 0) {
                donutChart.setOption({
                    series: [{
                        data: classStats.map(s => ({ name: s.name, value: Number(s.time) || 0 }))
                    }]
                });
            }
        }

        // Initialize charts
        const hasEcharts = typeof echarts !== 'undefined';
        const emptyChart = { setOption: function () {}, resize: function () {} };
        if (!hasEcharts) console.error('[Dashboard] echarts is not loaded.');
        const lineChart = hasEcharts ? echarts.init(document.getElementById('traffic-line-chart')) : emptyChart;
        lineChart.setOption({
            tooltip: { trigger: 'axis', backgroundColor: 'rgba(255, 255, 255, 0.95)', textStyle: { color: '#1e293b' }, formatter: function (p) {
                let r = `<div style="font-weight:bold;margin-bottom:4px;color:#475569;">${p[0].axisValue}</div>`;
                p.forEach(x => { r += `<div style="display:flex;align-items:center;margin-top:2px;"><span style="display:inline-block;margin-right:5px;border-radius:10px;width:9px;height:9px;background-color:${x.color};"></span><span style="margin-right:12px;color:#64748b;">${x.seriesName}:</span><span style="font-family:monospace;font-weight:500;color:#1e293b;">${formatBytes(x.value)}/s</span></div>`; });
                return r;
            }}, 
            legend: { data: ['Down', 'Up'], top: 0, itemWidth: 10, textStyle: { color: '#64748b' } },
            grid: { left: '1%', right: '2%', bottom: '0%', top: '15%', containLabel: true },
            xAxis: { type: 'category', boundaryGap: false, data: [], axisLine: { lineStyle: { color: '#cbd5e1' } }, axisLabel: { color: '#64748b' } },
            yAxis: { type: 'value', axisLabel: { formatter: (v) => formatBytes(v) + '/s', fontSize: 9, color: '#64748b' }, splitLine: { lineStyle: { color: '#e2e8f0', type: 'dashed' } } },
            series: [{ name: 'Down', type: 'line', smooth: true, symbol: 'none', itemStyle: { color: '#3b82f6' }, areaStyle: { color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [{ offset: 0, color: 'rgba(59, 130, 246, 0.3)' }, { offset: 1, color: 'rgba(59, 130, 246, 0.01)' }]) }, data: [] },
                     { name: 'Up', type: 'line', smooth: true, symbol: 'none', itemStyle: { color: '#10b981' }, areaStyle: { color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [{ offset: 0, color: 'rgba(16, 185, 129, 0.3)' }, { offset: 1, color: 'rgba(16, 185, 129, 0.01)' }]) }, data: [] }]
        });

        // 闂備胶绮划鐘诲垂娴煎瓨鍤嬪ù鍏兼綑閻?(闂佸湱鍘ч悺銊ヮ潖婵犳艾鏋侀柕鍫濐槸缁€鍡涙煕閳╁喚娈樻い?
        const donutChart = hasEcharts ? echarts.init(document.getElementById('app-dist-chart')) : emptyChart;
        donutChart.setOption({
            tooltip: { trigger: 'item' },
            color: ['#3b82f6', '#10b981', '#f59e0b', '#ec4899', '#8b5cf6', '#cbd5e1'],
            series: [{
                name: 'App Distribution',
                type: 'pie',
                radius: ['55%', '85%'],
                avoidLabelOverlap: false,
                itemStyle: { borderRadius: 4, borderColor: '#fff', borderWidth: 2 },
                label: { show: false, position: 'center' },
                emphasis: { label: { show: true, fontSize: 18, fontWeight: 'bold', formatter: '{d}%' } },
                labelLine: { show: false },
                data: [{ value: 100, name: 'Waiting for app stats' }]
            }]
        });

        window.addEventListener('resize', () => { lineChart.resize(); donutChart.resize(); });

        let tD = [], dD = [], uD = [], trafficState = null;
        async function refresh() {
            const sys = await apiRequest('sysinfo');
            if(sys) updateCpuMem(sys);
            const tr = await apiRequest('traffic');
            if (tr) {
                const now = Date.now();
                const sample = deriveTrafficSnapshot(tr, trafficState, now);
                const uS = Math.max(0, Number(sample.txRate) || 0);
                const dS = Math.max(0, Number(sample.rxRate) || 0);
                const tm = new Date().toTimeString().split(' ')[0];

                if (tD.length > 0 && tD[tD.length - 1] === tm) {
                    dD[dD.length - 1] = dS;
                    uD[uD.length - 1] = uS;
                } else {
                    tD.push(tm);
                    dD.push(dS);
                    uD.push(uS);
                    if (tD.length > 20) {
                        tD.shift();
                        dD.shift();
                        uD.shift();
                    }
                }
                lineChart.setOption({ xAxis: { data: tD }, series: [{ data: dD }, { data: uD }] });
                trafficState = sample.nextState;
                
                const fmtTx = formatBytes(tr.tx_bytes).split(' ');
                const fmtRx = formatBytes(tr.rx_bytes).split(' ');
                if(document.getElementById('summary-tx')) document.getElementById('summary-tx').innerText = fmtTx[0];
                if(document.getElementById('summary-tx-unit')) document.getElementById('summary-tx-unit').innerText = fmtTx[1];
                if(document.getElementById('summary-rx')) document.getElementById('summary-rx').innerText = fmtRx[0];
                if(document.getElementById('summary-rx-unit')) document.getElementById('summary-rx-unit').innerText = fmtRx[1];

                document.getElementById('total-up').innerText = formatBytes(uS) + '/s';
                document.getElementById('total-down').innerText = formatBytes(dS) + '/s';
            }
        }

        initNavButtons();
        loadStaticInfo(); loadDevices(); loadDomains(); loadActiveApps(); refresh();
        setInterval(refresh, 2000); setInterval(loadDomains, 5000); setInterval(loadActiveApps, 15000);
