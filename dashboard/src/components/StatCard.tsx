interface Props {
  label: string;
  value: string | number;
  sub?: string;
  color?: string;
}

export function StatCard({ label, value, sub, color }: Props) {
  return (
    <div className="rounded-lg border border-zinc-800 bg-zinc-950 p-5">
      <div className="text-xs text-zinc-500 uppercase tracking-wider mb-2">{label}</div>
      <div className={`text-2xl font-semibold tabular-nums ${color || 'text-zinc-100'}`}>{value}</div>
      {sub && <div className="text-xs text-zinc-500 mt-1">{sub}</div>}
    </div>
  );
}
