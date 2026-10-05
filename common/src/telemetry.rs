//! Tracing setup and the structured fields every binary uses.
//!
//! Log lines and spans carry these field names (see [`fields`]):
//! `task_id`, `node_id`, `operation`, `duration_ms`. Ids are logged in their
//! lowercase hex form.
//!
//! ```no_run
//! common::telemetry::init("marathon-orchestrator");
//! let op = common::telemetry::Operation::start("schedule_task")
//!     .task_id(&common::TaskId::random());
//! // ... work ...
//! op.finish(); // logs `operation`, `task_id` and `duration_ms`
//! ```

use std::fmt::Display;
use std::time::Instant;

use tracing_subscriber::EnvFilter;
use tracing_subscriber::fmt::format::FmtSpan;

/// Standard structured field names.
pub mod fields {
    pub const TASK_ID: &str = "task_id";
    pub const NODE_ID: &str = "node_id";
    pub const OPERATION: &str = "operation";
    pub const DURATION_MS: &str = "duration_ms";
}

/// Filter used when `RUST_LOG` is unset.
pub const DEFAULT_FILTER: &str = "info";
/// `MARATHON_LOG_FORMAT=json` switches to one JSON object per line.
pub const LOG_FORMAT_VAR: &str = "MARATHON_LOG_FORMAT";

/// Install the global subscriber: level from `RUST_LOG` (default `info`),
/// human-readable output or JSON when `MARATHON_LOG_FORMAT=json`, written to
/// stderr. Safe to call more than once; later calls do nothing.
pub fn init(service: &'static str) {
    let filter =
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(DEFAULT_FILTER));
    let json = std::env::var(LOG_FORMAT_VAR).is_ok_and(|v| v.eq_ignore_ascii_case("json"));
    let builder = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .with_target(true)
        .with_span_events(FmtSpan::NONE);
    let installed = if json {
        builder.json().flatten_event(true).try_init().is_ok()
    } else {
        builder.try_init().is_ok()
    };
    if installed {
        tracing::info!(
            service,
            version = env!("CARGO_PKG_VERSION"),
            "tracing initialised"
        );
    }
}

/// A timed unit of work. Holds an `info` span with `operation`, `task_id`
/// and `node_id`, and logs `duration_ms` when finished or dropped.
#[must_use = "an Operation logs its duration when finished or dropped"]
pub struct Operation {
    name: &'static str,
    span: tracing::Span,
    started: Instant,
    done: bool,
}

impl Operation {
    pub fn start(name: &'static str) -> Self {
        let span = tracing::info_span!(
            "operation",
            operation = name,
            task_id = tracing::field::Empty,
            node_id = tracing::field::Empty,
            duration_ms = tracing::field::Empty,
        );
        Self {
            name,
            span,
            started: Instant::now(),
            done: false,
        }
    }

    /// Record the task id on the span.
    pub fn task_id(self, id: &impl Display) -> Self {
        self.span
            .record(fields::TASK_ID, tracing::field::display(id));
        self
    }

    /// Record the node id on the span.
    pub fn node_id(self, id: &impl Display) -> Self {
        self.span
            .record(fields::NODE_ID, tracing::field::display(id));
        self
    }

    /// The span, for `Instrument::instrument` or `span.in_scope`.
    pub fn span(&self) -> &tracing::Span {
        &self.span
    }

    /// Milliseconds since `start`.
    pub fn elapsed_ms(&self) -> u64 {
        u64::try_from(self.started.elapsed().as_millis()).unwrap_or(u64::MAX)
    }

    /// Record `duration_ms` and log completion at `info`.
    pub fn finish(mut self) -> u64 {
        self.complete(None)
    }

    /// Record `duration_ms` and log the failure at `error`.
    pub fn fail(mut self, error: &dyn std::fmt::Display) -> u64 {
        self.complete(Some(error))
    }

    fn complete(&mut self, error: Option<&dyn std::fmt::Display>) -> u64 {
        self.done = true;
        let duration_ms = self.elapsed_ms();
        self.span.record(fields::DURATION_MS, duration_ms);
        let _guard = self.span.enter();
        match error {
            None => tracing::info!(operation = self.name, duration_ms, "operation finished"),
            Some(e) => {
                tracing::error!(operation = self.name, duration_ms, error = %e, "operation failed")
            }
        }
        duration_ms
    }
}

impl Drop for Operation {
    fn drop(&mut self) {
        if !self.done {
            self.complete(None);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io;
    use std::sync::{Arc, Mutex};

    #[derive(Clone, Default)]
    struct Buf(Arc<Mutex<Vec<u8>>>);

    impl io::Write for Buf {
        fn write(&mut self, data: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(data);
            Ok(data.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    fn capture(f: impl FnOnce()) -> String {
        let buf = Buf::default();
        let writer = buf.clone();
        let subscriber = tracing_subscriber::fmt()
            .json()
            .with_current_span(true)
            .with_span_list(false)
            .with_writer(move || writer.clone())
            .finish();
        tracing::subscriber::with_default(subscriber, f);
        String::from_utf8(buf.0.lock().unwrap().clone()).unwrap()
    }

    #[test]
    fn operation_logs_structured_fields() {
        let task = crate::TaskId::from_bytes([0xab; 32]);
        let node = crate::NodeId::from_bytes([0x01; 16]);
        let out = capture(|| {
            Operation::start("dispatch")
                .task_id(&task)
                .node_id(&node)
                .finish();
        });
        assert!(out.contains("\"operation\":\"dispatch\""), "{out}");
        assert!(out.contains(&format!("\"task_id\":\"{task}\"")), "{out}");
        assert!(out.contains(&format!("\"node_id\":\"{node}\"")), "{out}");
        assert!(out.contains("\"duration_ms\":"), "{out}");
        assert!(out.contains("operation finished"), "{out}");
    }

    #[test]
    fn failed_operation_logs_error() {
        let out = capture(|| {
            Operation::start("vsock_connect").fail(&"refused");
        });
        assert!(out.contains("\"level\":\"ERROR\""), "{out}");
        assert!(out.contains("refused"), "{out}");
        assert!(out.contains("\"duration_ms\":"), "{out}");
    }

    #[test]
    fn dropped_operation_still_logs_once() {
        let out = capture(|| {
            let _op = Operation::start("heartbeat");
        });
        assert_eq!(out.matches("operation finished").count(), 1, "{out}");
    }

    #[test]
    fn init_is_idempotent() {
        init("test");
        init("test");
    }
}
