import { useCallback } from 'react';
import { usePoll } from '../hooks/usePoll';
import { fetchOverview } from '../lib/api';
import { StatCard } from '../components/StatCard';

export function OverviewPage() {
  const { data, loading } = usePoll(useCallback(() => fetchOverview(), []), 5000);

  if (loading || !data) return <div className="p-8 text-zinc-500">Loading...</div>;

  return (
    <div className="p-8 max-w-6xl">
      <h2 className="text-xl font-semibold mb-6">Overview</h2>
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <StatCard label="Nodes Online" value={data.node_count} color="text-emerald-400" />
        <StatCard label="Active Tasks" value={data.active_tasks} color="text-blue-400" />
        <StatCard label="Queue Depth" value={data.queued_tasks} color="text-amber-400" />
        <StatCard label="Total Cost" value={`$${(data.total_cost_cents / 100).toFixed(2)}`} color="text-zinc-100" />
      </div>
      <div className="grid grid-cols-3 gap-4 mt-4">
        <StatCard label="Total Tasks" value={data.total_tasks} />
        <StatCard label="Completed" value={data.completed_tasks} color="text-emerald-400" />
        <StatCard label="Failed" value={data.failed_tasks} color="text-red-400" />
      </div>
    </div>
  );
}
