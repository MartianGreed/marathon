import { useCallback } from 'react';
import { Link } from 'react-router-dom';
import { usePoll } from '../hooks/usePoll';
import { fetchTasks } from '../lib/api';
import { Badge } from '../components/Badge';

function fmtTime(ms: number) {
  return new Date(ms).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function fmtDuration(start: number | null, end: number | null) {
  if (!start) return '—';
  const ms = (end || Date.now()) - start;
  const m = Math.floor(ms / 60000);
  return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h ${m % 60}m`;
}

function costCents(t: { usage: { input_tokens: number; output_tokens: number } }) {
  return Math.round(t.usage.input_tokens * 0.0003 + t.usage.output_tokens * 0.0015);
}

export function TasksPage() {
  const { data: tasks, loading } = usePoll(useCallback(() => fetchTasks(), []), 5000);

  if (loading || !tasks) return <div className="p-8 text-zinc-500">Loading...</div>;

  return (
    <div className="p-8 max-w-7xl">
      <h2 className="text-xl font-semibold mb-6">Tasks</h2>
      <div className="rounded-lg border border-zinc-800 overflow-hidden">
        <table className="w-full text-sm">
          <thead>
            <tr className="bg-zinc-950 border-b border-zinc-800 text-xs text-zinc-500 uppercase tracking-wider">
              <th className="text-left px-4 py-3">ID</th>
              <th className="text-left px-4 py-3">State</th>
              <th className="text-left px-4 py-3">Repository</th>
              <th className="text-left px-4 py-3">Duration</th>
              <th className="text-right px-4 py-3">Cost</th>
              <th className="text-right px-4 py-3">Turns</th>
              <th className="text-left px-4 py-3">PR</th>
            </tr>
          </thead>
          <tbody className="bg-zinc-950/50">
            {tasks.map(t => (
              <tr key={t.id} className="border-b border-zinc-800/50 hover:bg-zinc-800/30 transition-colors">
                <td className="px-4 py-3">
                  <Link to={`/tasks/${t.id}`} className="font-mono text-xs text-blue-400 hover:underline">
                    {t.id.slice(0, 12)}
                  </Link>
                </td>
                <td className="px-4 py-3"><Badge state={t.state} /></td>
                <td className="px-4 py-3">
                  <div className="truncate max-w-xs">{t.repo_url.replace('https://github.com/', '')}</div>
                  <div className="text-xs text-zinc-500">{t.branch}</div>
                </td>
                <td className="px-4 py-3 text-zinc-400">{fmtDuration(t.started_at, t.completed_at)}</td>
                <td className="px-4 py-3 text-right tabular-nums">${(costCents(t) / 100).toFixed(2)}</td>
                <td className="px-4 py-3 text-right tabular-nums text-zinc-400">{t.usage.tool_calls}</td>
                <td className="px-4 py-3">
                  {t.pr_url && (
                    <a href={t.pr_url} target="_blank" rel="noopener" className="text-emerald-400 hover:underline text-xs">
                      View PR ↗
                    </a>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
