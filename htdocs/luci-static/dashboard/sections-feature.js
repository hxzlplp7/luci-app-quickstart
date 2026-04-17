import { dashboardApi } from './api.js';

export async function loadFeatureInfo() {
  return dashboardApi('/feature/info');
}

export async function loadFeatureClasses() {
  return dashboardApi('/feature/classes');
}

export async function uploadFeatureBundle(file) {
  const body = new FormData();
  body.append('file', file);

  return dashboardApi('/feature/upload', {
    method: 'POST',
    body,
  });
}
