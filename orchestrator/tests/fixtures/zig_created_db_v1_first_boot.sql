
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
    pr_body text
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
    tool_calls bigint DEFAULT 0
);

CREATE SEQUENCE public.usage_records_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.usage_records_id_seq OWNED BY public.usage_records.id;

ALTER TABLE ONLY public.usage_records ALTER COLUMN id SET DEFAULT nextval('public.usage_records_id_seq'::regclass);

INSERT INTO public.schema_migrations (version, applied_at, description) VALUES (1, 1791192164614, 'initial schema');

SELECT pg_catalog.setval('public.usage_records_id_seq', 1, false);

ALTER TABLE ONLY public.nodes
    ADD CONSTRAINT nodes_pkey PRIMARY KEY (node_id);

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.usage_records
    ADD CONSTRAINT usage_records_pkey PRIMARY KEY (id);

CREATE INDEX idx_nodes_healthy ON public.nodes USING btree (healthy);

CREATE INDEX idx_nodes_last_heartbeat ON public.nodes USING btree (last_heartbeat_at);

CREATE INDEX idx_tasks_client_id ON public.tasks USING btree (client_id);

CREATE INDEX idx_tasks_created_at ON public.tasks USING btree (created_at);

CREATE INDEX idx_tasks_node_id ON public.tasks USING btree (node_id);

CREATE INDEX idx_tasks_state ON public.tasks USING btree (state);

CREATE INDEX idx_usage_records_client_id ON public.usage_records USING btree (client_id);

CREATE INDEX idx_usage_records_task_id ON public.usage_records USING btree (task_id);

CREATE INDEX idx_usage_records_timestamp ON public.usage_records USING btree ("timestamp");

ALTER TABLE ONLY public.usage_records
    ADD CONSTRAINT usage_records_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.tasks(id) ON DELETE CASCADE;

