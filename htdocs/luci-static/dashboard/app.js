import { buildSectionState } from './shell.js';
import { loadOverview } from './sections-overview.js';
import { loadUsers } from './sections-users.js';

export const registeredSections = ['overview'];

const EMPTY_USERS = {
  page: 1,
  page_size: 20,
  total_num: 0,
  list: [],
};

const DOMAIN_COLORS = ['#2563eb', '#10b981', '#f59e0b', '#8b5cf6', '#ef4444'];

function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function formatBytes(value) {
  if (typeof value !== 'number' || Number.isNaN(value) || value < 0) {
    return '-';
  }

  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let current = value;
  let index = 0;

  while (current >= 1024 && index < units.length - 1) {
    current /= 1024;
    index += 1;
  }

  const precision = current >= 100 || index === 0 ? 0 : current >= 10 ? 1 : 2;
  return `${current.toFixed(precision)} ${units[index]}`;
}

function formatDuration(seconds) {
  if (typeof seconds !== 'number' || Number.isNaN(seconds) || seconds < 0) {
    return '-';
  }

  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);

  if (days > 0) {
    return `${days}天 ${hours}小时`;
  }

  if (hours > 0) {
    return `${hours}小时 ${minutes}分钟`;
  }

  return `${minutes}分钟`;
}

function formatPercent(value) {
  if (typeof value !== 'number' || Number.isNaN(value)) {
    return '-';
  }

  return `${Math.round(value)}%`;
}

function formatTemperature(value) {
  if (typeof value !== 'number' || Number.isNaN(value) || value <= 0) {
    return '-';
  }

  return `${Math.round(value)}°C`;
}

function getUserDisplayName(user) {
  return user.nickname || user.hostname || user.ip || user.mac || '未知终端';
}

function getUserTrafficTotal(user) {
  const traffic = user && user.traffic ? user.traffic : {};
  return (Number(traffic.today_down_bytes) || 0) + (Number(traffic.today_up_bytes) || 0);
}

function buildDomainGradient(entries) {
  if (!entries.length) {
    return '';
  }

  const total = entries.reduce((sum, item) => sum + item.count, 0) || 1;
  let progress = 0;

  return entries
    .map((item) => {
      const start = (progress / total) * 360;
      progress += item.count;
      const end = (progress / total) * 360;
      return `${item.color} ${start.toFixed(2)}deg ${end.toFixed(2)}deg`;
    })
    .join(', ');
}

export function applySavedRemarkResult(dashboard, targetMac, targetValue) {
  if (!dashboard || !targetMac) {
    return dashboard;
  }

  if (dashboard.users && Array.isArray(dashboard.users.list)) {
    dashboard.users.list = dashboard.users.list.map((item) =>
      item.mac === targetMac ? { ...item, nickname: targetValue } : item
    );
  }

  if (
    dashboard.userDrawer &&
    dashboard.userDrawer.open &&
    dashboard.userDrawer.mac === targetMac &&
    dashboard.userDrawer.detail
  ) {
    dashboard.userDrawer.detail = {
      ...dashboard.userDrawer.detail,
      device: {
        ...dashboard.userDrawer.detail.device,
        nickname: targetValue,
      },
    };
  }

  return dashboard;
}

export function buildDashboardViewModel(overview, users = EMPTY_USERS) {
  const userList = Array.isArray(users.list) ? [...users.list] : [];
  const rankedUsers = userList
    .map((user) => ({
      ...user,
      total_bytes: getUserTrafficTotal(user),
    }))
    .sort((left, right) => right.total_bytes - left.total_bytes)
    .slice(0, 5);

  const topDomains = (overview.domains && Array.isArray(overview.domains.top) ? overview.domains.top : [])
    .map((entry, index) => ({
      domain: String(entry.domain || 'unknown'),
      count: Number(entry.count) || 0,
      color: DOMAIN_COLORS[index % DOMAIN_COLORS.length],
    }))
    .filter((entry) => entry.count > 0)
    .slice(0, 5);

  const recentDomains = (
    overview.domains && Array.isArray(overview.domains.recent) ? overview.domains.recent : []
  )
    .map((entry) => {
      if (typeof entry === 'string') {
        return { domain: entry, count: 1 };
      }

      return {
        domain: String(entry.domain || 'unknown'),
        count: Number(entry.count) || 1,
      };
    })
    .filter((entry) => entry.domain);

  const activeDomains = (topDomains.length ? topDomains : recentDomains.slice(0, 8)).map((entry) => ({
    domain: entry.domain,
    count: entry.count,
  }));

  const capabilityItems = [
    { label: '域名日志', enabled: Boolean(overview.capabilities.domain_logs) },
    { label: '流量监控', enabled: Boolean(overview.capabilities.nlbwmon) },
    { label: '特征库', enabled: Boolean(overview.capabilities.feature_library) },
    { label: '历史存储', enabled: Boolean(overview.capabilities.history_store) },
  ];

  const totalUserDownload = rankedUsers.reduce(
    (sum, user) => sum + (Number(user.traffic && user.traffic.today_down_bytes) || 0),
    0
  );
  const totalUserUpload = rankedUsers.reduce(
    (sum, user) => sum + (Number(user.traffic && user.traffic.today_up_bytes) || 0),
    0
  );

  return {
    hero: {
      model: overview.system.model || '未知设备',
      firmware: overview.system.firmware || '-',
      uptime: formatDuration(overview.system.uptime_raw),
      wanStatus: overview.network.wanStatus === 'up' ? '已联网' : '未联网',
      wanOnline: overview.network.wanStatus === 'up',
    },
    metrics: [
      {
        label: '联网状态',
        value: overview.network.wanStatus === 'up' ? '已联网' : '未联网',
        tone: overview.network.wanStatus === 'up' ? 'positive' : 'warning',
      },
      {
        label: '在线终端',
        value: String(users.total_num || userList.length || overview.devices.length || 0),
      },
      {
        label: '已识别设备',
        value: String(overview.devices.length || 0),
      },
      {
        label: '活跃域名',
        value: String(activeDomains.length || 0),
      },
      {
        label: '累计下行',
        value: formatBytes(Number(overview.traffic.rx_bytes) || 0),
      },
      {
        label: '累计上行',
        value: formatBytes(Number(overview.traffic.tx_bytes) || 0),
      },
    ],
    resourceMeters: [
      {
        label: 'CPU',
        value: clamp(Number(overview.system.cpuUsage) || 0, 0, 100),
        display: formatPercent(Number(overview.system.cpuUsage) || 0),
        color: '#2563eb',
      },
      {
        label: '内存',
        value: clamp(Number(overview.system.memUsage) || 0, 0, 100),
        display: formatPercent(Number(overview.system.memUsage) || 0),
        color: '#10b981',
      },
      {
        label: '温度',
        value: clamp(Number(overview.system.temp) || 0, 0, 100),
        display: formatTemperature(Number(overview.system.temp) || 0),
        color: '#f59e0b',
      },
    ],
    systemInfo: [
      ['设备型号', overview.system.model || '-'],
      ['固件版本', overview.system.firmware || '-'],
      ['内核版本', overview.system.kernel || '-'],
      ['运行时间', formatDuration(overview.system.uptime_raw)],
    ],
    networkInfo: [
      ['LAN IP', overview.network.lanIp || '-'],
      ['WAN IP', overview.network.wanIp || '-'],
      ['DNS', overview.network.dns.length ? overview.network.dns.join(', ') : '-'],
      ['域名源', overview.domains.source || 'none'],
    ],
    rankedUsers,
    userTrafficSummary: {
      download: formatBytes(totalUserDownload),
      upload: formatBytes(totalUserUpload),
    },
    maxUserTraffic: rankedUsers.length ? rankedUsers[0].total_bytes || 1 : 1,
    activeDomains,
    recentDomains: recentDomains.slice(0, 6),
    domainBreakdown: topDomains,
    domainGradient: buildDomainGradient(topDomains),
    capabilities: capabilityItems,
  };
}

function renderLoading() {
  const mount = document.querySelector('[data-section="overview"]');
  if (!mount) {
    return;
  }

  mount.innerHTML = `
    <div class="dashboard-home dashboard-home--loading">
      <div class="dashboard-skeleton dashboard-skeleton--hero"></div>
      <div class="dashboard-skeleton-grid">
        <div class="dashboard-skeleton"></div>
        <div class="dashboard-skeleton"></div>
        <div class="dashboard-skeleton"></div>
        <div class="dashboard-skeleton"></div>
      </div>
      <div class="dashboard-skeleton-grid dashboard-skeleton-grid--main">
        <div class="dashboard-skeleton dashboard-skeleton--panel"></div>
        <div class="dashboard-skeleton dashboard-skeleton--panel"></div>
      </div>
    </div>
  `;
}

function renderError(error) {
  const mount = document.querySelector('[data-section="overview"]');
  if (!mount) {
    return;
  }

  mount.innerHTML = `
    <div class="dashboard-home">
      <section class="dashboard-error-card">
        <p class="dashboard-eyebrow">Dashboard</p>
        <h1 class="dashboard-error-title">首页数据加载失败</h1>
        <p class="dashboard-error-copy">${escapeHtml(error.message || 'Unknown error')}</p>
      </section>
    </div>
  `;
}

function renderMetrics(metrics) {
  return metrics
    .map(
      (item) => `
        <article class="dashboard-stat-card">
          <p class="dashboard-stat-label">${escapeHtml(item.label)}</p>
          <p class="dashboard-stat-value${item.tone ? ` is-${escapeHtml(item.tone)}` : ''}">${escapeHtml(item.value)}</p>
        </article>
      `
    )
    .join('');
}

function renderResourceMeters(resourceMeters) {
  return resourceMeters
    .map(
      (item) => `
        <div class="dashboard-meter">
          <div class="dashboard-meter-ring" style="--meter-value:${item.value};--meter-color:${item.color};">
            <span>${escapeHtml(item.display)}</span>
          </div>
          <p>${escapeHtml(item.label)}</p>
        </div>
      `
    )
    .join('');
}

function renderKeyValueList(items) {
  return items
    .map(
      ([label, value]) => `
        <div class="dashboard-kv-row">
          <dt>${escapeHtml(label)}</dt>
          <dd>${escapeHtml(value)}</dd>
        </div>
      `
    )
    .join('');
}

function renderTrafficRanking(viewModel) {
  if (!viewModel.rankedUsers.length) {
    return '<p class="dashboard-empty-copy">暂无终端流量数据。</p>';
  }

  return viewModel.rankedUsers
    .map((user, index) => {
      const downBytes = Number(user.traffic && user.traffic.today_down_bytes) || 0;
      const upBytes = Number(user.traffic && user.traffic.today_up_bytes) || 0;
      const downWidth = clamp((downBytes / viewModel.maxUserTraffic) * 100, 8, 100);
      const upWidth = upBytes > 0 ? clamp((upBytes / viewModel.maxUserTraffic) * 100, 4, 100) : 0;

      return `
        <div class="dashboard-traffic-row">
          <div class="dashboard-traffic-rank">${index + 1}</div>
          <div class="dashboard-traffic-main">
            <div class="dashboard-traffic-head">
              <strong>${escapeHtml(getUserDisplayName(user))}</strong>
              <span>${escapeHtml(formatBytes(user.total_bytes))}</span>
            </div>
            <div class="dashboard-traffic-bars">
              <div class="dashboard-traffic-bar">
                <span class="dashboard-traffic-bar-fill is-down" style="width:${downWidth}%;"></span>
              </div>
              <div class="dashboard-traffic-bar">
                <span class="dashboard-traffic-bar-fill is-up" style="width:${upWidth}%;"></span>
              </div>
            </div>
            <div class="dashboard-traffic-meta">
              <span>下行 ${escapeHtml(formatBytes(downBytes))}</span>
              <span>上行 ${escapeHtml(formatBytes(upBytes))}</span>
            </div>
          </div>
        </div>
      `;
    })
    .join('');
}

function renderActiveDomains(viewModel) {
  if (!viewModel.activeDomains.length) {
    return '<p class="dashboard-empty-copy">暂无域名数据。</p>';
  }

  return viewModel.activeDomains
    .map(
      (item) => `
        <span class="dashboard-chip">
          <strong>${escapeHtml(item.domain)}</strong>
          <em>${escapeHtml(String(item.count))}</em>
        </span>
      `
    )
    .join('');
}

function renderDomainBreakdown(viewModel) {
  if (!viewModel.domainBreakdown.length) {
    return `
      <div class="dashboard-domain-empty">
        <div class="dashboard-domain-empty-ring"></div>
        <p class="dashboard-empty-copy">当前没有可绘制的域名分布。</p>
      </div>
    `;
  }

  const legend = viewModel.domainBreakdown
    .map(
      (item) => `
        <li>
          <span class="dashboard-domain-dot" style="background:${item.color};"></span>
          <strong>${escapeHtml(item.domain)}</strong>
          <em>${escapeHtml(String(item.count))}</em>
        </li>
      `
    )
    .join('');

  return `
    <div class="dashboard-domain-grid">
      <div class="dashboard-domain-ring" style="background:conic-gradient(${viewModel.domainGradient});">
        <div class="dashboard-domain-center">
          <span>${escapeHtml(String(viewModel.domainBreakdown.length))}</span>
          <small>热点域名</small>
        </div>
      </div>
      <ul class="dashboard-domain-legend">${legend}</ul>
    </div>
  `;
}

function renderRecentDomains(viewModel) {
  if (!viewModel.recentDomains.length) {
    return '<p class="dashboard-empty-copy">最近没有域名访问记录。</p>';
  }

  return `
    <ul class="dashboard-recent-list">
      ${viewModel.recentDomains
        .map(
          (item) => `
            <li>
              <strong>${escapeHtml(item.domain)}</strong>
              <span>${escapeHtml(String(item.count))} 次</span>
            </li>
          `
        )
        .join('')}
    </ul>
  `;
}

function renderCapabilities(viewModel) {
  return `
    <ul class="dashboard-capability-list">
      ${viewModel.capabilities
        .map(
          (item) => `
            <li class="${item.enabled ? 'is-enabled' : 'is-disabled'}">
              <span>${escapeHtml(item.label)}</span>
              <strong>${item.enabled ? '已启用' : '未启用'}</strong>
            </li>
          `
        )
        .join('')}
    </ul>
  `;
}

function renderOverviewContent(overview, users) {
  const mount = document.querySelector('[data-section="overview"]');
  if (!mount) {
    return;
  }

  const viewModel = buildDashboardViewModel(overview, users);

  mount.innerHTML = `
    <div class="dashboard-home">
      <section class="dashboard-hero-card">
        <div>
          <p class="dashboard-eyebrow">FanchmWrt Dashboard</p>
          <h1 class="dashboard-hero-title">首页总览</h1>
          <p class="dashboard-hero-copy">
            当前设备为 <strong>${escapeHtml(viewModel.hero.model)}</strong>，
            固件 <strong>${escapeHtml(viewModel.hero.firmware)}</strong>，
            已运行 <strong>${escapeHtml(viewModel.hero.uptime)}</strong>。
          </p>
        </div>
        <div class="dashboard-hero-side">
          <span class="dashboard-live-pill${viewModel.hero.wanOnline ? '' : ' is-warning'}">${escapeHtml(
            viewModel.hero.wanStatus
          )}</span>
          <div class="dashboard-hero-network">
            <span>LAN ${escapeHtml(overview.network.lanIp || '-')}</span>
            <span>WAN ${escapeHtml(overview.network.wanIp || '-')}</span>
          </div>
        </div>
      </section>

      <section class="dashboard-stat-grid">
        ${renderMetrics(viewModel.metrics)}
      </section>

      <section class="dashboard-layout">
        <div class="dashboard-main-column">
          <article class="dashboard-card dashboard-card--feature">
            <div class="dashboard-card-head">
              <div>
                <p class="dashboard-card-kicker">Flow Ranking</p>
                <h2>终端流量排行</h2>
              </div>
              <div class="dashboard-card-summary">
                <span>下行 ${escapeHtml(viewModel.userTrafficSummary.download)}</span>
                <span>上行 ${escapeHtml(viewModel.userTrafficSummary.upload)}</span>
              </div>
            </div>
            <div class="dashboard-traffic-legend">
              <span><i class="is-down"></i>下行</span>
              <span><i class="is-up"></i>上行</span>
            </div>
            <div class="dashboard-traffic-list">
              ${renderTrafficRanking(viewModel)}
            </div>
          </article>

          <article class="dashboard-card">
            <div class="dashboard-card-head">
              <div>
                <p class="dashboard-card-kicker">Live Domains</p>
                <h2>活跃域名</h2>
              </div>
            </div>
            <div class="dashboard-chip-row">
              ${renderActiveDomains(viewModel)}
            </div>
          </article>

          <div class="dashboard-bottom-grid">
            <article class="dashboard-card">
              <div class="dashboard-card-head">
                <div>
                  <p class="dashboard-card-kicker">Domain Mix</p>
                  <h2>域名分布</h2>
                </div>
              </div>
              ${renderDomainBreakdown(viewModel)}
            </article>

            <article class="dashboard-card">
              <div class="dashboard-card-head">
                <div>
                  <p class="dashboard-card-kicker">Recent URLs</p>
                  <h2>活跃 URL</h2>
                </div>
              </div>
              ${renderRecentDomains(viewModel)}
            </article>
          </div>
        </div>

        <aside class="dashboard-side-column">
          <article class="dashboard-card">
            <div class="dashboard-card-head">
              <div>
                <p class="dashboard-card-kicker">System</p>
                <h2>系统信息</h2>
              </div>
            </div>
            <dl class="dashboard-kv-list">
              ${renderKeyValueList(viewModel.systemInfo)}
            </dl>
          </article>

          <article class="dashboard-card">
            <div class="dashboard-card-head">
              <div>
                <p class="dashboard-card-kicker">Status</p>
                <h2>运行状态</h2>
              </div>
            </div>
            <div class="dashboard-meter-row">
              ${renderResourceMeters(viewModel.resourceMeters)}
            </div>
          </article>

          <article class="dashboard-card">
            <div class="dashboard-card-head">
              <div>
                <p class="dashboard-card-kicker">Network</p>
                <h2>网络信息</h2>
              </div>
            </div>
            <dl class="dashboard-kv-list">
              ${renderKeyValueList(viewModel.networkInfo)}
            </dl>
          </article>

          <article class="dashboard-card">
            <div class="dashboard-card-head">
              <div>
                <p class="dashboard-card-kicker">Capability</p>
                <h2>监测能力</h2>
              </div>
            </div>
            ${renderCapabilities(viewModel)}
          </article>
        </aside>
      </section>
    </div>
  `;
}

export async function bootstrapDashboard() {
  if (typeof document === 'undefined' || typeof document.getElementById !== 'function') {
    return;
  }

  const container = document.getElementById('dashboard-app');
  if (!container) {
    return;
  }

  window.dashboardState = {
    state: buildSectionState(),
    overview: null,
    users: EMPTY_USERS,
  };

  renderLoading();

  const [overviewResult, usersResult] = await Promise.allSettled([loadOverview(), loadUsers()]);
  if (overviewResult.status !== 'fulfilled') {
    renderError(overviewResult.reason);
    return;
  }

  const overview = overviewResult.value;
  const users = usersResult.status === 'fulfilled' ? usersResult.value : EMPTY_USERS;
  window.dashboardState.overview = overview;
  window.dashboardState.users = users;
  renderOverviewContent(overview, users);
}

bootstrapDashboard();
