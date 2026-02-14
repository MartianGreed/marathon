const API_BASE = import.meta.env.VITE_API_URL || '';

interface AuthResponse {
  success: boolean;
  token?: string;
  api_key?: string;
  message: string;
}

interface Task {
  id: string;
  state: string;
  repo_url: string;
  branch: string;
  prompt: string;
  created_at: number;
  started_at?: number;
  completed_at?: number;
  error_message?: string;
  pr_url?: string;
  usage?: {
    input_tokens: number;
    output_tokens: number;
    compute_time_ms: number;
    tool_calls: number;
  };
}

interface UsageReport {
  total_input_tokens: number;
  total_output_tokens: number;
  total_compute_time_ms: number;
  total_tool_calls: number;
  task_count: number;
}

function getToken(): string | null {
  return localStorage.getItem('marathon_token');
}

function getHeaders(): Record<string, string> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  const token = getToken();
  if (token) headers['Authorization'] = `Bearer ${token}`;
  return headers;
}

export async function register(email: string, password: string): Promise<AuthResponse> {
  const res = await fetch(`${API_BASE}/auth/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  const data = await res.json();
  if (data.token) {
    localStorage.setItem('marathon_token', data.token);
    localStorage.setItem('marathon_email', email);
    if (data.api_key) localStorage.setItem('marathon_api_key', data.api_key);
  }
  return data;
}

export async function login(email: string, password: string): Promise<AuthResponse> {
  const res = await fetch(`${API_BASE}/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  const data = await res.json();
  if (data.token) {
    localStorage.setItem('marathon_token', data.token);
    localStorage.setItem('marathon_email', email);
    if (data.api_key) localStorage.setItem('marathon_api_key', data.api_key);
  }
  return data;
}

export function logout() {
  localStorage.removeItem('marathon_token');
  localStorage.removeItem('marathon_email');
  localStorage.removeItem('marathon_api_key');
}

export function isAuthenticated(): boolean {
  return !!getToken();
}

export function getEmail(): string | null {
  return localStorage.getItem('marathon_email');
}

export async function listTasks(): Promise<Task[]> {
  const res = await fetch(`${API_BASE}/tasks`, { headers: getHeaders() });
  if (!res.ok) throw new Error('Failed to fetch tasks');
  return res.json();
}

export async function getTask(id: string): Promise<Task> {
  const res = await fetch(`${API_BASE}/tasks/${id}`, { headers: getHeaders() });
  if (!res.ok) throw new Error('Failed to fetch task');
  return res.json();
}

export async function getUsage(): Promise<UsageReport> {
  const res = await fetch(`${API_BASE}/usage`, { headers: getHeaders() });
  if (!res.ok) throw new Error('Failed to fetch usage');
  return res.json();
}

export type { Task, UsageReport, AuthResponse };
