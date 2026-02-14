import React, { useState, useEffect } from 'react';
import { listWorkspaces, switchWorkspace, type WorkspaceSummary } from '../lib/api';

interface WorkspaceSelectorProps {
  onWorkspaceChange?: (workspace: WorkspaceSummary | null) => void;
  className?: string;
}

export function WorkspaceSelector({ onWorkspaceChange, className = '' }: WorkspaceSelectorProps) {
  const [workspaces, setWorkspaces] = useState<WorkspaceSummary[]>([]);
  const [currentWorkspaceId, setCurrentWorkspaceId] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    loadWorkspaces();
  }, []);

  const loadWorkspaces = async () => {
    try {
      setLoading(true);
      const result = await listWorkspaces();
      setWorkspaces(result.workspaces);
      setCurrentWorkspaceId(result.current_workspace_id || null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load workspaces');
    } finally {
      setLoading(false);
    }
  };

  const handleWorkspaceChange = async (workspaceId: string) => {
    if (workspaceId === currentWorkspaceId) return;

    try {
      await switchWorkspace(workspaceId);
      setCurrentWorkspaceId(workspaceId);
      
      const selectedWorkspace = workspaces.find(w => w.id === workspaceId) || null;
      onWorkspaceChange?.(selectedWorkspace);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to switch workspace');
    }
  };

  if (loading) {
    return (
      <div className={`flex items-center space-x-2 ${className}`}>
        <div className="animate-spin h-4 w-4 border-2 border-blue-500 border-t-transparent rounded-full"></div>
        <span className="text-sm text-gray-500">Loading workspaces...</span>
      </div>
    );
  }

  if (error) {
    return (
      <div className={`text-sm text-red-500 ${className}`}>
        <span>Error: {error}</span>
        <button 
          onClick={loadWorkspaces} 
          className="ml-2 text-blue-500 hover:text-blue-700 underline"
        >
          Retry
        </button>
      </div>
    );
  }

  if (workspaces.length === 0) {
    return (
      <div className={`text-sm text-gray-500 ${className}`}>
        No workspaces available
      </div>
    );
  }

  const currentWorkspace = workspaces.find(w => w.id === currentWorkspaceId);

  return (
    <div className={`relative ${className}`}>
      <select
        value={currentWorkspaceId || ''}
        onChange={(e) => handleWorkspaceChange(e.target.value)}
        className="block w-full px-3 py-2 bg-white border border-gray-300 rounded-md shadow-sm focus:outline-none focus:ring-blue-500 focus:border-blue-500 sm:text-sm"
      >
        {!currentWorkspaceId && (
          <option value="" disabled>Select a workspace...</option>
        )}
        {workspaces.map((workspace) => (
          <option key={workspace.id} value={workspace.id}>
            {workspace.name} {workspace.is_active ? '(active)' : ''}
            {workspace.task_count > 0 && ` (${workspace.task_count} tasks)`}
          </option>
        ))}
      </select>
      
      {currentWorkspace && (
        <div className="mt-1 text-xs text-gray-500">
          {currentWorkspace.description && (
            <div>📝 {currentWorkspace.description}</div>
          )}
          {currentWorkspace.template && (
            <div>🎨 Template: {currentWorkspace.template}</div>
          )}
          <div>📅 Created: {new Date(currentWorkspace.created_at).toLocaleDateString()}</div>
        </div>
      )}
    </div>
  );
}