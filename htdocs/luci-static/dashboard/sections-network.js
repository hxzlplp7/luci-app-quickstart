import { dashboardApi } from './api.js';

function normalizeLanConfig(raw) {
  const source = raw && typeof raw === 'object' ? raw : {};

  return {
    proto: String(source.proto || ''),
    ipaddr: String(source.ipaddr || ''),
    netmask: String(source.netmask || ''),
    gateway: String(source.gateway || ''),
    dns: Array.isArray(source.dns) ? [...source.dns] : [],
    lan_ifname: String(source.lan_ifname || ''),
  };
}

function normalizeWanConfig(raw) {
  const source = raw && typeof raw === 'object' ? raw : {};

  return {
    proto: String(source.proto || ''),
    ipaddr: String(source.ipaddr || ''),
    netmask: String(source.netmask || ''),
    gateway: String(source.gateway || ''),
    dns: Array.isArray(source.dns) ? [...source.dns] : [],
    username: String(source.username || ''),
    password: String(source.password || ''),
  };
}

function normalizeWorkMode(raw) {
  const source = raw && typeof raw === 'object' ? raw : {};

  return {
    work_mode: String(source.work_mode || ''),
  };
}

function encodeBody(fields) {
  return new URLSearchParams(fields).toString();
}

export async function loadLanConfig() {
  return normalizeLanConfig(await dashboardApi('/network/lan'));
}

export async function saveLanConfig(payload) {
  const source = payload && typeof payload === 'object' ? payload : {};
  const dns = Array.isArray(source.dns) ? source.dns.join(',') : String(source.dns || '');

  return normalizeLanConfig(
    await dashboardApi('/network/lan', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
      },
      body: encodeBody({
        proto: source.proto || '',
        ipaddr: source.ipaddr || '',
        netmask: source.netmask || '',
        gateway: source.gateway || '',
        dns,
        lan_ifname: source.lan_ifname || '',
      }),
    })
  );
}

export async function loadWanConfig() {
  return normalizeWanConfig(await dashboardApi('/network/wan'));
}

export async function saveWanConfig(payload) {
  const source = payload && typeof payload === 'object' ? payload : {};
  const dns = Array.isArray(source.dns) ? source.dns.join(',') : String(source.dns || '');

  return normalizeWanConfig(
    await dashboardApi('/network/wan', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
      },
      body: encodeBody({
        proto: source.proto || '',
        ipaddr: source.ipaddr || '',
        netmask: source.netmask || '',
        gateway: source.gateway || '',
        dns,
        username: source.username || '',
        password: source.password || '',
      }),
    })
  );
}

export async function loadWorkMode() {
  return normalizeWorkMode(await dashboardApi('/network/work-mode'));
}

export async function saveWorkMode(payload) {
  const source = payload && typeof payload === 'object' ? payload : {};

  return normalizeWorkMode(
    await dashboardApi('/network/work-mode', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
      },
      body: encodeBody({
        work_mode: source.work_mode || '',
      }),
    })
  );
}
