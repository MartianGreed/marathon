
CREATE TABLE public.nodes (
    node_id bytea NOT NULL,
    hostname text NOT NULL,
    total_vm_slots integer NOT NULL,
    active_vms integer DEFAULT 0,
    warm_vms integer DEFAULT 0,
    cpu_usage double precision DEFAULT 0,
    memory_usage double precision DEFAULT 0,
    disk_available_bytes bigint DEFAULT 0,
    healthy boolean DEFAULT true,
    draining boolean DEFAULT false,
    uptime_seconds bigint DEFAULT 0,
    last_task_at bigint,
    last_heartbeat_at bigint NOT NULL,
    registered_at bigint NOT NULL,
    updated_at bigint NOT NULL
);

CREATE TABLE public.schema_migrations (
    version integer NOT NULL,
    applied_at bigint NOT NULL,
    description text
);

CREATE TABLE public.tasks (
    id bytea NOT NULL,
    client_id bytea NOT NULL,
    state smallint DEFAULT 1 NOT NULL,
    repo_url text NOT NULL,
    branch text NOT NULL,
    prompt text NOT NULL,
    node_id bytea,
    vm_id bytea,
    created_at bigint NOT NULL,
    started_at bigint,
    completed_at bigint,
    error_message text,
    pr_url text,
    compute_time_ms bigint DEFAULT 0,
    input_tokens bigint DEFAULT 0,
    output_tokens bigint DEFAULT 0,
    cache_read_tokens bigint DEFAULT 0,
    cache_write_tokens bigint DEFAULT 0,
    tool_calls bigint DEFAULT 0,
    create_pr boolean DEFAULT false,
    pr_title text,
    pr_body text,
    user_id bytea
);

CREATE TABLE public.usage_records (
    id bigint NOT NULL,
    client_id bytea NOT NULL,
    task_id bytea NOT NULL,
    "timestamp" bigint NOT NULL,
    compute_time_ms bigint DEFAULT 0,
    input_tokens bigint DEFAULT 0,
    output_tokens bigint DEFAULT 0,
    cache_read_tokens bigint DEFAULT 0,
    cache_write_tokens bigint DEFAULT 0,
    tool_calls bigint DEFAULT 0,
    user_id bytea
);

CREATE SEQUENCE public.usage_records_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.usage_records_id_seq OWNED BY public.usage_records.id;

CREATE TABLE public.user_tokens (
    id bytea NOT NULL,
    user_id bytea NOT NULL,
    token_hash text NOT NULL,
    expires_at bigint NOT NULL,
    created_at bigint NOT NULL
);

CREATE TABLE public.users (
    id bytea NOT NULL,
    email text NOT NULL,
    password_hash text NOT NULL,
    github_id text,
    api_key text NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL
);

ALTER TABLE ONLY public.usage_records ALTER COLUMN id SET DEFAULT nextval('public.usage_records_id_seq'::regclass);

INSERT INTO public.nodes (node_id, hostname, total_vm_slots, active_vms, warm_vms, cpu_usage, memory_usage, disk_available_bytes, healthy, draining, uptime_seconds, last_task_at, last_heartbeat_at, registered_at, updated_at) VALUES ('\x101112131415161718191a1b1c1d1e1f', 'zig-node', 4, 1, 2, 0.25, 0.5, 1000000, true, false, 60, NULL, 1791192185670, 1791192185670, 1791192185670);

INSERT INTO public.schema_migrations (version, applied_at, description) VALUES (1, 1791192164614, 'initial schema');
INSERT INTO public.schema_migrations (version, applied_at, description) VALUES (2, 1791192171992, 'users and authentication');

INSERT INTO public.tasks (id, client_id, state, repo_url, branch, prompt, node_id, vm_id, created_at, started_at, completed_at, error_message, pr_url, compute_time_ms, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, tool_calls, create_pr, pr_title, pr_body, user_id) VALUES ('\xe1c01a45331f99b9d64c8f8a4221746cb4d128fce9f47e93bc58e357a275807c', '\xa0a1a2a3a4a5a6a7a8a9aaabacadaeaf', 4, 'https://github.com/zig/compat', 'main', 'zig stored prompt', '\x101112131415161718191a1b1c1d1e1f', NULL, 1791192185750, 1791192199696, 1791192200018, NULL, 'https://github.com/zig/compat/pull/1', 1234, 100, 50, 7, 3, 5, true, 'Zig PR title', NULL, NULL);
INSERT INTO public.tasks (id, client_id, state, repo_url, branch, prompt, node_id, vm_id, created_at, started_at, completed_at, error_message, pr_url, compute_time_ms, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, tool_calls, create_pr, pr_title, pr_body, user_id) VALUES ('\x8fcdfd97d5d3cbdbbf6650158494a97530062cc9fbb0e893607b03e638b91cc8', '\xa0a1a2a3a4a5a6a7a8a9aaabacadaeaf', 1, 'git@github.com:zig/compat.git', 'dev', 'zig queued prompt', NULL, NULL, 1791192209231, NULL, NULL, NULL, NULL, 0, 0, 0, 0, 0, 0, false, NULL, NULL, NULL);

INSERT INTO public.usage_records (id, client_id, task_id, "timestamp", compute_time_ms, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, tool_calls, user_id) VALUES (1, '\xa0a1a2a3a4a5a6a7a8a9aaabacadaeaf', '\xe1c01a45331f99b9d64c8f8a4221746cb4d128fce9f47e93bc58e357a275807c', 1791190001000, 1234, 100, 50, 7, 3, 5, NULL);

INSERT INTO public.users (id, email, password_hash, github_id, api_key, created_at, updated_at) VALUES ('\xa0a1a2a3a4a5a6a7a8a9aaabacadaeaf', 'zig@example.com', 'ee4b38627d1338c03dc08d1de8dbff3f:041eeca77e513925902d620c0e6d251ef84995578c3ba0cdd56572b5c6413a8c', NULL, 'zig-api-key-0123456789abcdefghijklmnopqrstuv', 1791190000000, 1791190000000);

SELECT pg_catalog.setval('public.usage_records_id_seq', 1, true);

ALTER TABLE ONLY public.nodes
    ADD CONSTRAINT nodes_pkey PRIMARY KEY (node_id);

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.usage_records
    ADD CONSTRAINT usage_records_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.user_tokens
    ADD CONSTRAINT user_tokens_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.user_tokens
    ADD CONSTRAINT user_tokens_token_hash_key UNIQUE (token_hash);

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_api_key_key UNIQUE (api_key);

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_github_id_key UNIQUE (github_id);

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);

CREATE INDEX idx_nodes_healthy ON public.nodes USING btree (healthy);

CREATE INDEX idx_nodes_last_heartbeat ON public.nodes USING btree (last_heartbeat_at);

CREATE INDEX idx_tasks_client_id ON public.tasks USING btree (client_id);

CREATE INDEX idx_tasks_created_at ON public.tasks USING btree (created_at);

CREATE INDEX idx_tasks_node_id ON public.tasks USING btree (node_id);

CREATE INDEX idx_tasks_state ON public.tasks USING btree (state);

CREATE INDEX idx_tasks_user_id ON public.tasks USING btree (user_id);

CREATE INDEX idx_usage_records_client_id ON public.usage_records USING btree (client_id);

CREATE INDEX idx_usage_records_task_id ON public.usage_records USING btree (task_id);

CREATE INDEX idx_usage_records_timestamp ON public.usage_records USING btree ("timestamp");

CREATE INDEX idx_usage_records_user_id ON public.usage_records USING btree (user_id);

CREATE INDEX idx_user_tokens_expires_at ON public.user_tokens USING btree (expires_at);

CREATE INDEX idx_user_tokens_token_hash ON public.user_tokens USING btree (token_hash);

CREATE INDEX idx_user_tokens_user_id ON public.user_tokens USING btree (user_id);

CREATE INDEX idx_users_api_key ON public.users USING btree (api_key);

CREATE INDEX idx_users_email ON public.users USING btree (email);

CREATE INDEX idx_users_github_id ON public.users USING btree (github_id);

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);

ALTER TABLE ONLY public.usage_records
    ADD CONSTRAINT usage_records_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.tasks(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.usage_records
    ADD CONSTRAINT usage_records_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);

ALTER TABLE ONLY public.user_tokens
    ADD CONSTRAINT user_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

