-- Workspace Management Schema
CREATE TABLE IF NOT EXISTS workspaces (
    id BYTEA PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    user_id BYTEA NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    template TEXT,
    settings JSONB DEFAULT '{}',
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    last_accessed_at BIGINT NOT NULL,
    UNIQUE(user_id, name)
);

CREATE INDEX IF NOT EXISTS idx_workspaces_user_id ON workspaces(user_id);
CREATE INDEX IF NOT EXISTS idx_workspaces_name ON workspaces(name);
CREATE INDEX IF NOT EXISTS idx_workspaces_last_accessed_at ON workspaces(last_accessed_at);

-- Store user's current active workspace
CREATE TABLE IF NOT EXISTS user_active_workspaces (
    user_id BYTEA PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    workspace_id BYTEA NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    updated_at BIGINT NOT NULL
);

-- Workspace-specific environment variables
CREATE TABLE IF NOT EXISTS workspace_env_vars (
    id BYTEA PRIMARY KEY,
    workspace_id BYTEA NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    created_at BIGINT NOT NULL,
    UNIQUE(workspace_id, key)
);

CREATE INDEX IF NOT EXISTS idx_workspace_env_vars_workspace_id ON workspace_env_vars(workspace_id);

-- Associate tasks with workspaces
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS workspace_id BYTEA REFERENCES workspaces(id);
CREATE INDEX IF NOT EXISTS idx_tasks_workspace_id ON tasks(workspace_id);

-- Workspace templates
CREATE TABLE IF NOT EXISTS workspace_templates (
    id BYTEA PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    description TEXT,
    default_settings JSONB DEFAULT '{}',
    default_env_vars JSONB DEFAULT '{}',
    created_at BIGINT NOT NULL
);

INSERT INTO workspace_templates (id, name, description, default_settings, default_env_vars, created_at)
VALUES 
    (gen_random_bytes(16), 'default', 'Default empty workspace', '{}', '{}', EXTRACT(epoch FROM now()) * 1000),
    (gen_random_bytes(16), 'web-app', 'Web application workspace with Node.js environment', 
     '{"node_version": "20", "package_manager": "npm"}',
     '{"NODE_ENV": "development", "PORT": "3000"}',
     EXTRACT(epoch FROM now()) * 1000),
    (gen_random_bytes(16), 'python-ml', 'Python machine learning workspace',
     '{"python_version": "3.11", "gpu_enabled": true}',
     '{"PYTHONPATH": "/workspace", "CUDA_VISIBLE_DEVICES": "0"}',
     EXTRACT(epoch FROM now()) * 1000),
    (gen_random_bytes(16), 'rust-backend', 'Rust backend development workspace',
     '{"rust_version": "1.75", "cargo_features": ["release"]}',
     '{"RUST_LOG": "debug", "DATABASE_URL": "sqlite://db.sqlite"}',
     EXTRACT(epoch FROM now()) * 1000);

-- Workspace activity tracking
CREATE TABLE IF NOT EXISTS workspace_activity (
    id BYTEA PRIMARY KEY,
    workspace_id BYTEA NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    activity_type TEXT NOT NULL,
    description TEXT,
    metadata JSONB DEFAULT '{}',
    timestamp BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_workspace_activity_workspace_id ON workspace_activity(workspace_id);
CREATE INDEX IF NOT EXISTS idx_workspace_activity_timestamp ON workspace_activity(timestamp);