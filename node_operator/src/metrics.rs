//! In-process metrics for the node operator.
//!
//! Counters, gauges and fixed-bucket latency histograms backed by atomics.
//! The workspace has no metrics exporter yet, so [`Metrics::log`] writes a
//! snapshot at `debug` on every heartbeat and tests read the values directly.

use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::time::Duration;

/// A monotonically increasing count.
#[derive(Debug, Default)]
pub struct Counter(AtomicU64);

impl Counter {
    pub const fn new() -> Self {
        Self(AtomicU64::new(0))
    }

    pub fn inc(&self) {
        self.add(1);
    }

    pub fn add(&self, n: u64) {
        self.0.fetch_add(n, Ordering::Relaxed);
    }

    pub fn get(&self) -> u64 {
        self.0.load(Ordering::Relaxed)
    }
}

/// A value that goes up and down.
#[derive(Debug, Default)]
pub struct Gauge(AtomicI64);

impl Gauge {
    pub const fn new() -> Self {
        Self(AtomicI64::new(0))
    }

    pub fn set(&self, v: i64) {
        self.0.store(v, Ordering::Relaxed);
    }

    pub fn get(&self) -> i64 {
        self.0.load(Ordering::Relaxed)
    }
}

/// Upper bounds of the latency buckets, in milliseconds. A last implicit
/// bucket holds everything slower.
pub const LATENCY_BUCKETS_MS: [u64; 14] = [
    5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 30_000, 60_000, 600_000,
];

/// Latency distribution with fixed buckets.
#[derive(Debug)]
pub struct Histogram {
    buckets: [AtomicU64; LATENCY_BUCKETS_MS.len() + 1],
    count: AtomicU64,
    sum_ms: AtomicU64,
}

impl Default for Histogram {
    fn default() -> Self {
        Self::new()
    }
}

impl Histogram {
    pub const fn new() -> Self {
        Self {
            buckets: [const { AtomicU64::new(0) }; LATENCY_BUCKETS_MS.len() + 1],
            count: AtomicU64::new(0),
            sum_ms: AtomicU64::new(0),
        }
    }

    pub fn observe_ms(&self, ms: u64) {
        let idx = LATENCY_BUCKETS_MS
            .iter()
            .position(|&b| ms <= b)
            .unwrap_or(LATENCY_BUCKETS_MS.len());
        self.buckets[idx].fetch_add(1, Ordering::Relaxed);
        self.count.fetch_add(1, Ordering::Relaxed);
        self.sum_ms.fetch_add(ms, Ordering::Relaxed);
    }

    pub fn observe(&self, d: Duration) {
        self.observe_ms(u64::try_from(d.as_millis()).unwrap_or(u64::MAX));
    }

    pub fn count(&self) -> u64 {
        self.count.load(Ordering::Relaxed)
    }

    pub fn sum_ms(&self) -> u64 {
        self.sum_ms.load(Ordering::Relaxed)
    }

    /// Count in each bucket, the last one being "slower than every bound".
    pub fn buckets(&self) -> Vec<u64> {
        self.buckets
            .iter()
            .map(|b| b.load(Ordering::Relaxed))
            .collect()
    }
}

/// Every node-operator metric.
#[derive(Debug)]
pub struct Metrics {
    // Heartbeat stream and reports
    pub heartbeats_sent: Counter,
    pub heartbeat_responses: Counter,
    pub heartbeat_errors: Counter,
    pub heartbeat_auth_failures: Counter,
    pub reconnects: Counter,
    pub commands_received: Counter,
    pub result_reports: Counter,
    pub result_report_errors: Counter,
    pub output_reports: Counter,
    pub output_report_errors: Counter,
    pub heartbeat_connect_ms: Histogram,
    pub report_rpc_ms: Histogram,

    // Tasks
    pub tasks_started: Counter,
    pub tasks_succeeded: Counter,
    pub tasks_failed: Counter,
    pub tasks_cancelled: Counter,
    pub tasks_rejected: Counter,
    pub task_duration_ms: Histogram,
    pub vsock_connect_retries: Counter,

    // VMs and Firecracker
    pub vm_boots: Counter,
    pub vm_boot_failures: Counter,
    pub vm_boot_ms: Histogram,
    pub firecracker_api_calls: Counter,
    pub firecracker_api_errors: Counter,
    pub firecracker_api_ms: Histogram,
    pub warm_vms: Gauge,
    pub active_vms: Gauge,

    // Output buffer
    pub output_buffer_depth: Gauge,
    pub output_events_dropped: Counter,
}

impl Default for Metrics {
    fn default() -> Self {
        Self::new()
    }
}

impl Metrics {
    pub const fn new() -> Self {
        Self {
            heartbeats_sent: Counter::new(),
            heartbeat_responses: Counter::new(),
            heartbeat_errors: Counter::new(),
            heartbeat_auth_failures: Counter::new(),
            reconnects: Counter::new(),
            commands_received: Counter::new(),
            result_reports: Counter::new(),
            result_report_errors: Counter::new(),
            output_reports: Counter::new(),
            output_report_errors: Counter::new(),
            heartbeat_connect_ms: Histogram::new(),
            report_rpc_ms: Histogram::new(),
            tasks_started: Counter::new(),
            tasks_succeeded: Counter::new(),
            tasks_failed: Counter::new(),
            tasks_cancelled: Counter::new(),
            tasks_rejected: Counter::new(),
            task_duration_ms: Histogram::new(),
            vsock_connect_retries: Counter::new(),
            vm_boots: Counter::new(),
            vm_boot_failures: Counter::new(),
            vm_boot_ms: Histogram::new(),
            firecracker_api_calls: Counter::new(),
            firecracker_api_errors: Counter::new(),
            firecracker_api_ms: Histogram::new(),
            warm_vms: Gauge::new(),
            active_vms: Gauge::new(),
            output_buffer_depth: Gauge::new(),
            output_events_dropped: Counter::new(),
        }
    }

    /// Log the current values at `debug`.
    pub fn log(&self) {
        tracing::debug!(
            operation = "metrics",
            heartbeats_sent = self.heartbeats_sent.get(),
            heartbeat_responses = self.heartbeat_responses.get(),
            heartbeat_errors = self.heartbeat_errors.get(),
            heartbeat_auth_failures = self.heartbeat_auth_failures.get(),
            reconnects = self.reconnects.get(),
            commands_received = self.commands_received.get(),
            result_reports = self.result_reports.get(),
            result_report_errors = self.result_report_errors.get(),
            output_reports = self.output_reports.get(),
            output_report_errors = self.output_report_errors.get(),
            tasks_started = self.tasks_started.get(),
            tasks_succeeded = self.tasks_succeeded.get(),
            tasks_failed = self.tasks_failed.get(),
            tasks_cancelled = self.tasks_cancelled.get(),
            tasks_rejected = self.tasks_rejected.get(),
            vm_boots = self.vm_boots.get(),
            vm_boot_failures = self.vm_boot_failures.get(),
            firecracker_api_calls = self.firecracker_api_calls.get(),
            firecracker_api_errors = self.firecracker_api_errors.get(),
            warm_vms = self.warm_vms.get(),
            active_vms = self.active_vms.get(),
            output_buffer_depth = self.output_buffer_depth.get(),
            output_events_dropped = self.output_events_dropped.get(),
            "node metrics"
        );
    }
}

static METRICS: Metrics = Metrics::new();

/// The process-wide metrics.
pub fn global() -> &'static Metrics {
    &METRICS
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counter_and_gauge() {
        let c = Counter::new();
        c.inc();
        c.add(2);
        assert_eq!(c.get(), 3);
        let g = Gauge::new();
        g.set(7);
        g.set(4);
        assert_eq!(g.get(), 4);
    }

    #[test]
    fn histogram_buckets_by_upper_bound() {
        let h = Histogram::new();
        h.observe_ms(0);
        h.observe_ms(5);
        h.observe_ms(6);
        h.observe_ms(700_000);
        let b = h.buckets();
        assert_eq!(b[0], 2, "0 and 5 ms land in the <=5 bucket");
        assert_eq!(b[1], 1, "6 ms lands in the <=10 bucket");
        assert_eq!(b[LATENCY_BUCKETS_MS.len()], 1, "overflow bucket");
        assert_eq!(h.count(), 4);
        assert_eq!(h.sum_ms(), 700_011);
    }
}
