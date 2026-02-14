import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { useState, useEffect } from 'react';
import { isAuthenticated } from './lib/api';
import { LoginPage } from './pages/Login';
import { RegisterPage } from './pages/Register';
import { DashboardPage } from './pages/Dashboard';
import AnalyticsDashboard from './components/analytics/AnalyticsDashboard';
import { Navbar } from './components/Navbar';
import { Toaster } from 'react-hot-toast';

const queryClient = new QueryClient();

type Page = 'login' | 'register' | 'dashboard' | 'usage' | 'analytics';

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
      <Toaster position="top-right" />
      {authed && <Navbar currentPage={page} onNavigate={setPage} onLogout={onLogout} />}
      <main className={authed ? 'pt-16' : ''}>
        {page === 'login' && <LoginPage onAuth={onAuth} onSwitch={() => setPage('register')} />}
        {page === 'register' && <RegisterPage onAuth={onAuth} onSwitch={() => setPage('login')} />}
        {page === 'dashboard' && <DashboardPage />}
        {page === 'analytics' && <AnalyticsDashboard />}
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