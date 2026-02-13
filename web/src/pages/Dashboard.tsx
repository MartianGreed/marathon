import { useQuery } from '@tanstack/react-query';
import { listTasks, type Task } from '../lib/api';

const STATE_COLORS: Record<string, { bg: string; text: string }> = {
  queued: { bg: 'rgba(245,158,11,0.15)', text: '#f59e0b' },
  starting: { bg: 'rgba(99,102,241,0.15)', text: '#818cf8' },
  running: { bg: 'rgba(59,130,246,0.15)', text: '#60a5fa' },
  completed: { bg: 'rgba(34,197,94,0.15)', text: '#22c55e' },
  failed: { bg: 'rgba(239,68,68,0.15)', text: '#ef4444' },
  cancelled: { bg: 'rgba(136,136,170,0.15)', text: '#8888aa' },
};

function StateBadge({ state }: { state: string }) {
  const colors = STATE_COLORS[state] || STATE_COLORS.cancelled;
  return (
    <span className="px-2 py-0.5 rounded text-xs font-medium"
      style={{ background: colors.bg, color: colors.text }}>
      {state}
    </span>
  );
}

function formatTime(ms: number): string {
  const date = new Date(ms);
  return date.toLocaleDateString() + ' ' + date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

function TaskRow({ task }: { task: Task }) {
  const repoName = task.repo_url.replace('https://github.com/', '');
  return (
    <tr className="border-b transition-colors hover:bg-opacity-50"
      style={{ borderColor: 'var(--border)' }}
      onMouseEnter={e => (e.currentTarget.style.background = 'var(--bg-tertiary)')}
      onMouseLeave={e => (e.currentTarget.style.background = 'transparent')}>
      <td className="px-4 py-3">
        <div className="font-mono text-xs" style={{ color: 'var(--text-secondary)' }}>
          {task.id.slice(0, 12)}...
        </div>
      </td>
      <td className="px-4 py-3"><StateBadge state={task.state} /></td>
      <td className="px-4 py-3">
        <a href={task.repo_url} target="_blank" rel="noopener"
          className="text-sm hover:underline" style={{ color: 'var(--accent)' }}>
          {repoName}
        </a>
        <div className="text-xs mt-0.5" style={{ color: 'var(--text-secondary)' }}>{task.branch}</div>
      </td>
      <td className="px-4 py-3">
        <div className="text-sm max-w-xs truncate" title={task.prompt}>{task.prompt}</div>
      </td>
      <td className="px-4 py-3">
        <div className="text-sm" style={{ color: 'var(--text-secondary)' }}>{formatTime(task.created_at)}</div>
      </td>
      <td className="px-4 py-3">
        {task.pr_url && (
          <a href={task.pr_url} target="_blank" rel="noopener"
            className="text-xs px-2 py-1 rounded border transition-colors hover:border-green-500"
            style={{ borderColor: 'var(--border)', color: 'var(--success)' }}>
            View PR
          </a>
        )}
      </td>
    </tr>
  );
}

export function DashboardPage() {
  const { data: tasks, isLoading, error } = useQuery({
    queryKey: ['tasks'],
    queryFn: listTasks,
    refetchInterval: 5000,
  });

  return (
    <div className="max-w-7xl mx-auto px-6 py-8">
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-bold">Tasks</h1>
          <p className="text-sm mt-1" style={{ color: 'var(--text-secondary)' }}>
            Monitor your distributed Claude Code runs
          </p>
        </div>
        <div className="flex items-center gap-3">
          {tasks && (
            <span className="text-sm" style={{ color: 'var(--text-secondary)' }}>
              {tasks.length} task{tasks.length !== 1 ? 's' : ''}
            </span>
          )}
        </div>
      </div>

      {isLoading && (
        <div className="flex items-center justify-center py-20">
          <div className="animate-spin w-8 h-8 border-2 rounded-full"
            style={{ borderColor: 'var(--border)', borderTopColor: 'var(--accent)' }} />
        </div>
      )}

      {error && (
        <div className="rounded-lg border p-6 text-center"
          style={{ borderColor: 'var(--border)', background: 'var(--bg-secondary)' }}>
          <p className="text-sm" style={{ color: 'var(--error)' }}>
            Failed to load tasks. Make sure the orchestrator is running.
          </p>
        </div>
      )}

      {tasks && tasks.length === 0 && (
        <div className="rounded-lg border p-12 text-center"
          style={{ borderColor: 'var(--border)', background: 'var(--bg-secondary)' }}>
          <div className="text-4xl mb-3">🏃</div>
          <h3 className="font-semibold text-lg mb-1">No tasks yet</h3>
          <p className="text-sm" style={{ color: 'var(--text-secondary)' }}>
            Submit a task using the CLI: <code className="px-1.5 py-0.5 rounded text-xs"
              style={{ background: 'var(--bg-tertiary)' }}>marathon submit --repo ... --prompt ...</code>
          </p>
        </div>
      )}

      {tasks && tasks.length > 0 && (
        <div className="rounded-lg border overflow-hidden"
          style={{ borderColor: 'var(--border)', background: 'var(--bg-secondary)' }}>
          <table className="w-full">
            <thead>
              <tr className="border-b text-left text-xs font-medium uppercase tracking-wider"
                style={{ borderColor: 'var(--border)', color: 'var(--text-secondary)' }}>
                <th className="px-4 py-3">ID</th>
                <th className="px-4 py-3">State</th>
                <th className="px-4 py-3">Repository</th>
                <th className="px-4 py-3">Prompt</th>
                <th className="px-4 py-3">Created</th>
                <th className="px-4 py-3">PR</th>
              </tr>
            </thead>
            <tbody>
              {tasks.map(task => <TaskRow key={task.id} task={task} />)}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
