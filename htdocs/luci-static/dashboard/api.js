const API_BASE = '/cgi-bin/luci/admin/dashboard/api';

export async function dashboardApi(path, options = {}) {
  const requestPath = path.startsWith('/') ? path : `/${path}`;
  const headers = {
    Accept: 'application/json',
    ...(options.headers || {}),
  };

  const response = await fetch(`${API_BASE}${requestPath}`, {
    credentials: 'same-origin',
    ...options,
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
    const message = payload && payload.error ? payload.error : `Dashboard API request failed with HTTP ${response.status}`;
    throw new Error(message);
  }

  if (!payload || payload.ok === false) {
    throw new Error((payload && payload.error) || 'Dashboard API request failed');
  }

  return payload.data;
}
