import type { TaskState } from '../lib/types';

const colors: Record<TaskState, string> = {
  queued: 'bg-amber-500/15 text-amber-400',
  starting: 'bg-indigo-500/15 text-indigo-400',
  running: 'bg-blue-500/15 text-blue-400',
  completed: 'bg-emerald-500/15 text-emerald-400',
  failed: 'bg-red-500/15 text-red-400',
  cancelled: 'bg-zinc-500/15 text-zinc-400',
};

export function Badge({ state }: { state: TaskState }) {
  return (
    <span className={`inline-flex px-2 py-0.5 rounded text-xs font-medium ${colors[state] || colors.cancelled}`}>
      {state}
    </span>
  );
}
