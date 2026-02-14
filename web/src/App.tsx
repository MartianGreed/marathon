import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { useState, useEffect } from 'react';
import { isAuthenticated } from './lib/api';
import { LoginPage } from './pages/Login';
import { RegisterPage } from './pages/Register';
import { DashboardPage } from './pages/Dashboard';
import { WorkspaceDashboard } from './pages/WorkspaceDashboard';
import { Navbar } from './components/Navbar';

const queryClient = new QueryClient();

type Page = 'login' | 'register' | 'dashboard' | 'usage' | 'workspaces';

function AppContent() {
  const [page, setPage] = useState<Page>(isAuthenticated() ? 'dashboard' : 'login');
  const [authed, setAuthed] = useState(isAuthenticated());

  useEffect(() => {
    if (!authed && page !== 'login' && page !== 'register') {
      setPage('login');
    }
  }, [authed, page]);

  const onAuth = () => {
    setAuthed(true);
    setPage('dashboard');
  };

  const onLogout = () => {
    setAuthed(false);
    setPage('login');
  };

  return (
    <div className="min-h-screen" style={{ background: 'var(--bg-primary)' }}>
      {authed && <Navbar currentPage={page} onNavigate={setPage} onLogout={onLogout} />}
      <main className={authed ? 'pt-16' : ''}>
        {page === 'login' && <LoginPage onAuth={onAuth} onSwitch={() => setPage('register')} />}
        {page === 'register' && <RegisterPage onAuth={onAuth} onSwitch={() => setPage('login')} />}
        {page === 'dashboard' && <DashboardPage />}
        {page === 'workspaces' && <WorkspaceDashboard />}
        {page === 'usage' && (
          <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
            <h1 className="text-3xl font-bold text-gray-900 mb-8">Usage Report</h1>
            <div className="bg-white rounded-lg border p-6 text-center text-gray-500">
              Usage reporting coming soon...
            </div>
          </div>
        )}
      </main>
    </div>
  );
}

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <AppContent />
    </QueryClientProvider>
  );
}