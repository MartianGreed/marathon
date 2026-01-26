CREATE TABLE IF NOT EXISTS tasks (
    id BYTEA PRIMARY KEY,
    client_id BYTEA NOT NULL,
    state SMALLINT NOT NULL DEFAULT 1,
    repo_url TEXT NOT NULL,
    branch TEXT NOT NULL,
    prompt TEXT NOT NULL,
    node_id BYTEA,
    vm_id BYTEA,
    created_at BIGINT NOT NULL,
    started_at BIGINT,
    completed_at BIGINT,
    error_message TEXT,
    pr_url TEXT,
    compute_time_ms BIGINT DEFAULT 0,
    input_tokens BIGINT DEFAULT 0,
    output_tokens BIGINT DEFAULT 0,
    cache_read_tokens BIGINT DEFAULT 0,
    cache_write_tokens BIGINT DEFAULT 0,
    tool_calls BIGINT DEFAULT 0,
    create_pr BOOLEAN DEFAULT FALSE,
    pr_title TEXT,
    pr_body TEXT
);

CREATE INDEX IF NOT EXISTS idx_tasks_client_id ON tasks(client_id);
CREATE INDEX IF NOT EXISTS idx_tasks_state ON tasks(state);
CREATE INDEX IF NOT EXISTS idx_tasks_node_id ON tasks(node_id);
CREATE INDEX IF NOT EXISTS idx_tasks_created_at ON tasks(created_at);

CREATE TABLE IF NOT EXISTS nodes (
    node_id BYTEA PRIMARY KEY,
    hostname TEXT NOT NULL,
    total_vm_slots INTEGER NOT NULL,
    active_vms INTEGER DEFAULT 0,
    warm_vms INTEGER DEFAULT 0,
    cpu_usage DOUBLE PRECISION DEFAULT 0,
    memory_usage DOUBLE PRECISION DEFAULT 0,
    disk_available_bytes BIGINT DEFAULT 0,
    healthy BOOLEAN DEFAULT TRUE,
    draining BOOLEAN DEFAULT FALSE,
    uptime_seconds BIGINT DEFAULT 0,
    last_task_at BIGINT,
    last_heartbeat_at BIGINT NOT NULL,
    registered_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_nodes_healthy ON nodes(healthy);
CREATE INDEX IF NOT EXISTS idx_nodes_last_heartbeat ON nodes(last_heartbeat_at);

CREATE TABLE IF NOT EXISTS usage_records (
    id BIGSERIAL PRIMARY KEY,
    client_id BYTEA NOT NULL,
    task_id BYTEA NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    timestamp BIGINT NOT NULL,
    compute_time_ms BIGINT DEFAULT 0,
    input_tokens BIGINT DEFAULT 0,
    output_tokens BIGINT DEFAULT 0,
    cache_read_tokens BIGINT DEFAULT 0,
    cache_write_tokens BIGINT DEFAULT 0,
    tool_calls BIGINT DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_usage_records_client_id ON usage_records(client_id);
CREATE INDEX IF NOT EXISTS idx_usage_records_task_id ON usage_records(task_id);
CREATE INDEX IF NOT EXISTS idx_usage_records_timestamp ON usage_records(timestamp)
