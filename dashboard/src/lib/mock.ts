import type { Task, NodeStatus, TaskEvent, OrgSettings, OverviewStats } from './types';

const now = Date.now();
const hour = 3600_000;

export const mockNodes: NodeStatus[] = [
  {
    node_id: 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4',
    hostname: 'marathon-node-us-east-1a',
    total_vm_slots: 8, active_vms: 5, warm_vms: 2,
    cpu_usage: 0.62, memory_usage: 0.48,
    disk_available_bytes: 214_748_364_800,
    healthy: true, draining: false,
    uptime_seconds: 432_000, last_task_at: now - 120_000,
    active_task_ids: ['task01','task02','task03','task04','task05'],
  },
  {
    node_id: 'b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5',
    hostname: 'marathon-node-us-west-2b',
    total_vm_slots: 8, active_vms: 3, warm_vms: 4,
    cpu_usage: 0.35, memory_usage: 0.31,
    disk_available_bytes: 322_122_547_200,
    healthy: true, draining: false,
    uptime_seconds: 259_200, last_task_at: now - 300_000,
    active_task_ids: ['task06','task07','task08'],
  },
  {
    node_id: 'c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6',
    hostname: 'marathon-node-eu-west-1a',
    total_vm_slots: 4, active_vms: 0, warm_vms: 0,
    cpu_usage: 0.02, memory_usage: 0.15,
    disk_available_bytes: 429_496_729_600,
    healthy: false, draining: true,
    uptime_seconds: 86_400, last_task_at: now - 12 * hour,
    active_task_ids: [],
  },
];

export const mockTasks: Task[] = [
  {
    id: 'task01', client_id: 'client01', state: 'running',
    repo_url: 'https://github.com/acme/backend', branch: 'feat/auth-refactor',
    prompt: 'Refactor the authentication module to use JWT with refresh tokens',
    node_id: mockNodes[0].node_id, vm_id: 'vm01',
    created_at: now - 2 * hour, started_at: now - 1.8 * hour, completed_at: null,
    error_message: null, pr_url: null,
    usage: { compute_time_ms: 6480000, input_tokens: 245000, output_tokens: 89000, cache_read_tokens: 12000, cache_write_tokens: 8000, tool_calls: 47 },
    create_pr: true, max_iterations: 50,
  },
  {
    id: 'task02', client_id: 'client01', state: 'completed',
    repo_url: 'https://github.com/acme/frontend', branch: 'fix/dashboard-perf',
    prompt: 'Fix the dashboard performance issue - reduce re-renders in the chart components',
    node_id: mockNodes[0].node_id, vm_id: 'vm02',
    created_at: now - 5 * hour, started_at: now - 4.9 * hour, completed_at: now - 3 * hour,
    error_message: null, pr_url: 'https://github.com/acme/frontend/pull/142',
    usage: { compute_time_ms: 6840000, input_tokens: 312000, output_tokens: 156000, cache_read_tokens: 45000, cache_write_tokens: 22000, tool_calls: 83 },
    create_pr: true, max_iterations: null,
  },
  {
    id: 'task03', client_id: 'client02', state: 'failed',
    repo_url: 'https://github.com/acme/infra', branch: 'feat/k8s-migration',
    prompt: 'Migrate Docker Compose setup to Kubernetes manifests',
    node_id: mockNodes[0].node_id, vm_id: 'vm03',
    created_at: now - 8 * hour, started_at: now - 7.9 * hour, completed_at: now - 6 * hour,
    error_message: 'Budget limit exceeded: $2.50 max reached', pr_url: null,
    usage: { compute_time_ms: 6840000, input_tokens: 520000, output_tokens: 210000, cache_read_tokens: 80000, cache_write_tokens: 35000, tool_calls: 120 },
    create_pr: true, max_iterations: 100,
  },
  {
    id: 'task04', client_id: 'client01', state: 'queued',
    repo_url: 'https://github.com/acme/docs', branch: 'feat/api-docs',
    prompt: 'Generate OpenAPI spec from the Express routes and add Swagger UI',
    node_id: null, vm_id: null,
    created_at: now - 600_000, started_at: null, completed_at: null,
    error_message: null, pr_url: null,
    usage: { compute_time_ms: 0, input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0, tool_calls: 0 },
    create_pr: true, max_iterations: 30,
  },
  {
    id: 'task05', client_id: 'client02', state: 'running',
    repo_url: 'https://github.com/acme/ml-pipeline', branch: 'feat/streaming',
    prompt: 'Add streaming inference support to the prediction endpoint',
    node_id: mockNodes[0].node_id, vm_id: 'vm05',
    created_at: now - 45 * 60_000, started_at: now - 40 * 60_000, completed_at: null,
    error_message: null, pr_url: null,
    usage: { compute_time_ms: 2400000, input_tokens: 180000, output_tokens: 67000, cache_read_tokens: 9000, cache_write_tokens: 5000, tool_calls: 31 },
    create_pr: true, max_iterations: null,
  },
  {
    id: 'task06', client_id: 'client01', state: 'completed',
    repo_url: 'https://github.com/acme/backend', branch: 'fix/rate-limiter',
    prompt: 'Implement rate limiting middleware with Redis backend',
    node_id: mockNodes[1].node_id, vm_id: 'vm06',
    created_at: now - 24 * hour, started_at: now - 23.9 * hour, completed_at: now - 22 * hour,
    error_message: null, pr_url: 'https://github.com/acme/backend/pull/87',
    usage: { compute_time_ms: 6840000, input_tokens: 198000, output_tokens: 95000, cache_read_tokens: 30000, cache_write_tokens: 15000, tool_calls: 52 },
    create_pr: true, max_iterations: null,
  },
  {
    id: 'task07', client_id: 'client03', state: 'starting',
    repo_url: 'https://github.com/acme/sdk-python', branch: 'feat/async-client',
    prompt: 'Add async/await support to the Python SDK client',
    node_id: mockNodes[1].node_id, vm_id: 'vm07',
    created_at: now - 120_000, started_at: now - 30_000, completed_at: null,
    error_message: null, pr_url: null,
    usage: { compute_time_ms: 0, input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0, tool_calls: 0 },
    create_pr: true, max_iterations: 40,
  },
  {
    id: 'task08', client_id: 'client01', state: 'cancelled',
    repo_url: 'https://github.com/acme/frontend', branch: 'feat/dark-mode',
    prompt: 'Add dark mode toggle with system preference detection',
    node_id: null, vm_id: null,
    created_at: now - 48 * hour, started_at: now - 47.5 * hour, completed_at: now - 47 * hour,
    error_message: 'Cancelled by user', pr_url: null,
    usage: { compute_time_ms: 1800000, input_tokens: 42000, output_tokens: 12000, cache_read_tokens: 3000, cache_write_tokens: 1000, tool_calls: 8 },
    create_pr: false, max_iterations: null,
  },
];

export const mockTaskEvents: Record<string, TaskEvent[]> = {
  task01: [
    { task_id: 'task01', timestamp: now - 1.8 * hour, output_type: 'claude', data: 'I\'ll start by analyzing the current authentication module structure.' },
    { task_id: 'task01', timestamp: now - 1.7 * hour, output_type: 'stdout', data: '$ find src/auth -type f\nsrc/auth/index.ts\nsrc/auth/middleware.ts\nsrc/auth/session.ts' },
    { task_id: 'task01', timestamp: now - 1.5 * hour, output_type: 'claude', data: 'The current auth uses session-based cookies. I\'ll refactor to JWT with access/refresh token pairs.' },
    { task_id: 'task01', timestamp: now - 1.2 * hour, output_type: 'stdout', data: '$ npm test -- --grep auth\n✓ 12 tests passed\n✗ 3 tests failed' },
    { task_id: 'task01', timestamp: now - 0.8 * hour, output_type: 'claude', data: 'Fixed the failing tests. Now implementing the refresh token rotation logic.' },
    { task_id: 'task01', timestamp: now - 0.3 * hour, output_type: 'stderr', data: 'Warning: Token expiry set to 15m for access, 7d for refresh.' },
  ],
};

export const mockSettings: OrgSettings = {
  per_task_budget_cents: 500,
  org_spending_cap_cents: 50000,
  kill_switch: false,
};

export function getMockOverview(): OverviewStats {
  const active = mockTasks.filter(t => t.state === 'running' || t.state === 'starting').length;
  const queued = mockTasks.filter(t => t.state === 'queued').length;
  const completed = mockTasks.filter(t => t.state === 'completed').length;
  const failed = mockTasks.filter(t => t.state === 'failed').length;
  const totalTokens = mockTasks.reduce((s, t) => s + t.usage.input_tokens + t.usage.output_tokens, 0);
  // rough cost: $3/M input, $15/M output (Claude pricing ballpark)
  const costCents = mockTasks.reduce((s, t) =>
    s + Math.round(t.usage.input_tokens * 0.0003 + t.usage.output_tokens * 0.0015), 0);
  return {
    node_count: mockNodes.filter(n => n.healthy).length,
    active_tasks: active,
    queued_tasks: queued,
    total_cost_cents: costCents,
    total_tasks: mockTasks.length,
    completed_tasks: completed,
    failed_tasks: failed,
  };
}
