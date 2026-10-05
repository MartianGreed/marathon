//! W3C trace context for outgoing calls.
//!
//! Each heartbeat stream and report call carries a `traceparent` header
//! (`00-<trace id>-<span id>-01`) in its gRPC metadata, and the node logs the
//! trace id next to the call so its logs join the orchestrator's.

use std::fmt;

use tonic::metadata::MetadataValue;

/// gRPC metadata key of the W3C trace context.
pub const TRACEPARENT: &str = "traceparent";

/// A trace id and the id of the current span within it.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct TraceContext {
    trace_id: [u8; 16],
    span_id: [u8; 8],
}

fn nonzero<const N: usize>() -> [u8; N] {
    loop {
        let bytes: [u8; N] = rand::random();
        if bytes.iter().any(|&b| b != 0) {
            return bytes;
        }
    }
}

impl TraceContext {
    /// A new trace.
    pub fn new_root() -> Self {
        Self {
            trace_id: nonzero(),
            span_id: nonzero(),
        }
    }

    /// A new span in the same trace.
    pub fn child(&self) -> Self {
        Self {
            trace_id: self.trace_id,
            span_id: nonzero(),
        }
    }

    pub fn trace_id(&self) -> String {
        hex::encode(self.trace_id)
    }

    pub fn span_id(&self) -> String {
        hex::encode(self.span_id)
    }

    /// The `traceparent` header value, sampled.
    pub fn traceparent(&self) -> String {
        format!("00-{}-{}-01", self.trace_id(), self.span_id())
    }

    /// Parse a version-00 `traceparent` value.
    pub fn parse(value: &str) -> Option<Self> {
        let mut parts = value.split('-');
        let (version, trace, span, flags) =
            (parts.next()?, parts.next()?, parts.next()?, parts.next()?);
        if parts.next().is_some() || version != "00" || flags.len() != 2 {
            return None;
        }
        let trace_id: [u8; 16] = hex::decode(trace).ok()?.try_into().ok()?;
        let span_id: [u8; 8] = hex::decode(span).ok()?.try_into().ok()?;
        if trace_id == [0; 16] || span_id == [0; 8] {
            return None;
        }
        Some(Self { trace_id, span_id })
    }

    /// Put this context on an outgoing request.
    pub fn inject<T>(&self, request: &mut tonic::Request<T>) {
        // A traceparent is always printable ASCII.
        if let Ok(v) = MetadataValue::try_from(self.traceparent()) {
            request.metadata_mut().insert(TRACEPARENT, v);
        }
    }
}

impl fmt::Debug for TraceContext {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.traceparent())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn traceparent_round_trips() {
        let root = TraceContext::new_root();
        let tp = root.traceparent();
        assert_eq!(tp.len(), 55);
        assert!(tp.starts_with("00-") && tp.ends_with("-01"));
        assert_eq!(TraceContext::parse(&tp), Some(root));
    }

    #[test]
    fn child_keeps_trace_id() {
        let root = TraceContext::new_root();
        let child = root.child();
        assert_eq!(child.trace_id(), root.trace_id());
        assert_ne!(child.span_id(), root.span_id());
    }

    #[test]
    fn parse_rejects_bad_values() {
        assert!(TraceContext::parse("").is_none());
        assert!(
            TraceContext::parse("01-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
                .is_none()
        );
        assert!(
            TraceContext::parse("00-00000000000000000000000000000000-b7ad6b7169203331-01")
                .is_none()
        );
        assert!(
            TraceContext::parse("00-0af7651916cd43dd8448eb211c80319c-0000000000000000-01")
                .is_none()
        );
        assert!(
            TraceContext::parse("00-0af7651916cd43dd8448eb211c80319c-b7ad6b71692033-01").is_none()
        );
        assert!(
            TraceContext::parse("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01-x")
                .is_none()
        );
        assert!(
            TraceContext::parse("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
                .is_some()
        );
    }

    #[test]
    fn inject_sets_metadata() {
        let ctx = TraceContext::new_root();
        let mut req = tonic::Request::new(());
        ctx.inject(&mut req);
        let got = req.metadata().get(TRACEPARENT).unwrap().to_str().unwrap();
        assert_eq!(got, ctx.traceparent());
    }
}
