//! Request trace context and metrics. Credentials and payloads never enter spans.

use common::{NodeId, TaskId, telemetry::Operation};
use sqlx::PgPool;
use std::time::Instant;
use tonic::{Request, Status, metadata::MetadataMap};

/// The incoming W3C trace id and optional parent span id.
pub struct TraceContext {
    /// Trace identifier retained from the submit request.
    pub trace_id: String,
    /// Validated incoming parent span id, or None for a new trace.
    pub parent_span_id: Option<String>,
}

impl TraceContext {
    /// Validate W3C traceparent or generate a new trace when it is absent or invalid.
    pub fn from_metadata(metadata: &MetadataMap) -> Self {
        if let Some(s) = metadata.get("traceparent").and_then(|v| v.to_str().ok()) {
            let p: Vec<_> = s.split('-').collect();
            if p.len() == 4
                && p[0] == "00"
                && valid_hex(p[1], 32)
                && valid_hex(p[2], 16)
                && valid_hex(p[3], 2)
                && p[1].bytes().any(|b| b != b'0')
                && p[2].bytes().any(|b| b != b'0')
            {
                return Self {
                    trace_id: p[1].into(),
                    parent_span_id: Some(p[2].into()),
                };
            }
        }
        Self {
            trace_id: hex::encode(rand::random::<[u8; 16]>()),
            parent_span_id: None,
        }
    }
}

fn valid_hex(s: &str, len: usize) -> bool {
    s.len() == len
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Times a request and records its span, status and latency metrics.
pub struct RpcOperation {
    operation: Operation,
    rpc: &'static str,
    /// Trace context resolved from the request metadata.
    pub trace: TraceContext,
    /// Request span used to instrument asynchronous RPC work.
    pub span: tracing::Span,
}

impl RpcOperation {
    /// Mark credentials sensitive and start the request span and latency timer.
    pub fn start<T>(rpc: &'static str, request: &mut Request<T>) -> Self {
        common::client_auth::mark_credentials_sensitive(request.metadata_mut());
        let trace = TraceContext::from_metadata(request.metadata());
        let span = tracing::info_span!(
            "rpc",
            operation = rpc,
            trace_id = %trace.trace_id,
            parent_span_id = trace.parent_span_id.as_deref().unwrap_or(""),
            task_id = tracing::field::Empty,
            node_id = tracing::field::Empty,
            duration_ms = tracing::field::Empty
        );
        let operation = span.in_scope(|| Operation::start(rpc));
        span.in_scope(|| tracing::info!(operation = rpc, "RPC entered"));
        Self {
            operation,
            rpc,
            trace,
            span,
        }
    }

    /// Record request status, latency and the operation outcome.
    pub fn finish<T>(self, result: &Result<T, Status>) {
        let status = result
            .as_ref()
            .map(|_| tonic::Code::Ok)
            .unwrap_or_else(|e| e.code());
        metrics::counter!(
            "marathon_requests_total",
            "rpc"=>self.rpc,
            "status"=>format!(
            "{status:?}"
        )
        )
        .increment(1);
        metrics::histogram!(
            "marathon_rpc_latency_ms",
            "rpc"=>self.rpc
        )
        .record(self.operation.elapsed_ms() as f64);
        self.span.in_scope(|| match result {
            Ok(_) => {
                self.operation.finish();
            }
            Err(e) => {
                self.operation.fail(&e.code());
            }
        });
    }
}

/// Log a classified database error and return a safe INTERNAL status.
pub fn db_error(operation: &'static str, error: &crate::db::DbError) -> Status {
    tracing::error!(
        operation,
        error = %error,
        "database operation failed"
    );
    Status::internal("Database operation failed")
}

/// Times a repository call and samples database pool gauges.
pub struct DbOperation {
    name: &'static str,
    start: Instant,
    pool: PgPool,
    operation: Option<Operation>,
}

impl DbOperation {
    /// Start timing a database operation and retain its pool for gauge samples.
    pub fn new(name: &'static str, pool: PgPool) -> Self {
        Self {
            name,
            start: Instant::now(),
            pool,
            operation: Some(Operation::start(name)),
        }
    }

    /// Record repository success or failure before sampling latency and pool gauges.
    pub fn finish<T>(mut self, result: &Result<T, crate::db::DbError>) {
        if let Some(op) = self.operation.take() {
            match result {
                Ok(_) => {
                    op.finish();
                }
                Err(e) => {
                    metrics::counter!(
                        "marathon_db_errors_total",
                        "operation" => self.name
                    )
                    .increment(1);
                    op.fail(e);
                }
            }
        }
    }
}

impl Drop for DbOperation {
    fn drop(&mut self) {
        metrics::histogram!(
            "marathon_db_latency_ms",
            "operation"=>self.name
        )
        .record(self.start.elapsed().as_secs_f64() * 1000.0);
        metrics::gauge!("marathon_db_pool_size").set(self.pool.size() as f64);
        metrics::gauge!("marathon_db_pool_idle").set(self.pool.num_idle() as f64);
    }
}

/// Count and log a rejected credential without exposing the credential itself.
pub fn auth_failure(kind: &'static str) -> Status {
    metrics::counter!(
        "marathon_auth_failures_total",
        "kind"=>kind
    )
    .increment(1);
    tracing::warn!(operation = "authenticate", kind, "authentication rejected");
    Status::unauthenticated("Invalid or missing credentials")
}

/// Parent span retains the submit trace when a node reports under its own RPC trace.
pub fn task_operation(
    name: &'static str,
    id: TaskId,
    node: Option<NodeId>,
    trace_id: &str,
) -> Operation {
    let span = tracing::info_span!(
        "task",
        operation = name,
        task_id = %id,
        node_id = node.map(|n|n.to_hex()).as_deref().unwrap_or(""),
        trace_id,
        duration_ms = tracing::field::Empty
    );
    span.in_scope(|| {
        tracing::debug!(operation = name, "task operation entered");
        let op = Operation::start(name).task_id(&id);
        if let Some(node) = node {
            op.node_id(&node)
        } else {
            op
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn traceparent_validation() {
        let mut m = MetadataMap::new();
        m.insert(
            "traceparent",
            "00-00112233445566778899aabbccddeeff-0123456789abcdef-01"
                .parse()
                .unwrap(),
        );
        let trace = TraceContext::from_metadata(&m);
        assert_eq!(trace.trace_id, "00112233445566778899aabbccddeeff");
        assert_eq!(trace.parent_span_id.as_deref(), Some("0123456789abcdef"));
        for s in [
            "garbage",
            "00-00000000000000000000000000000000-0123456789abcdef-01",
            "00-00112233445566778899aabbccddeeff-0000000000000000-01",
            "00-00112233445566778899aabbccddeefg-0123456789abcdef-01",
            "01-00112233445566778899aabbccddeeff-0123456789abcdef-01",
        ] {
            m.insert("traceparent", s.parse().unwrap());
            let t = TraceContext::from_metadata(&m);
            assert_eq!(t.trace_id.len(), 32);
            assert!(t.parent_span_id.is_none());
        }
    }

    #[tokio::test]
    async fn rpc_metrics_status_and_sensitive_credentials() {
        let recorder = metrics_exporter_prometheus::PrometheusBuilder::new().build_recorder();
        let handle = recorder.handle();
        let mut r = Request::new(());
        r.metadata_mut()
            .insert("x-api-key", "secret-not-for-logs".parse().unwrap());
        metrics::with_local_recorder(&recorder, || {
            let op = RpcOperation::start("TestRpc", &mut r);
            assert!(!format!("{:?}", r.metadata()).contains("secret-not-for-logs"));
            op.finish(&Err::<(), _>(Status::unauthenticated("missing")));
        });
        let output = handle.render();
        assert!(output.contains("marathon_requests_total"));
        assert!(output.contains("Unauthenticated"));
        assert!(output.contains("marathon_rpc_latency_ms"));
    }
}
