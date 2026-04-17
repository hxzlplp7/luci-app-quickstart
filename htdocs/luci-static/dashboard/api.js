const DEFAULT_API_BASE = '/cgi-bin/luci/admin/dashboard/api';

function resolveMount() {
  if (typeof document !== 'undefined' && typeof document.getElementById === 'function') {
    return document.getElementById('dashboard-app');
  }

  return null;
}

function readErrorMessage(error, fallbackMessage) {
  if (typeof error === 'string' && error) {
    return error;
  }

  if (error && typeof error === 'object') {
    if (typeof error.message === 'string' && error.message) {
      return error.message;
    }

    if (typeof error.code === 'string' && error.code) {
      return error.code;
    }
  }

  return fallbackMessage;
}

function resolveApiBase() {
  const mount = resolveMount();
  if (mount && mount.dataset && mount.dataset.apiBase) {
    return mount.dataset.apiBase;
  }

  return DEFAULT_API_BASE;
}

function resolveSessionToken() {
  const mount = resolveMount();
  if (mount && mount.dataset && mount.dataset.sessionToken) {
    return mount.dataset.sessionToken;
  }

  return '';
}

function resolveMethod(options) {
  return String((options && options.method) || 'GET').toUpperCase();
}

export async function dashboardApi(path, options = {}) {
  const requestPath = path.startsWith('/') ? path : `/${path}`;
  const method = resolveMethod(options);
  const headers = {
    Accept: 'application/json',
    ...(options.headers || {}),
  };
  const sessionToken = resolveSessionToken();

  if (method !== 'GET' && method !== 'HEAD' && sessionToken && !headers['X-Dashboard-CSRF-Token']) {
    headers['X-Dashboard-CSRF-Token'] = sessionToken;
  }

  const response = await fetch(`${resolveApiBase()}${requestPath}`, {
    credentials: 'same-origin',
    ...options,
    method,
    headers,
  });

  let payload = null;
  try {
    payload = await response.json();
  } catch (error) {
    if (!response.ok) {
      throw new Error(`Dashboard API request failed with HTTP ${response.status}`);
    }
    throw new Error('Dashboard API returned invalid JSON');
  }

  if (!response.ok) {
    const message = readErrorMessage(
      payload && payload.error,
      `Dashboard API request failed with HTTP ${response.status}`
    );
    throw new Error(message);
  }

  if (!payload || payload.ok === false) {
    throw new Error(readErrorMessage(payload && payload.error, 'Dashboard API request failed'));
  }

  return payload.data;
}
