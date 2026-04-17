import { buildSectionState } from './shell.js';
import { loadOverview } from './sections-overview.js';

const SECTION_META = {
  overview: {
    title: 'Overview',
    subtitle: 'Primary data source: /overview',
  },
  users: {
    title: 'Users',
    subtitle: 'Waiting for module wiring',
  },
  network: {
    title: 'Network',
    subtitle: 'Waiting for module wiring',
  },
  system: {
    title: 'System',
    subtitle: 'Waiting for module wiring',
  },
  record: {
    title: 'Record',
    subtitle: 'Waiting for module wiring',
  },
  feature: {
    title: 'Feature',
    subtitle: 'Waiting for module wiring',
  },
  settings: {
    title: 'Settings',
    subtitle: 'Waiting for module wiring',
  },
};

function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function formatNumber(value, suffix = '') {
  if (typeof value !== 'number' || Number.isNaN(value)) {
    return '-';
  }

  return `${value}${suffix}`;
}

function renderSectionFrame(sectionName, bodyHtml, badgeHtml = '') {
  const mount = document.querySelector(`[data-section="${sectionName}"]`);
  if (!mount) {
    return;
  }

  const meta = SECTION_META[sectionName];
  mount.innerHTML = `
    <div class="dashboard-panel-header">
      <div>
        <h2 class="dashboard-panel-title">${escapeHtml(meta.title)}</h2>
        <p class="dashboard-panel-subtitle">${escapeHtml(meta.subtitle)}</p>
      </div>
      ${badgeHtml}
    </div>
    <div class="dashboard-panel-body">${bodyHtml}</div>
  `;
}

function renderOverviewLoading() {
  renderSectionFrame(
    'overview',
    '<p class="dashboard-note">Loading overview from <code>/overview</code>...</p>',
    '<span class="dashboard-status-badge">Loading</span>'
  );
}

function renderOverviewError(error) {
  renderSectionFrame(
    'overview',
    `<p class="dashboard-note">Overview failed to load.</p><p class="dashboard-note is-muted">${escapeHtml(error.message || 'Unknown error')}</p>`,
    '<span class="dashboard-status-badge is-error">Error</span>'
  );
}

function renderOverviewContent(overview) {
  const dnsMarkup = overview.network.dns.length
    ? `<ul class="dashboard-list">${overview.network.dns.map((item) => `<li>${escapeHtml(item)}</li>`).join('')}</ul>`
    : '<p class="dashboard-note is-muted">No DNS servers reported.</p>';

  renderSectionFrame(
    'overview',
    `
      <div class="dashboard-overview-grid">
        <article class="dashboard-metric">
          <p class="dashboard-metric-label">WAN</p>
          <p class="dashboard-metric-value">${escapeHtml(overview.network.wanIp || '-')}</p>
        </article>
        <article class="dashboard-metric">
          <p class="dashboard-metric-label">LAN</p>
          <p class="dashboard-metric-value">${escapeHtml(overview.network.lanIp || '-')}</p>
        </article>
        <article class="dashboard-metric">
          <p class="dashboard-metric-label">Model</p>
          <p class="dashboard-metric-value">${escapeHtml(overview.system.model || '-')}</p>
        </article>
        <article class="dashboard-metric">
          <p class="dashboard-metric-label">Firmware</p>
          <p class="dashboard-metric-value">${escapeHtml(overview.system.firmware || '-')}</p>
        </article>
        <article class="dashboard-metric">
          <p class="dashboard-metric-label">CPU</p>
          <p class="dashboard-metric-value">${formatNumber(overview.system.cpuUsage, '%')}</p>
        </article>
        <article class="dashboard-metric">
          <p class="dashboard-metric-label">Memory</p>
          <p class="dashboard-metric-value">${formatNumber(overview.system.memUsage, '%')}</p>
        </article>
      </div>
      <div class="dashboard-overview-grid" style="margin-top: 12px;">
        <article class="dashboard-metric">
          <p class="dashboard-metric-label">DNS</p>
          ${dnsMarkup}
        </article>
        <article class="dashboard-metric">
          <p class="dashboard-metric-label">Traffic</p>
          <p class="dashboard-metric-value">RX ${formatNumber(overview.traffic.rx_bytes)} / TX ${formatNumber(overview.traffic.tx_bytes)}</p>
        </article>
        <article class="dashboard-metric">
          <p class="dashboard-metric-label">Devices</p>
          <p class="dashboard-metric-value">${formatNumber(overview.devices.length)}</p>
        </article>
        <article class="dashboard-metric">
          <p class="dashboard-metric-label">Capabilities</p>
          <p class="dashboard-metric-value">${overview.capabilities.nlbwmon ? 'nlbwmon enabled' : 'nlbwmon unavailable'}</p>
        </article>
      </div>
    `,
    '<span class="dashboard-status-badge">Live</span>'
  );
}

function renderPlaceholder(sectionName) {
  renderSectionFrame(
    sectionName,
    '<p class="dashboard-note">Pending integration.</p><p class="dashboard-note is-muted">This section is scaffolded and ready for its dedicated module.</p>'
  );
}

function refreshIcons() {
  if (window.lucide && typeof window.lucide.createIcons === 'function') {
    window.lucide.createIcons();
  }
}

async function bootstrapDashboard() {
  const container = document.getElementById('dashboard-app');
  if (!container) {
    return;
  }

  const state = buildSectionState();
  window.dashboardState = {
    state,
    overview: null,
  };

  for (const sectionName of ['users', 'network', 'system', 'record', 'feature', 'settings']) {
    renderPlaceholder(sectionName);
  }

  renderOverviewLoading();
  refreshIcons();

  state.overview.loading = true;

  try {
    const overview = await loadOverview();
    state.overview.loading = false;
    state.overview.loaded = true;
    window.dashboardState.overview = overview;
    renderOverviewContent(overview);
  } catch (error) {
    state.overview.loading = false;
    state.overview.error = error;
    renderOverviewError(error);
  }

  refreshIcons();
}

bootstrapDashboard();
