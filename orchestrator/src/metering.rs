//! Usage records, inclusive reports and lifetime client totals.

use common::{ClientId, TaskId, types::UsageMetrics};
use std::collections::HashMap;

/// Token and compute usage reported for one task at a timestamp.
#[derive(Clone, Debug, PartialEq)]
pub struct UsageRecord {
    /// Client that owns the usage record.
    pub client_id: ClientId,
    /// Task that produced the usage.
    pub task_id: TaskId,
    /// Report time in Unix milliseconds.
    pub timestamp: i64,
    /// Token and compute metrics reported for the task.
    pub usage: UsageMetrics,
}

/// Usage records and lifetime totals for each client.
#[derive(Default)]
pub struct Metering {
    /// Retained usage records in insertion order.
    pub records: Vec<UsageRecord>,
    totals: HashMap<ClientId, UsageMetrics>,
}

impl Metering {
    /// Append usage and update the client lifetime totals.
    pub fn record(&mut self, record: UsageRecord) {
        self.totals
            .entry(record.client_id)
            .or_default()
            .add(&record.usage);
        self.records.push(record);
    }

    /// Return the client lifetime usage, including pruned records.
    pub fn client_total(&self, client: ClientId) -> UsageMetrics {
        self.totals.get(&client).copied().unwrap_or_default()
    }

    /// Sum records for one client over an inclusive timestamp range.
    pub fn report(&self, client: ClientId, start: i64, end: i64) -> (UsageMetrics, u32) {
        let mut total = UsageMetrics::default();
        let mut count: u32 = 0;
        for r in &self.records {
            if r.client_id == client && r.timestamp >= start && r.timestamp <= end {
                total.add(&r.usage);
                count = count.saturating_add(1);
            }
        }
        (total, count)
    }

    /// Drop older records while retaining the client lifetime totals.
    pub fn prune_older_than(&mut self, cutoff: i64) -> usize {
        let n = self.records.len();
        self.records.retain(|r| r.timestamp >= cutoff);
        n - self.records.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(client: ClientId, time: i64) -> UsageRecord {
        UsageRecord {
            client_id: client,
            task_id: TaskId::random(),
            timestamp: time,
            usage: UsageMetrics {
                compute_time_ms: 1000,
                input_tokens: 100,
                output_tokens: 50,
                tool_calls: 5,
                ..UsageMetrics::default()
            },
        }
    }

    // Port of metering/metering.zig "metering basic operations"
    #[test]
    fn basic_operations() {
        let mut m = Metering::default();
        let c = ClientId::random();
        m.record(record(c, 0));
        assert_eq!(m.client_total(c).input_tokens, 100);
        assert_eq!(m.client_total(c).output_tokens, 50);
        assert_eq!(m.client_total(ClientId::random()), UsageMetrics::default());
    }

    // Port of metering/metering.zig "metering getUsageReport with time range"
    #[test]
    fn time_range() {
        let mut m = Metering::default();
        let c = ClientId::random();
        for t in [0, 1000, 2000] {
            m.record(record(c, t));
        }
        assert_eq!(m.report(c, 1000, 2000).1, 2);
        assert_eq!(m.report(c, 1000, 1000).1, 1);
        assert_eq!(m.report(c, 3000, 4000).1, 0);
    }

    // Port of metering/metering.zig "metering getUsageReport filters by client"
    #[test]
    fn filters_client() {
        let mut m = Metering::default();
        let a = ClientId::random();
        let b = ClientId::random();
        m.record(record(a, 0));
        m.record(record(b, 0));
        assert_eq!(m.report(a, 0, 0).1, 1);
    }

    // Port of metering/metering.zig "metering pruneOlderThan removes old records"
    #[test]
    fn prune() {
        let mut m = Metering::default();
        let c = ClientId::random();
        m.record(record(c, 0));
        m.record(record(c, 100));
        assert_eq!(m.prune_older_than(100), 1);
        assert_eq!(m.report(c, 0, 200).1, 1);
        assert_eq!(m.client_total(c).input_tokens, 200);
    }

    // Port of metering/metering.zig "metering accumulates totals across multiple records"
    #[test]
    fn accumulates() {
        let mut m = Metering::default();
        let c = ClientId::random();
        for t in 0..3 {
            m.record(record(c, t));
        }
        assert_eq!(m.client_total(c).input_tokens, 300);
        assert_eq!(m.client_total(c).tool_calls, 15);
    }

    // Port of db/repository/usage.zig "usage record structure"
    #[test]
    fn usage_record_structure() {
        let c = ClientId([1; 16]);
        let r = record(c, 1000);
        assert_eq!(r.client_id, c);
        assert_eq!(r.timestamp, 1000);
        assert_eq!(r.task_id.as_bytes().len(), 32);
        assert_eq!(r.usage.compute_time_ms, 1000);
    }
}
