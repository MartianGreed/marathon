import { logout, getEmail } from '../lib/api';
import { WorkspaceSelector } from './WorkspaceSelector';

type Page = 'login' | 'register' | 'dashboard' | 'usage' | 'workspaces';

interface NavbarProps {
  currentPage: Page;
  onNavigate: (page: Page) => void;
  onLogout: () => void;
}

export function Navbar({ currentPage, onNavigate, onLogout }: NavbarProps) {
  const email = getEmail();

  const handleLogout = () => {
    logout();
    onLogout();
  };

  return (
    <nav className="fixed top-0 left-0 right-0 z-50 border-b"
      style={{ background: 'var(--bg-secondary)', borderColor: 'var(--border)' }}>
      <div className="max-w-7xl mx-auto px-6 h-16 flex items-center justify-between">
        <div className="flex items-center gap-8">
          <div className="flex items-center gap-2">
            <div className="w-8 h-8 rounded-lg flex items-center justify-center text-white font-bold text-sm"
              style={{ background: 'var(--accent)' }}>M</div>
            <span className="font-semibold text-lg">Marathon</span>
          </div>
          <div className="flex items-center gap-1">
            <NavLink active={currentPage === 'dashboard'} onClick={() => onNavigate('dashboard')}>
              Tasks
            </NavLink>
            <NavLink active={currentPage === 'workspaces'} onClick={() => onNavigate('workspaces')}>
              Workspaces
            </NavLink>
            <NavLink active={currentPage === 'usage'} onClick={() => onNavigate('usage')}>
              Usage
            </NavLink>
          </div>
        </div>
        
        <div className="flex items-center gap-4">
          {/* Workspace Selector */}
          <div className="hidden md:block">
            <WorkspaceSelector className="w-48" />
          </div>
          
          <span className="text-sm" style={{ color: 'var(--text-secondary)' }}>{email}</span>
          <button onClick={handleLogout}
            className="text-sm px-3 py-1.5 rounded-md border transition-colors hover:border-red-500 hover:text-red-400"
            style={{ borderColor: 'var(--border)', color: 'var(--text-secondary)' }}>
            Logout
          </button>
        </div>
      </div>
    </nav>
  );
}

function NavLink({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button onClick={onClick}
      className="px-3 py-1.5 rounded-md text-sm font-medium transition-colors"
      style={{
        background: active ? 'var(--bg-tertiary)' : 'transparent',
        color: active ? 'var(--text-primary)' : 'var(--text-secondary)',
      }}>
      {children}
    </button>
  );
}