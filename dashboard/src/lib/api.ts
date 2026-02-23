import type { Task, NodeStatus, TaskEvent, OrgSettings, OverviewStats } from './types';
import { mockTasks, mockNodes, mockTaskEvents, mockSettings, getMockOverview } from './mock';

const API_BASE = import.meta.env.VITE_API_URL || '/api';
const USE_MOCK = import.meta.env.VITE_USE_MOCK !== 'false';

function getApiKey(): string | null {
  return localStorage.getItem('marathon_api_key');
}

export function setApiKey(key: string) {
  localStorage.setItem('marathon_api_key', key);
}

export function clearApiKey() {
  localStorage.removeItem('marathon_api_key');
}

export function hasApiKey(): boolean {
  return !!getApiKey();
}

async function apiFetch<T>(path: string, opts?: RequestInit): Promise<T> {
  const key = getApiKey();
  const res = await fetch(`${API_BASE}${path}`, {
    ...opts,
    headers: {
      'Content-Type': 'application/json',
      ...(key ? { 'X-API-Key': key } : {}),
      ...opts?.headers,
    },
  });
  if (!res.ok) throw new Error(`API error: ${res.status}`);
  return res.json();
}

// -- Overview
export async function fetchOverview(): Promise<OverviewStats> {
  if (USE_MOCK) return getMockOverview();
  return apiFetch('/overview');
}

// -- Tasks
export async function fetchTasks(): Promise<Task[]> {
  if (USE_MOCK) return mockTasks;
  return apiFetch('/tasks');
}

export async function fetchTask(id: string): Promise<Task> {
  if (USE_MOCK) {
    const t = mockTasks.find(t => t.id === id);
    if (!t) throw new Error('Task not found');
    return t;
  }
  return apiFetch(`/tasks/${id}`);
}

export async function fetchTaskEvents(id: string): Promise<TaskEvent[]> {
  if (USE_MOCK) return mockTaskEvents[id] || [];
  return apiFetch(`/tasks/${id}/events`);
}

export async function cancelTask(id: string): Promise<void> {
  if (USE_MOCK) return;
  await apiFetch(`/tasks/${id}/cancel`, { method: 'POST' });
}

// -- Nodes
export async function fetchNodes(): Promise<NodeStatus[]> {
  if (USE_MOCK) return mockNodes;
  return apiFetch('/nodes');
}

// -- Settings / Cost Controls
export async function fetchSettings(): Promise<OrgSettings> {
  if (USE_MOCK) return { ...mockSettings };
  return apiFetch('/settings');
}

export async function updateSettings(s: Partial<OrgSettings>): Promise<OrgSettings> {
  if (USE_MOCK) return { ...mockSettings, ...s };
  return apiFetch('/settings', { method: 'PUT', body: JSON.stringify(s) });
}

// -- WebSocket stub for future real-time streaming
export function connectTaskStream(_taskId: string): { close: () => void } {
  // TODO: implement WebSocket connection
  // const ws = new WebSocket(`${WS_BASE}/tasks/${taskId}/stream`);
  console.log('[ws] WebSocket stub - polling used instead');
  return { close: () => {} };
}
