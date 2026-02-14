-- Teams and membership
CREATE TABLE IF NOT EXISTS teams (
    id BYTEA PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    description TEXT,
    owner_id BYTEA NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_teams_owner_id ON teams(owner_id);
CREATE INDEX IF NOT EXISTS idx_teams_name ON teams(name);

-- Team roles: admin, lead, developer, viewer
CREATE TYPE team_role AS ENUM ('admin', 'lead', 'developer', 'viewer');

CREATE TABLE IF NOT EXISTS team_members (
    id BYTEA PRIMARY KEY,
    team_id BYTEA NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    user_id BYTEA NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role team_role NOT NULL DEFAULT 'developer',
    permissions JSONB DEFAULT '{}',
    invited_by BYTEA REFERENCES users(id),
    invited_at BIGINT,
    joined_at BIGINT,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    UNIQUE(team_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_team_members_team_id ON team_members(team_id);
CREATE INDEX IF NOT EXISTS idx_team_members_user_id ON team_members(user_id);
CREATE INDEX IF NOT EXISTS idx_team_members_role ON team_members(role);

-- Workspaces (associated with teams)
CREATE TABLE IF NOT EXISTS workspaces (
    id BYTEA PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    team_id BYTEA NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    created_by BYTEA NOT NULL REFERENCES users(id),
    repo_url TEXT,
    branch TEXT,
    settings JSONB DEFAULT '{}',
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    UNIQUE(team_id, name)
);

CREATE INDEX IF NOT EXISTS idx_workspaces_team_id ON workspaces(team_id);
CREATE INDEX IF NOT EXISTS idx_workspaces_created_by ON workspaces(created_by);

-- Task assignments and dependencies
CREATE TYPE task_priority AS ENUM ('low', 'normal', 'high', 'urgent');
CREATE TYPE task_status AS ENUM ('todo', 'in_progress', 'review', 'done', 'blocked');

CREATE TABLE IF NOT EXISTS task_assignments (
    id BYTEA PRIMARY KEY,
    task_id BYTEA NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    workspace_id BYTEA REFERENCES workspaces(id) ON DELETE SET NULL,
    title TEXT NOT NULL,
    description TEXT,
    assigned_to BYTEA REFERENCES users(id) ON DELETE SET NULL,
    assigned_by BYTEA REFERENCES users(id) ON DELETE SET NULL,
    status task_status NOT NULL DEFAULT 'todo',
    priority task_priority NOT NULL DEFAULT 'normal',
    due_date BIGINT,
    template_name TEXT,
    dependencies BYTEA[], -- Array of task_assignment IDs
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_task_assignments_task_id ON task_assignments(task_id);
CREATE INDEX IF NOT EXISTS idx_task_assignments_workspace_id ON task_assignments(workspace_id);
CREATE INDEX IF NOT EXISTS idx_task_assignments_assigned_to ON task_assignments(assigned_to);
CREATE INDEX IF NOT EXISTS idx_task_assignments_status ON task_assignments(status);
CREATE INDEX IF NOT EXISTS idx_task_assignments_priority ON task_assignments(priority);
CREATE INDEX IF NOT EXISTS idx_task_assignments_due_date ON task_assignments(due_date);

-- Task comments and discussions
CREATE TABLE IF NOT EXISTS task_comments (
    id BYTEA PRIMARY KEY,
    task_assignment_id BYTEA NOT NULL REFERENCES task_assignments(id) ON DELETE CASCADE,
    user_id BYTEA NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    metadata JSONB DEFAULT '{}', -- For mentions, attachments, etc.
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_task_comments_assignment_id ON task_comments(task_assignment_id);
CREATE INDEX IF NOT EXISTS idx_task_comments_user_id ON task_comments(user_id);
CREATE INDEX IF NOT EXISTS idx_task_comments_created_at ON task_comments(created_at);

-- Terminal sessions for sharing
CREATE TABLE IF NOT EXISTS terminal_sessions (
    id BYTEA PRIMARY KEY,
    workspace_id BYTEA NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    created_by BYTEA NOT NULL REFERENCES users(id),
    is_active BOOLEAN DEFAULT TRUE,
    readonly_users BYTEA[], -- Array of user IDs with read-only access
    settings JSONB DEFAULT '{}', -- Terminal settings, colors, etc.
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    UNIQUE(workspace_id, name)
);

CREATE INDEX IF NOT EXISTS idx_terminal_sessions_workspace_id ON terminal_sessions(workspace_id);
CREATE INDEX IF NOT EXISTS idx_terminal_sessions_created_by ON terminal_sessions(created_by);
CREATE INDEX IF NOT EXISTS idx_terminal_sessions_active ON terminal_sessions(is_active);

-- Terminal session participants
CREATE TABLE IF NOT EXISTS terminal_participants (
    id BYTEA PRIMARY KEY,
    session_id BYTEA NOT NULL REFERENCES terminal_sessions(id) ON DELETE CASCADE,
    user_id BYTEA NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    readonly BOOLEAN DEFAULT FALSE,
    joined_at BIGINT NOT NULL,
    last_seen_at BIGINT NOT NULL,
    UNIQUE(session_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_terminal_participants_session_id ON terminal_participants(session_id);
CREATE INDEX IF NOT EXISTS idx_terminal_participants_user_id ON terminal_participants(user_id);

-- Terminal history for replay
CREATE TABLE IF NOT EXISTS terminal_history (
    id BIGSERIAL PRIMARY KEY,
    session_id BYTEA NOT NULL REFERENCES terminal_sessions(id) ON DELETE CASCADE,
    user_id BYTEA REFERENCES users(id) ON DELETE SET NULL,
    data BYTEA NOT NULL,
    timestamp BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_terminal_history_session_id ON terminal_history(session_id);
CREATE INDEX IF NOT EXISTS idx_terminal_history_timestamp ON terminal_history(timestamp);

-- Messages and chat
CREATE TABLE IF NOT EXISTS messages (
    id BYTEA PRIMARY KEY,
    workspace_id BYTEA REFERENCES workspaces(id) ON DELETE CASCADE,
    task_assignment_id BYTEA REFERENCES task_assignments(id) ON DELETE CASCADE,
    user_id BYTEA NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    message_type TEXT NOT NULL DEFAULT 'text', -- text, file, code_snippet, system
    metadata JSONB DEFAULT '{}', -- mentions, files, code blocks, etc.
    reply_to BYTEA REFERENCES messages(id) ON DELETE SET NULL,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    CONSTRAINT check_message_context CHECK (
        (workspace_id IS NOT NULL AND task_assignment_id IS NULL) OR
        (workspace_id IS NULL AND task_assignment_id IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_messages_workspace_id ON messages(workspace_id);
CREATE INDEX IF NOT EXISTS idx_messages_task_assignment_id ON messages(task_assignment_id);
CREATE INDEX IF NOT EXISTS idx_messages_user_id ON messages(user_id);
CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(created_at);
CREATE INDEX IF NOT EXISTS idx_messages_reply_to ON messages(reply_to);

-- User presence and status
CREATE TABLE IF NOT EXISTS user_presence (
    user_id BYTEA PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'offline', -- online, busy, away, offline
    workspace_id BYTEA REFERENCES workspaces(id) ON DELETE SET NULL,
    last_seen_at BIGINT NOT NULL,
    custom_status TEXT,
    updated_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_user_presence_workspace_id ON user_presence(workspace_id);
CREATE INDEX IF NOT EXISTS idx_user_presence_status ON user_presence(status);
CREATE INDEX IF NOT EXISTS idx_user_presence_last_seen ON user_presence(last_seen_at);

-- Notifications
CREATE TYPE notification_type AS ENUM ('task_assigned', 'mention', 'task_comment', 'team_invite', 'terminal_invite', 'system');
CREATE TYPE notification_channel AS ENUM ('in_app', 'email', 'webhook');

CREATE TABLE IF NOT EXISTS notifications (
    id BYTEA PRIMARY KEY,
    user_id BYTEA NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type notification_type NOT NULL,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    metadata JSONB DEFAULT '{}',
    channels notification_channel[] NOT NULL DEFAULT ARRAY['in_app'],
    read_at BIGINT,
    sent_at BIGINT,
    created_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_notifications_user_id ON notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_type ON notifications(type);
CREATE INDEX IF NOT EXISTS idx_notifications_read_at ON notifications(read_at);
CREATE INDEX IF NOT EXISTS idx_notifications_created_at ON notifications(created_at);

-- Audit logs for security and compliance
CREATE TABLE IF NOT EXISTS audit_logs (
    id BIGSERIAL PRIMARY KEY,
    user_id BYTEA REFERENCES users(id) ON DELETE SET NULL,
    team_id BYTEA REFERENCES teams(id) ON DELETE SET NULL,
    workspace_id BYTEA REFERENCES workspaces(id) ON DELETE SET NULL,
    action TEXT NOT NULL,
    resource_type TEXT NOT NULL,
    resource_id BYTEA,
    old_values JSONB,
    new_values JSONB,
    ip_address INET,
    user_agent TEXT,
    timestamp BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_audit_logs_user_id ON audit_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_team_id ON audit_logs(team_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_workspace_id ON audit_logs(workspace_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_action ON audit_logs(action);
CREATE INDEX IF NOT EXISTS idx_audit_logs_timestamp ON audit_logs(timestamp);

-- Task templates for common workflows
CREATE TABLE IF NOT EXISTS task_templates (
    id BYTEA PRIMARY KEY,
    team_id BYTEA NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT,
    prompt_template TEXT NOT NULL,
    default_priority task_priority NOT NULL DEFAULT 'normal',
    estimated_duration BIGINT, -- in milliseconds
    required_permissions JSONB DEFAULT '{}',
    created_by BYTEA NOT NULL REFERENCES users(id),
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    UNIQUE(team_id, name)
);

CREATE INDEX IF NOT EXISTS idx_task_templates_team_id ON task_templates(team_id);
CREATE INDEX IF NOT EXISTS idx_task_templates_created_by ON task_templates(created_by);

-- Update tasks table to add team context
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS team_id BYTEA REFERENCES teams(id) ON DELETE SET NULL;
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS workspace_id BYTEA REFERENCES workspaces(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_team_id ON tasks(team_id);
CREATE INDEX IF NOT EXISTS idx_tasks_workspace_id ON tasks(workspace_id);

-- Integration settings for external services
CREATE TABLE IF NOT EXISTS integrations (
    id BYTEA PRIMARY KEY,
    team_id BYTEA NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    type TEXT NOT NULL, -- slack, discord, webhook, etc.
    name TEXT NOT NULL,
    config JSONB NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    created_by BYTEA NOT NULL REFERENCES users(id),
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    UNIQUE(team_id, name)
);

CREATE INDEX IF NOT EXISTS idx_integrations_team_id ON integrations(team_id);
CREATE INDEX IF NOT EXISTS idx_integrations_type ON integrations(type);
CREATE INDEX IF NOT EXISTS idx_integrations_active ON integrations(is_active);