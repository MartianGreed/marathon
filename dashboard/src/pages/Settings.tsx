import { useState, useCallback } from 'react';
import { usePoll } from '../hooks/usePoll';
import { fetchSettings, updateSettings, setApiKey, hasApiKey, clearApiKey } from '../lib/api';

export function SettingsPage() {
  const { data: settings, refresh } = usePoll(useCallback(() => fetchSettings(), []), 30000);
  const [perTask, setPerTask] = useState('');
  const [orgCap, setOrgCap] = useState('');
  const [key, setKey] = useState('');
  const [authed, setAuthed] = useState(hasApiKey());

  const handleSave = async () => {
    const patch: Record<string, unknown> = {};
    if (perTask) patch.per_task_budget_cents = Math.round(parseFloat(perTask) * 100);
    if (orgCap) patch.org_spending_cap_cents = Math.round(parseFloat(orgCap) * 100);
    await updateSettings(patch);
    refresh();
  };

  const handleKillSwitch = async () => {
    await updateSettings({ kill_switch: !settings?.kill_switch });
    refresh();
  };

  return (
    <div className="p-8 max-w-2xl">
      <h2 className="text-xl font-semibold mb-6">Cost Controls</h2>

      {/* API Key */}
      <div className="rounded-lg border border-zinc-800 bg-zinc-950 p-5 mb-4">
        <div className="text-xs text-zinc-500 uppercase tracking-wider mb-3">Authentication</div>
        {authed ? (
          <div className="flex items-center justify-between">
            <span className="text-sm text-emerald-400">✓ API key configured</span>
            <button onClick={() => { clearApiKey(); setAuthed(false); }}
              className="text-xs text-zinc-400 hover:text-red-400 transition-colors">Remove</button>
          </div>
        ) : (
          <div className="flex gap-2">
            <input type="password" value={key} onChange={e => setKey(e.target.value)}
              placeholder="Enter API key"
              className="flex-1 bg-zinc-900 border border-zinc-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-blue-500" />
            <button onClick={() => { setApiKey(key); setAuthed(true); setKey(''); }}
              className="px-3 py-1.5 rounded bg-blue-600 text-sm font-medium hover:bg-blue-500 transition-colors">Save</button>
          </div>
        )}
      </div>

      {/* Budget */}
      {settings && (
        <div className="rounded-lg border border-zinc-800 bg-zinc-950 p-5 mb-4">
          <div className="text-xs text-zinc-500 uppercase tracking-wider mb-3">Budget Limits</div>
          <div className="space-y-4">
            <div>
              <label className="text-sm text-zinc-400 block mb-1">Per-Task Budget ($)</label>
              <input type="number" step="0.01"
                placeholder={(settings.per_task_budget_cents / 100).toFixed(2)}
                value={perTask} onChange={e => setPerTask(e.target.value)}
                className="w-full bg-zinc-900 border border-zinc-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-blue-500" />
            </div>
            <div>
              <label className="text-sm text-zinc-400 block mb-1">Org Spending Cap ($)</label>
              <input type="number" step="1"
                placeholder={(settings.org_spending_cap_cents / 100).toFixed(2)}
                value={orgCap} onChange={e => setOrgCap(e.target.value)}
                className="w-full bg-zinc-900 border border-zinc-700 rounded px-3 py-1.5 text-sm focus:outline-none focus:border-blue-500" />
            </div>
            <button onClick={handleSave}
              className="px-4 py-2 rounded bg-blue-600 text-sm font-medium hover:bg-blue-500 transition-colors">
              Save Limits
            </button>
          </div>
        </div>
      )}

      {/* Kill Switch */}
      {settings && (
        <div className="rounded-lg border border-zinc-800 bg-zinc-950 p-5">
          <div className="text-xs text-zinc-500 uppercase tracking-wider mb-3">Emergency</div>
          <div className="flex items-center justify-between">
            <div>
              <div className="text-sm font-medium">Kill Switch</div>
              <div className="text-xs text-zinc-500">Immediately halt all running tasks</div>
            </div>
            <button onClick={handleKillSwitch}
              className={`px-4 py-2 rounded text-sm font-medium transition-colors ${
                settings.kill_switch
                  ? 'bg-red-600 text-white hover:bg-red-500'
                  : 'border border-red-500/30 text-red-400 hover:bg-red-500/10'
              }`}>
              {settings.kill_switch ? '🔴 ACTIVE — Click to Disable' : 'Activate Kill Switch'}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
