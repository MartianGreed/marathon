//! Guest task execution, Ralph iterations, and framed host communication.

/// One-task lifecycle and Ralph iterations.
pub mod agent;

/// Thread-safe API usage parsing and accounting.
pub mod api_interceptor;

/// Claude subprocess execution and output streaming.
pub mod claude_wrapper;

/// Guest cleanup strategies and paths.
pub mod cleanup;

/// Persistent notes and iteration context.
pub mod memory;

/// In-process counters and duration observations.
pub mod metrics;

/// Task prompt template substitution.
pub mod prompt_wrapper;

/// Repository clone and credential setup.
pub mod repo_setup;

/// Completion, clarification, and pull request signals.
pub mod signal_parser;

/// Platform listeners and portable test transport.
pub mod transport;
