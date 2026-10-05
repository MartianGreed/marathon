//! Orchestrator application and transport adapters.

/// Passwords, JWTs, API keys and task input validation.
pub mod auth;

/// Orchestrator-only TLS and metrics configuration.
pub mod config;

/// Postgres repositories and Zig-compatible migrations.
pub mod db;

/// Retained output and live task-event streams.
pub mod events;

/// Task usage records and client totals.
pub mod metering;

/// Heartbeat health, node expiry and capacity.
pub mod registry;

/// FIFO reservations, dispatch and task lifecycle operations.
pub mod scheduler;

/// Listener setup, TLS, metrics and graceful shutdown.
pub mod server;

/// Client and node tonic transport adapters.
pub mod service;

/// Persistence operations and the in-memory fallback.
pub mod store;

/// RPC trace context, spans and metrics.
pub mod telemetry;
