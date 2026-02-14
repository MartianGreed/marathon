import React, { useState, useEffect } from 'react';
import { 
  listWorkspaces, 
  getCurrentWorkspace, 
  createWorkspace,
  deleteWorkspace,
  getWorkspaceTemplates,
  type WorkspaceSummary, 
  type WorkspaceWithEnvVars,
  type WorkspaceTemplate,
  type WorkspaceCreateRequest 
} from '../lib/api';

interface CreateWorkspaceFormData {
  name: string;
  description: string;
  template: string;
  settings: string;
}

export function WorkspaceDashboard() {
  const [workspaces, setWorkspaces] = useState<WorkspaceSummary[]>([]);
  const [currentWorkspace, setCurrentWorkspace] = useState<WorkspaceWithEnvVars | null>(null);
  const [templates, setTemplates] = useState<WorkspaceTemplate[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showCreateForm, setShowCreateForm] = useState(false);
  const [createFormData, setCreateFormData] = useState<CreateWorkspaceFormData>({
    name: '',
    description: '',
    template: 'default',
    settings: '{}',
  });

  useEffect(() => {
    loadData();
  }, []);

  const loadData = async () => {
    try {
      setLoading(true);
      setError(null);
      
      const [workspacesResult, currentResult, templatesResult] = await Promise.all([
        listWorkspaces(),
        getCurrentWorkspace().catch(() => null),
        getWorkspaceTemplates(),
      ]);
      
      setWorkspaces(workspacesResult.workspaces);
      setCurrentWorkspace(currentResult);
      setTemplates(templatesResult);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load workspace data');
    } finally {
      setLoading(false);
    }
  };

  const handleCreateWorkspace = async (e: React.FormEvent) => {
    e.preventDefault();
    
    if (!createFormData.name.trim()) {
      setError('Workspace name is required');
      return;
    }

    try {
      setLoading(true);
      setError(null);
      
      const request: WorkspaceCreateRequest = {
        name: createFormData.name.trim(),
        description: createFormData.description.trim() || undefined,
        template: createFormData.template || undefined,
        settings: createFormData.settings.trim() || undefined,
      };

      await createWorkspace(request);
      setShowCreateForm(false);
      setCreateFormData({ name: '', description: '', template: 'default', settings: '{}' });
      await loadData(); // Reload data to show the new workspace
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to create workspace');
    } finally {
      setLoading(false);
    }
  };

  const handleDeleteWorkspace = async (workspace: WorkspaceSummary) => {
    if (!confirm(`Are you sure you want to delete the workspace "${workspace.name}"?`)) {
      return;
    }

    try {
      setLoading(true);
      setError(null);
      await deleteWorkspace(workspace.id);
      await loadData(); // Reload data
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete workspace');
    } finally {
      setLoading(false);
    }
  };

  const formatDate = (timestamp: number) => {
    return new Date(timestamp).toLocaleString();
  };

  if (loading && workspaces.length === 0) {
    return (
      <div className="flex items-center justify-center min-h-64">
        <div className="animate-spin h-8 w-8 border-2 border-blue-500 border-t-transparent rounded-full"></div>
        <span className="ml-3 text-gray-600">Loading workspaces...</span>
      </div>
    );
  }

  return (
    <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div className="flex justify-between items-center mb-8">
        <h1 className="text-3xl font-bold text-gray-900">Workspace Dashboard</h1>
        <button
          onClick={() => setShowCreateForm(true)}
          className="bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-md font-medium"
          disabled={loading}
        >
          Create Workspace
        </button>
      </div>

      {error && (
        <div className="mb-6 bg-red-50 border border-red-200 rounded-md p-4">
          <div className="flex">
            <div className="text-red-800">{error}</div>
            <button
              onClick={() => setError(null)}
              className="ml-auto text-red-500 hover:text-red-700"
            >
              ✕
            </button>
          </div>
        </div>
      )}

      {/* Current Workspace */}
      {currentWorkspace && (
        <div className="mb-8 bg-blue-50 border border-blue-200 rounded-lg p-6">
          <h2 className="text-xl font-semibold text-blue-900 mb-4">Current Workspace</h2>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <h3 className="font-medium text-blue-800">{currentWorkspace.workspace.name}</h3>
              {currentWorkspace.workspace.description && (
                <p className="text-blue-600 text-sm mt-1">{currentWorkspace.workspace.description}</p>
              )}
              <div className="text-sm text-blue-500 mt-2">
                {currentWorkspace.workspace.template && (
                  <div>Template: {currentWorkspace.workspace.template}</div>
                )}
                <div>Created: {formatDate(currentWorkspace.workspace.created_at)}</div>
                <div>Last accessed: {formatDate(currentWorkspace.workspace.last_accessed_at)}</div>
              </div>
            </div>
            {currentWorkspace.env_vars.length > 0 && (
              <div>
                <h4 className="font-medium text-blue-800 mb-2">Environment Variables</h4>
                <div className="space-y-1">
                  {currentWorkspace.env_vars.map((env) => (
                    <div key={env.key} className="text-sm font-mono bg-blue-100 p-2 rounded">
                      <span className="text-blue-800">{env.key}</span>=
                      <span className="text-blue-600">{env.value}</span>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>
        </div>
      )}

      {/* Create Workspace Form */}
      {showCreateForm && (
        <div className="fixed inset-0 bg-gray-600 bg-opacity-50 flex items-center justify-center z-50">
          <div className="bg-white rounded-lg p-6 w-full max-w-md mx-4">
            <h2 className="text-xl font-semibold mb-4">Create New Workspace</h2>
            <form onSubmit={handleCreateWorkspace}>
              <div className="mb-4">
                <label className="block text-sm font-medium text-gray-700 mb-2">
                  Name *
                </label>
                <input
                  type="text"
                  value={createFormData.name}
                  onChange={(e) => setCreateFormData({ ...createFormData, name: e.target.value })}
                  className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-blue-500 focus:border-blue-500"
                  placeholder="my-workspace"
                  required
                />
              </div>

              <div className="mb-4">
                <label className="block text-sm font-medium text-gray-700 mb-2">
                  Description
                </label>
                <textarea
                  value={createFormData.description}
                  onChange={(e) => setCreateFormData({ ...createFormData, description: e.target.value })}
                  className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-blue-500 focus:border-blue-500"
                  placeholder="Description of this workspace"
                  rows={2}
                />
              </div>

              <div className="mb-4">
                <label className="block text-sm font-medium text-gray-700 mb-2">
                  Template
                </label>
                <select
                  value={createFormData.template}
                  onChange={(e) => setCreateFormData({ ...createFormData, template: e.target.value })}
                  className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-blue-500 focus:border-blue-500"
                >
                  {templates.map((template) => (
                    <option key={template.id} value={template.name}>
                      {template.name} - {template.description || 'No description'}
                    </option>
                  ))}
                </select>
              </div>

              <div className="mb-6">
                <label className="block text-sm font-medium text-gray-700 mb-2">
                  Settings (JSON)
                </label>
                <textarea
                  value={createFormData.settings}
                  onChange={(e) => setCreateFormData({ ...createFormData, settings: e.target.value })}
                  className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-blue-500 focus:border-blue-500 font-mono text-sm"
                  placeholder="{}"
                  rows={3}
                />
              </div>

              <div className="flex justify-end space-x-3">
                <button
                  type="button"
                  onClick={() => setShowCreateForm(false)}
                  className="px-4 py-2 text-gray-700 bg-gray-100 hover:bg-gray-200 rounded-md"
                  disabled={loading}
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-md disabled:opacity-50"
                  disabled={loading}
                >
                  {loading ? 'Creating...' : 'Create'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Workspaces List */}
      <div>
        <h2 className="text-xl font-semibold text-gray-900 mb-4">All Workspaces</h2>
        {workspaces.length === 0 ? (
          <div className="text-center py-8 text-gray-500">
            <div className="text-lg mb-2">No workspaces found</div>
            <div className="text-sm">Create your first workspace to get started</div>
          </div>
        ) : (
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
            {workspaces.map((workspace) => (
              <div
                key={workspace.id}
                className={`border rounded-lg p-4 ${
                  workspace.is_active ? 'border-blue-300 bg-blue-50' : 'border-gray-200 bg-white'
                }`}
              >
                <div className="flex items-start justify-between mb-3">
                  <div>
                    <h3 className="font-medium text-gray-900">
                      {workspace.name}
                      {workspace.is_active && (
                        <span className="ml-2 inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-blue-100 text-blue-800">
                          Active
                        </span>
                      )}
                    </h3>
                    {workspace.description && (
                      <p className="text-sm text-gray-600 mt-1">{workspace.description}</p>
                    )}
                  </div>
                  <button
                    onClick={() => handleDeleteWorkspace(workspace)}
                    className="text-gray-400 hover:text-red-500 ml-2"
                    disabled={loading}
                    title="Delete workspace"
                  >
                    🗑️
                  </button>
                </div>

                <div className="space-y-2">
                  {workspace.template && (
                    <div className="text-sm text-gray-500">
                      🎨 Template: {workspace.template}
                    </div>
                  )}
                  <div className="text-sm text-gray-500">
                    📊 {workspace.task_count} tasks
                  </div>
                  <div className="text-sm text-gray-500">
                    📅 Created: {formatDate(workspace.created_at)}
                  </div>
                  <div className="text-sm text-gray-500">
                    🕒 Last accessed: {formatDate(workspace.last_accessed_at)}
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}