import { useState } from 'react';
import { register } from '../lib/api';

interface RegisterPageProps {
  onAuth: () => void;
  onSwitch: () => void;
}

export function RegisterPage({ onAuth, onSwitch }: RegisterPageProps) {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    if (password.length < 8) {
      setError('Password must be at least 8 characters');
      return;
    }
    setLoading(true);
    try {
      const res = await register(email, password);
      if (res.success) {
        onAuth();
      } else {
        setError(res.message);
      }
    } catch {
      setError('Connection failed. Is the orchestrator running?');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center px-4">
      <div className="w-full max-w-md">
        <div className="text-center mb-8">
          <div className="w-12 h-12 rounded-xl mx-auto mb-4 flex items-center justify-center text-white font-bold text-xl"
            style={{ background: 'var(--accent)' }}>M</div>
          <h1 className="text-2xl font-bold">Create your account</h1>
          <p className="mt-2 text-sm" style={{ color: 'var(--text-secondary)' }}>
            Start running distributed Claude Code tasks
          </p>
        </div>

        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label className="block text-sm font-medium mb-1.5" style={{ color: 'var(--text-secondary)' }}>Email</label>
            <input type="email" value={email} onChange={e => setEmail(e.target.value)} required
              className="w-full px-3 py-2.5 rounded-lg border text-sm outline-none transition-colors focus:border-indigo-500"
              style={{ background: 'var(--bg-tertiary)', borderColor: 'var(--border)', color: 'var(--text-primary)' }}
              placeholder="you@example.com" />
          </div>
          <div>
            <label className="block text-sm font-medium mb-1.5" style={{ color: 'var(--text-secondary)' }}>Password</label>
            <input type="password" value={password} onChange={e => setPassword(e.target.value)} required
              className="w-full px-3 py-2.5 rounded-lg border text-sm outline-none transition-colors focus:border-indigo-500"
              style={{ background: 'var(--bg-tertiary)', borderColor: 'var(--border)', color: 'var(--text-primary)' }}
              placeholder="Min 8 characters" />
          </div>

          {error && (
            <div className="px-3 py-2 rounded-lg text-sm" style={{ background: 'rgba(239,68,68,0.1)', color: 'var(--error)' }}>
              {error}
            </div>
          )}

          <button type="submit" disabled={loading}
            className="w-full py-2.5 rounded-lg font-medium text-sm text-white transition-colors disabled:opacity-50"
            style={{ background: 'var(--accent)' }}>
            {loading ? 'Creating account...' : 'Create account'}
          </button>
        </form>

        <p className="mt-6 text-center text-sm" style={{ color: 'var(--text-secondary)' }}>
          Already have an account?{' '}
          <button onClick={onSwitch} className="font-medium" style={{ color: 'var(--accent)' }}>
            Sign in
          </button>
        </p>
      </div>
    </div>
  );
}
