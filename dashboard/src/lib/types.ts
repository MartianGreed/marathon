export type TaskState = 'queued' | 'starting' | 'running' | 'completed' | 'failed' | 'cancelled';

export interface UsageMetrics {
  compute_time_ms: number;
  input_tokens: number;
  output_tokens: number;
  cache_read_tokens: number;
  cache_write_tokens: number;
  tool_calls: number;
}

export interface Task {
  id: string;
  client_id: string;
  state: TaskState;
  repo_url: string;
  branch: string;
  prompt: string;
  node_id: string | null;
  vm_id: string | null;
  created_at: number;
  started_at: number | null;
  completed_at: number | null;
  error_message: string | null;
  pr_url: string | null;
  usage: UsageMetrics;
  create_pr: boolean;
  max_iterations: number | null;
}

export interface NodeStatus {
  node_id: string;
  hostname: string;
  total_vm_slots: number;
  active_vms: number;
  warm_vms: number;
  cpu_usage: number;
  memory_usage: number;
  disk_available_bytes: number;
  healthy: boolean;
  draining: boolean;
  uptime_seconds: number;
  last_task_at: number | null;
  active_task_ids: string[];
}

export interface TaskEvent {
  task_id: string;
  timestamp: number;
  output_type: 'stdout' | 'stderr' | 'claude';
  data: string;
}

export interface OrgSettings {
  per_task_budget_cents: number;
  org_spending_cap_cents: number;
  kill_switch: boolean;
}

export interface OverviewStats {
  node_count: number;
  active_tasks: number;
  queued_tasks: number;
  total_cost_cents: number;
  total_tasks: number;
  completed_tasks: number;
  failed_tasks: number;
}
