import { useCallback } from 'react';
import { useParams, Link } from 'react-router-dom';
import { usePoll } from '../hooks/usePoll';
import { fetchTask, fetchTaskEvents, cancelTask } from '../lib/api';
import { Badge } from '../components/Badge';

function fmtTokens(n: number) {
  return n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n);
}

export function TaskDetailPage() {
  const { id } = useParams<{ id: string }>();
  const { data: task } = usePoll(useCallback(() => fetchTask(id!), [id]), 5000);
  const { data: events } = usePoll(useCallback(() => fetchTaskEvents(id!), [id]), 5000);

  if (!task) return <div className="p-8 text-zinc-500">Loading...</div>;

  const costCents = Math.round(task.usage.input_tokens * 0.0003 + task.usage.output_tokens * 0.0015);

  return (
    <div className="p-8 max-w-5xl">
      <Link to="/tasks" className="text-xs text-zinc-500 hover:text-zinc-300 mb-4 inline-block">← Back to Tasks</Link>

      <div className="flex items-center gap-4 mb-6">
        <h2 className="text-xl font-semibold font-mono">{task.id}</h2>
        <Badge state={task.state} />
        {(task.state === 'running' || task.state === 'starting') && (
          <button onClick={() => cancelTask(task.id)}
            className="ml-auto text-xs px-3 py-1.5 rounded border border-red-500/30 text-red-400 hover:bg-red-500/10 transition-colors">
            Cancel Task
          </button>
        )}
      </div>

      <div className="grid grid-cols-2 gap-4 mb-6">
        <div className="rounded-lg border border-zinc-800 bg-zinc-950 p-4">
          <div className="text-xs text-zinc-500 mb-3 uppercase tracking-wider">Details</div>
          <dl className="space-y-2 text-sm">
            <div className="flex justify-between"><dt className="text-zinc-500">Repo</dt><dd><a href={task.repo_url} target="_blank" className="text-blue-400 hover:underline">{task.repo_url.replace('https://github.com/', '')}</a></dd></div>
            <div className="flex justify-between"><dt className="text-zinc-500">Branch</dt><dd className="font-mono text-xs">{task.branch}</dd></div>
            <div className="flex justify-between"><dt className="text-zinc-500">Created</dt><dd>{new Date(task.created_at).toLocaleString()}</dd></div>
            {task.pr_url && <div className="flex justify-between"><dt className="text-zinc-500">PR</dt><dd><a href={task.pr_url} target="_blank" className="text-emerald-400 hover:underline">View ↗</a></dd></div>}
            {task.error_message && <div className="flex justify-between"><dt className="text-zinc-500">Error</dt><dd className="text-red-400">{task.error_message}</dd></div>}
          </dl>
        </div>

        <div className="rounded-lg border border-zinc-800 bg-zinc-950 p-4">
          <div className="text-xs text-zinc-500 mb-3 uppercase tracking-wider">Cost Breakdown</div>
          <dl className="space-y-2 text-sm">
            <div className="flex justify-between"><dt className="text-zinc-500">Input Tokens</dt><dd className="tabular-nums">{fmtTokens(task.usage.input_tokens)}</dd></div>
            <div className="flex justify-between"><dt className="text-zinc-500">Output Tokens</dt><dd className="tabular-nums">{fmtTokens(task.usage.output_tokens)}</dd></div>
            <div className="flex justify-between"><dt className="text-zinc-500">Cache Read</dt><dd className="tabular-nums">{fmtTokens(task.usage.cache_read_tokens)}</dd></div>
            <div className="flex justify-between"><dt className="text-zinc-500">Cache Write</dt><dd className="tabular-nums">{fmtTokens(task.usage.cache_write_tokens)}</dd></div>
            <div className="flex justify-between"><dt className="text-zinc-500">Tool Calls</dt><dd className="tabular-nums">{task.usage.tool_calls}</dd></div>
            <div className="flex justify-between border-t border-zinc-800 pt-2"><dt className="text-zinc-400 font-medium">Est. Cost</dt><dd className="font-medium tabular-nums">${(costCents / 100).toFixed(2)}</dd></div>
          </dl>
        </div>
      </div>

      <div className="rounded-lg border border-zinc-800 bg-zinc-950 p-4 mb-6">
        <div className="text-xs text-zinc-500 mb-2 uppercase tracking-wider">Prompt</div>
        <p className="text-sm text-zinc-300">{task.prompt}</p>
      </div>

      <div className="rounded-lg border border-zinc-800 bg-zinc-950 p-4">
        <div className="text-xs text-zinc-500 mb-3 uppercase tracking-wider">Logs & Conversation</div>
        {events && events.length > 0 ? (
          <div className="space-y-2 max-h-96 overflow-auto">
            {events.map((e, i) => (
              <div key={i} className={`text-sm rounded p-3 ${
                e.output_type === 'claude' ? 'bg-blue-500/10 border border-blue-500/20' :
                e.output_type === 'stderr' ? 'bg-amber-500/10 border border-amber-500/20' :
                'bg-zinc-800/50'
              }`}>
                <div className="flex items-center gap-2 mb-1">
                  <span className="text-[10px] uppercase font-medium text-zinc-500">{e.output_type}</span>
                  <span className="text-[10px] text-zinc-600">{new Date(e.timestamp).toLocaleTimeString()}</span>
                </div>
                <pre className="whitespace-pre-wrap font-mono text-xs text-zinc-300">{e.data}</pre>
              </div>
            ))}
          </div>
        ) : (
          <p className="text-sm text-zinc-500">No events yet.</p>
        )}
      </div>
    </div>
  );
}
