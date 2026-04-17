import { dashboardApi } from './api.js';

function cloneList(value) {
  return Array.isArray(value) ? [...value] : [];
}

function mergeObject(defaults, value) {
  return {
    ...defaults,
    ...(value && typeof value === 'object' ? value : {}),
  };
}

export function normalizeOverview(raw) {
  const source = raw && typeof raw === 'object' ? raw : {};

  return {
    system: mergeObject(
      {
        model: '',
        firmware: '',
        kernel: '',
        uptime_raw: 0,
        cpuUsage: 0,
        memUsage: 0,
        temp: 0,
        systime_raw: 0,
        hasSamba4: false,
      },
      source.system
    ),
    network: {
      ...mergeObject(
        {
          wanStatus: 'down',
          wanIp: '',
          lanIp: '',
          dns: [],
          network_uptime_raw: 0,
        },
        source.network
      ),
      dns: cloneList(source.network && source.network.dns),
    },
    traffic: mergeObject(
      {
        tx_bytes: 0,
        rx_bytes: 0,
      },
      source.traffic
    ),
    devices: cloneList(source.devices),
    domains: {
      ...mergeObject(
        {
          source: 'none',
          top: [],
          recent: [],
        },
        source.domains
      ),
      top: cloneList(source.domains && source.domains.top),
      recent: cloneList(source.domains && source.domains.recent),
    },
    capabilities: mergeObject(
      {
        nlbwmon: false,
        samba4: false,
        domain_logs: false,
        feature_library: false,
        history_store: false,
      },
      source.capabilities
    ),
  };
}

export async function loadOverview() {
  const raw = await dashboardApi('/overview');
  return normalizeOverview(raw);
}
