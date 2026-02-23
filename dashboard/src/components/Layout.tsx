import { NavLink, Outlet } from 'react-router-dom';

const links = [
  { to: '/', label: 'Overview', icon: '◈' },
  { to: '/nodes', label: 'Nodes', icon: '⬡' },
  { to: '/tasks', label: 'Tasks', icon: '▤' },
  { to: '/settings', label: 'Cost Controls', icon: '⚙' },
];

export function Layout() {
  return (
    <div className="min-h-screen flex">
      <nav className="w-56 border-r border-zinc-800 bg-zinc-950 flex flex-col shrink-0">
        <div className="p-5 border-b border-zinc-800">
          <h1 className="text-lg font-bold tracking-tight flex items-center gap-2">
            <span className="text-xl">🏃</span> Marathon
          </h1>
          <p className="text-[11px] text-zinc-500 mt-0.5">Distributed Claude Code</p>
        </div>
        <div className="flex-1 py-3 px-2 space-y-0.5">
          {links.map(l => (
            <NavLink key={l.to} to={l.to} end={l.to === '/'}
              className={({ isActive }) =>
                `flex items-center gap-2.5 px-3 py-2 rounded-md text-sm transition-colors ${
                  isActive ? 'bg-zinc-800 text-zinc-100' : 'text-zinc-400 hover:text-zinc-200 hover:bg-zinc-800/50'
                }`
              }>
              <span className="text-xs opacity-70">{l.icon}</span>{l.label}
            </NavLink>
          ))}
        </div>
        <div className="p-3 border-t border-zinc-800">
          <div className="text-[10px] text-zinc-600 text-center">v0.1.0 · mock mode</div>
        </div>
      </nav>
      <main className="flex-1 bg-zinc-900 overflow-auto">
        <Outlet />
      </main>
    </div>
  );
}
