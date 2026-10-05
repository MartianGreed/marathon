//! In-process counters, active-task gauge, and duration observations.

use common::{pb::VsockMessage, vsock};
use std::{
    collections::BTreeMap,
    sync::{
        Mutex,
        atomic::{AtomicU64, Ordering},
    },
};

/// Fixed buckets keep observations bounded even for a very long Ralph loop.
#[derive(Debug, Default)]
struct DurationObservation {
    count: u64,
    sum_ms: u64,
    max_ms: u64,
    buckets: [u64; 7],
}

impl DurationObservation {
    fn record(&mut self, ms: u64) {
        self.count = self.count.saturating_add(1);
        self.sum_ms = self.sum_ms.saturating_add(ms);
        self.max_ms = self.max_ms.max(ms);
        let bucket = [1, 10, 100, 1000, 10_000, 60_000].partition_point(|bound| ms > *bound);
        self.buckets[bucket] = self.buckets[bucket].saturating_add(1);
    }
}

/// In-process task counters, gauge, and bounded duration observations.
#[derive(Default)]
pub struct Registry {
    /// Total listener connections accepted, including probes.
    pub connections_accepted: AtomicU64,
    /// Connections dropped before a valid Start arrived.
    pub probe_resets: AtomicU64,
    /// Total Claude iterations started.
    pub iterations: AtomicU64,
    /// Current number of running tasks.
    pub active_tasks: AtomicU64,
    frames: Mutex<BTreeMap<&'static str, AtomicU64>>,
    errors: Mutex<BTreeMap<&'static str, AtomicU64>>,
    durations: Mutex<BTreeMap<&'static str, DurationObservation>>,
}

impl Registry {
    /// Count a successfully written frame by payload kind.
    pub fn frame_sent(&self, frame: &VsockMessage) {
        let mut frames = self.frames.lock().unwrap_or_else(|e| e.into_inner());
        frames
            .entry(vsock::kind(frame))
            .or_default()
            .fetch_add(1, Ordering::Relaxed);
    }

    /// Count a task or protocol error by its stable code.
    pub fn error(&self, code: &'static str) {
        let mut errors = self.errors.lock().unwrap_or_else(|e| e.into_inner());
        errors
            .entry(code)
            .or_default()
            .fetch_add(1, Ordering::Relaxed);
    }

    /// Record a duration in milliseconds for an operation.
    pub fn observe(&self, operation: &'static str, ms: u64) {
        self.durations
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .entry(operation)
            .or_default()
            .record(ms);
    }

    /// Log counters, gauge, and duration observations for the task.
    pub fn summary(&self, task_id: &str) {
        tracing::info!(
            task_id,
            operation = "metrics",
            connections_accepted = self.connections_accepted.load(Ordering::Relaxed),
            probe_resets = self.probe_resets.load(Ordering::Relaxed),
            iterations = self.iterations.load(Ordering::Relaxed),
            active_tasks = self.active_tasks.load(Ordering::Relaxed),
            frames_sent = ?*self.frames.lock().unwrap_or_else(|e| e.into_inner()),
            errors_by_code = ?*self.errors.lock().unwrap_or_else(|e| e.into_inner()),
            durations_ms = ?*self.durations.lock().unwrap_or_else(|e| e.into_inner()),
            "Guest metrics summary"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counters_and_bounded_duration_observations() {
        let r = Registry::default();
        r.error("cancelled");
        r.error("cancelled");
        r.frame_sent(
            &common::pb::vsock_message::Payload::Ready(common::pb::VsockReady { vm_id: 0 }).into(),
        );
        r.observe("claude_run", 2);
        r.observe("claude_run", 70_000);
        assert_eq!(
            r.errors.lock().unwrap()["cancelled"].load(Ordering::Relaxed),
            2
        );
        assert_eq!(r.frames.lock().unwrap()["ready"].load(Ordering::Relaxed), 1);
        let d = r.durations.lock().unwrap();
        assert_eq!(d["claude_run"].count, 2);
        assert_eq!(d["claude_run"].sum_ms, 70_002);
        assert_eq!(d["claude_run"].max_ms, 70_000);
        assert_eq!(d["claude_run"].buckets, [0, 1, 0, 0, 0, 0, 1]);
    }
}
