import { useCallback } from 'react';
import { usePoll } from '../hooks/usePoll';
import { fetchNodes } from '../lib/api';

function fmtUptime(sec: number) {
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  return d > 0 ? `${d}d ${h}h` : `${h}h`;
}

function fmtBytes(b: number) {
  const gb = b / 1_073_741_824;
  return `${gb.toFixed(0)} GB`;
}

function Bar({ pct, color }: { pct: number; color: string }) {
  return (
    <div className="w-full h-1.5 rounded-full bg-zinc-800">
      <div className={`h-full rounded-full ${color}`} style={{ width: `${Math.min(pct * 100, 100)}%` }} />
    </div>
  );
}

export function NodesPage() {
  const { data: nodes, loading } = usePoll(useCallback(() => fetchNodes(), []), 5000);

  if (loading || !nodes) return <div className="p-8 text-zinc-500">Loading...</div>;

  return (
    <div className="p-8 max-w-6xl">
      <h2 className="text-xl font-semibold mb-6">Nodes</h2>
      <div className="grid gap-4">
        {nodes.map(n => (
          <div key={n.node_id} className="rounded-lg border border-zinc-800 bg-zinc-950 p-5">
            <div className="flex items-center justify-between mb-4">
              <div className="flex items-center gap-3">
                <div className={`w-2 h-2 rounded-full ${n.healthy && !n.draining ? 'bg-emerald-400' : 'bg-red-400'}`} />
                <span className="font-mono text-sm">{n.hostname}</span>
              </div>
              <div className="flex items-center gap-3 text-xs text-zinc-500">
                {n.draining && <span className="text-amber-400">draining</span>}
                <span>up {fmtUptime(n.uptime_seconds)}</span>
              </div>
            </div>
            <div className="grid grid-cols-2 md:grid-cols-4 gap-4 text-sm">
              <div>
                <div className="text-zinc-500 text-xs mb-1">VM Slots</div>
                <div className="font-medium">{n.active_vms}/{n.total_vm_slots} active · {n.warm_vms} warm</div>
              </div>
              <div>
                <div className="text-zinc-500 text-xs mb-1">CPU {(n.cpu_usage * 100).toFixed(0)}%</div>
                <Bar pct={n.cpu_usage} color={n.cpu_usage > 0.8 ? 'bg-red-400' : 'bg-blue-400'} />
              </div>
              <div>
                <div className="text-zinc-500 text-xs mb-1">Memory {(n.memory_usage * 100).toFixed(0)}%</div>
                <Bar pct={n.memory_usage} color={n.memory_usage > 0.8 ? 'bg-red-400' : 'bg-purple-400'} />
              </div>
              <div>
                <div className="text-zinc-500 text-xs mb-1">Disk Free</div>
                <div className="font-medium">{fmtBytes(n.disk_available_bytes)}</div>
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
