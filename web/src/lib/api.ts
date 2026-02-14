const API_BASE = import.meta.env.VITE_API_URL || 'http://localhost:8081';

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

interface Workspace {
  id: string;
  name: string;
  description?: string;
  template?: string;
  settings: string; // JSON string
  created_at: number;
  updated_at: number;
  last_accessed_at: number;
}

interface WorkspaceSummary {
  id: string;
  name: string;
  description?: string;
  template?: string;
  created_at: number;
  last_accessed_at: number;
  task_count: number;
  is_active: boolean;
}

interface WorkspaceTemplate {
  id: string;
  name: string;
  description?: string;
  default_settings: string; // JSON string
  default_env_vars: string; // JSON string
  created_at: number;
}

interface EnvVar {
  key: string;
  value: string;
}

interface WorkspaceWithEnvVars {
  workspace: Workspace;
  env_vars: EnvVar[];
}

interface WorkspaceCreateRequest {
  name: string;
  description?: string;
  template?: string;
  settings?: string;
}

interface WorkspaceUpdateRequest {
  workspace_id: string;
  name?: string;
  description?: string;
  settings?: string;
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
  localStorage.removeItem('marathon_current_workspace');
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

// Workspace API functions
export async function listWorkspaces(limit: number = 50, offset: number = 0): Promise<{
  workspaces: WorkspaceSummary[];
  total_count: number;
  current_workspace_id?: string;
}> {
  const res = await fetch(`${API_BASE}/workspaces?limit=${limit}&offset=${offset}`, {
    headers: getHeaders()
  });
  if (!res.ok) throw new Error('Failed to fetch workspaces');
  return res.json();
}

export async function createWorkspace(request: WorkspaceCreateRequest): Promise<WorkspaceWithEnvVars> {
  const res = await fetch(`${API_BASE}/workspaces`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify(request),
  });
  if (!res.ok) throw new Error('Failed to create workspace');
  const data = await res.json();
  if (data.workspace) {
    // Set as current workspace in localStorage
    localStorage.setItem('marathon_current_workspace', data.workspace.id);
  }
  return data;
}

export async function getWorkspace(id?: string, name?: string): Promise<WorkspaceWithEnvVars | null> {
  let url = `${API_BASE}/workspaces/`;
  const params = new URLSearchParams();
  if (id) params.set('id', id);
  if (name) params.set('name', name);
  
  if (params.toString()) {
    url += `?${params.toString()}`;
  } else {
    url += 'current';
  }

  const res = await fetch(url, { headers: getHeaders() });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error('Failed to fetch workspace');
  return res.json();
}

export async function getCurrentWorkspace(): Promise<WorkspaceWithEnvVars | null> {
  return getWorkspace();
}

export async function updateWorkspace(request: WorkspaceUpdateRequest): Promise<WorkspaceWithEnvVars> {
  const res = await fetch(`${API_BASE}/workspaces/${request.workspace_id}`, {
    method: 'PUT',
    headers: getHeaders(),
    body: JSON.stringify(request),
  });
  if (!res.ok) throw new Error('Failed to update workspace');
  return res.json();
}

export async function deleteWorkspace(workspaceId: string): Promise<void> {
  const res = await fetch(`${API_BASE}/workspaces/${workspaceId}`, {
    method: 'DELETE',
    headers: getHeaders(),
  });
  if (!res.ok) throw new Error('Failed to delete workspace');
}

export async function switchWorkspace(workspaceId?: string, name?: string): Promise<void> {
  const body: any = {};
  if (workspaceId) body.workspace_id = workspaceId;
  if (name) body.name = name;

  const res = await fetch(`${API_BASE}/workspaces/switch`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error('Failed to switch workspace');
  
  // Update localStorage with new active workspace
  if (workspaceId) {
    localStorage.setItem('marathon_current_workspace', workspaceId);
  } else if (name) {
    // Get the workspace ID by name and store it
    const workspace = await getWorkspace(undefined, name);
    if (workspace) {
      localStorage.setItem('marathon_current_workspace', workspace.workspace.id);
    }
  }
}

export async function getWorkspaceTemplates(): Promise<WorkspaceTemplate[]> {
  const res = await fetch(`${API_BASE}/workspaces/templates`, {
    headers: getHeaders()
  });
  if (!res.ok) throw new Error('Failed to fetch workspace templates');
  const data = await res.json();
  return data.templates;
}

export async function setWorkspaceEnvVar(workspaceId: string, key: string, value: string): Promise<void> {
  const res = await fetch(`${API_BASE}/workspaces/${workspaceId}/env`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify({ key, value }),
  });
  if (!res.ok) throw new Error('Failed to set environment variable');
}

export async function deleteWorkspaceEnvVar(workspaceId: string, key: string): Promise<void> {
  const res = await fetch(`${API_BASE}/workspaces/${workspaceId}/env/${encodeURIComponent(key)}`, {
    method: 'DELETE',
    headers: getHeaders(),
  });
  if (!res.ok) throw new Error('Failed to delete environment variable');
}

export function getCurrentWorkspaceId(): string | null {
  return localStorage.getItem('marathon_current_workspace');
}

export type { 
  Task, 
  UsageReport, 
  AuthResponse, 
  Workspace, 
  WorkspaceSummary, 
  WorkspaceTemplate, 
  EnvVar, 
  WorkspaceWithEnvVars,
  WorkspaceCreateRequest,
  WorkspaceUpdateRequest
};