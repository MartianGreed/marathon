const API_BASE = import.meta.env.VITE_API_URL || 'http://localhost:8081';

function getToken(): string | null {
  return localStorage.getItem('marathon_token');
}

function getHeaders(): Record<string, string> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  const token = getToken();
  if (token) headers['Authorization'] = `Bearer ${token}`;
  return headers;
}

// Analytics Types
export interface TaskMetrics {
  total_tasks: number;
  completed_tasks: number;
  failed_tasks: number;
  running_tasks: number;
  queued_tasks: number;
  average_execution_time_ms: number;
  success_rate: number;
}

export interface ResourceUsage {
  total_cpu_usage: number;
  average_cpu_usage: number;
  total_memory_usage: number;
  average_memory_usage: number;
  total_disk_usage: number;
  active_nodes: number;
  healthy_nodes: number;
}

export interface UserActivity {
  total_active_users: number;
  daily_active_users: number;
  weekly_active_users: number;
  monthly_active_users: number;
  new_registrations: number;
  user_engagement_score: number;
}

export interface SystemHealth {
  uptime_percentage: number;
  average_response_time_ms: number;
  error_rate: number;
  active_connections: number;
  queue_length: number;
  last_updated: number;
}

export interface TimeSeriesPoint {
  timestamp: number;
  value: number;
  label?: string;
}

export interface TaskPerformanceData {
  execution_times: TimeSeriesPoint[];
  success_rates: TimeSeriesPoint[];
  failure_rates: TimeSeriesPoint[];
  throughput: TimeSeriesPoint[];
}

export interface ResourceTimeSeriesData {
  cpu_usage: TimeSeriesPoint[];
  memory_usage: TimeSeriesPoint[];
  disk_usage: TimeSeriesPoint[];
  network_io: TimeSeriesPoint[];
}

export interface UserActivityData {
  login_frequency: TimeSeriesPoint[];
  task_creation: TimeSeriesPoint[];
  workspace_usage: TimeSeriesPoint[];
}

export interface TeamProductivityData {
  tasks_completed: TimeSeriesPoint[];
  collaboration_score: TimeSeriesPoint[];
  code_commits: TimeSeriesPoint[];
  pr_creation: TimeSeriesPoint[];
}

export interface AnalyticsDashboard {
  overview: {
    task_metrics: TaskMetrics;
    resource_usage: ResourceUsage;
    user_activity: UserActivity;
    system_health: SystemHealth;
  };
  time_series: {
    task_performance: TaskPerformanceData;
    resource_usage: ResourceTimeSeriesData;
    user_activity: UserActivityData;
    team_productivity: TeamProductivityData;
  };
  last_updated: number;
}

export interface DateRange {
  start: Date;
  end: Date;
}

export interface ExportFormat {
  type: 'csv' | 'pdf';
  filename: string;
}

// WebSocket Events
export interface WebSocketMessage {
  type: 'task_completed' | 'task_started' | 'task_failed' | 'resource_update' | 'user_activity' | 'system_alert';
  data: any;
  timestamp: number;
}

// API Functions
export async function getDashboardData(dateRange?: DateRange): Promise<AnalyticsDashboard> {
  const params = new URLSearchParams();
  if (dateRange) {
    params.append('start', Math.floor(dateRange.start.getTime() / 1000).toString());
    params.append('end', Math.floor(dateRange.end.getTime() / 1000).toString());
  }
  
  const url = `${API_BASE}/analytics/dashboard${params.toString() ? `?${params.toString()}` : ''}`;
  const res = await fetch(url, { headers: getHeaders() });
  if (!res.ok) throw new Error('Failed to fetch dashboard data');
  return res.json();
}

export async function getTaskMetrics(dateRange?: DateRange): Promise<TaskMetrics> {
  const params = new URLSearchParams();
  if (dateRange) {
    params.append('start', Math.floor(dateRange.start.getTime() / 1000).toString());
    params.append('end', Math.floor(dateRange.end.getTime() / 1000).toString());
  }
  
  const url = `${API_BASE}/analytics/tasks${params.toString() ? `?${params.toString()}` : ''}`;
  const res = await fetch(url, { headers: getHeaders() });
  if (!res.ok) throw new Error('Failed to fetch task metrics');
  return res.json();
}

export async function getResourceUsage(dateRange?: DateRange): Promise<ResourceUsage> {
  const params = new URLSearchParams();
  if (dateRange) {
    params.append('start', Math.floor(dateRange.start.getTime() / 1000).toString());
    params.append('end', Math.floor(dateRange.end.getTime() / 1000).toString());
  }
  
  const url = `${API_BASE}/analytics/resources${params.toString() ? `?${params.toString()}` : ''}`;
  const res = await fetch(url, { headers: getHeaders() });
  if (!res.ok) throw new Error('Failed to fetch resource usage');
  return res.json();
}

export async function getUserActivity(dateRange?: DateRange): Promise<UserActivity> {
  const params = new URLSearchParams();
  if (dateRange) {
    params.append('start', Math.floor(dateRange.start.getTime() / 1000).toString());
    params.append('end', Math.floor(dateRange.end.getTime() / 1000).toString());
  }
  
  const url = `${API_BASE}/analytics/users${params.toString() ? `?${params.toString()}` : ''}`;
  const res = await fetch(url, { headers: getHeaders() });
  if (!res.ok) throw new Error('Failed to fetch user activity');
  return res.json();
}

export async function getSystemHealth(): Promise<SystemHealth> {
  const res = await fetch(`${API_BASE}/analytics/health`, { headers: getHeaders() });
  if (!res.ok) throw new Error('Failed to fetch system health');
  return res.json();
}

export async function getTaskPerformanceTimeSeries(dateRange?: DateRange): Promise<TaskPerformanceData> {
  const params = new URLSearchParams();
  if (dateRange) {
    params.append('start', Math.floor(dateRange.start.getTime() / 1000).toString());
    params.append('end', Math.floor(dateRange.end.getTime() / 1000).toString());
  }
  
  const url = `${API_BASE}/analytics/time-series/tasks${params.toString() ? `?${params.toString()}` : ''}`;
  const res = await fetch(url, { headers: getHeaders() });
  if (!res.ok) throw new Error('Failed to fetch task performance time series');
  return res.json();
}

export async function getResourceTimeSeriesData(dateRange?: DateRange): Promise<ResourceTimeSeriesData> {
  const params = new URLSearchParams();
  if (dateRange) {
    params.append('start', Math.floor(dateRange.start.getTime() / 1000).toString());
    params.append('end', Math.floor(dateRange.end.getTime() / 1000).toString());
  }
  
  const url = `${API_BASE}/analytics/time-series/resources${params.toString() ? `?${params.toString()}` : ''}`;
  const res = await fetch(url, { headers: getHeaders() });
  if (!res.ok) throw new Error('Failed to fetch resource time series');
  return res.json();
}

export async function exportDashboard(format: ExportFormat, dateRange?: DateRange): Promise<Blob> {
  const params = new URLSearchParams();
  params.append('format', format.type);
  if (dateRange) {
    params.append('start', Math.floor(dateRange.start.getTime() / 1000).toString());
    params.append('end', Math.floor(dateRange.end.getTime() / 1000).toString());
  }
  
  const url = `${API_BASE}/analytics/export?${params.toString()}`;
  const res = await fetch(url, { headers: getHeaders() });
  if (!res.ok) throw new Error('Failed to export dashboard data');
  return res.blob();
}

// WebSocket Connection
export class AnalyticsWebSocket {
  private ws: WebSocket | null = null;
  private reconnectTimeout: number = 5000;
  private maxReconnectAttempts: number = 5;
  private reconnectAttempts: number = 0;
  private messageHandlers: Map<string, (data: any) => void> = new Map();

  connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      const token = getToken();
      if (!token) {
        reject(new Error('No authentication token found'));
        return;
      }

      const wsUrl = `${API_BASE.replace('http', 'ws')}/analytics/ws?token=${encodeURIComponent(token)}`;
      this.ws = new WebSocket(wsUrl);

      this.ws.onopen = () => {
        console.log('Analytics WebSocket connected');
        this.reconnectAttempts = 0;
        resolve();
      };

      this.ws.onmessage = (event) => {
        try {
          const message: WebSocketMessage = JSON.parse(event.data);
          const handler = this.messageHandlers.get(message.type);
          if (handler) {
            handler(message.data);
          }
        } catch (error) {
          console.error('Failed to parse WebSocket message:', error);
        }
      };

      this.ws.onclose = () => {
        console.log('Analytics WebSocket disconnected');
        this.ws = null;
        this.reconnect();
      };

      this.ws.onerror = (error) => {
        console.error('Analytics WebSocket error:', error);
        reject(error);
      };
    });
  }

  private reconnect(): void {
    if (this.reconnectAttempts >= this.maxReconnectAttempts) {
      console.error('Max WebSocket reconnection attempts reached');
      return;
    }

    setTimeout(() => {
      console.log(`Attempting to reconnect WebSocket (attempt ${this.reconnectAttempts + 1})`);
      this.reconnectAttempts++;
      this.connect().catch(() => {
        // Reconnection will be attempted again
      });
    }, this.reconnectTimeout);
  }

  onMessage(type: string, handler: (data: any) => void): void {
    this.messageHandlers.set(type, handler);
  }

  disconnect(): void {
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
    this.messageHandlers.clear();
  }

  isConnected(): boolean {
    return this.ws?.readyState === WebSocket.OPEN;
  }
}