//! Task output waiting to be reported to the orchestrator.
//!
//! Task runners push output here; the heartbeat loop drains it into a
//! `ReportTaskOutput` call. At most [`MAX_EVENTS`] events are kept; the
//! oldest is dropped first.

use std::collections::VecDeque;
use std::sync::{Mutex, MutexGuard, PoisonError};

use common::pb;
use common::{OutputType, TaskId};

use crate::metrics;

/// Buffer capacity, in events.
pub const MAX_EVENTS: usize = 200;

/// Thread-safe bounded buffer of output events.
#[derive(Debug, Default)]
pub struct OutputBuffer {
    events: Mutex<VecDeque<pb::TaskOutputEvent>>,
}

impl OutputBuffer {
    pub fn new() -> Self {
        Self::default()
    }

    fn lock(&self) -> MutexGuard<'_, VecDeque<pb::TaskOutputEvent>> {
        self.events.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Append one chunk, dropping the oldest event when full.
    pub fn push(&self, task_id: &TaskId, output_type: OutputType, data: &[u8]) {
        let m = metrics::global();
        let mut events = self.lock();
        if events.len() >= MAX_EVENTS {
            events.pop_front();
            m.output_events_dropped.inc();
        }
        events.push_back(pb::TaskOutputEvent {
            task_id: task_id.to_hex(),
            r#type: output_type.to_wire(),
            timestamp: common::types::now_ms(),
            data: data.to_vec(),
        });
        m.output_buffer_depth
            .set(i64::try_from(events.len()).unwrap_or(i64::MAX));
    }

    /// Take every buffered event, oldest first.
    pub fn drain(&self) -> Vec<pb::TaskOutputEvent> {
        let mut events = self.lock();
        let out = events.drain(..).collect();
        metrics::global().output_buffer_depth.set(0);
        out
    }

    pub fn len(&self) -> usize {
        self.lock().len()
    }

    pub fn is_empty(&self) -> bool {
        self.lock().is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_and_drain_in_order() {
        let buf = OutputBuffer::new();
        let task = TaskId::random();
        buf.push(&task, OutputType::Stdout, b"one");
        buf.push(&task, OutputType::Stderr, b"two");
        let events = buf.drain();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].data, b"one");
        assert_eq!(events[0].task_id, task.to_hex());
        assert_eq!(events[0].r#type, pb::OutputType::Stdout as i32);
        assert_eq!(events[1].data, b"two");
        assert_eq!(events[1].r#type, pb::OutputType::Stderr as i32);
        assert!(events[0].timestamp > 0);
        assert!(buf.is_empty());
        assert!(buf.drain().is_empty());
    }

    #[test]
    fn caps_at_200_dropping_oldest() {
        let buf = OutputBuffer::new();
        let task = TaskId::random();
        for i in 0..250 {
            buf.push(&task, OutputType::Stdout, format!("{i}").as_bytes());
        }
        assert_eq!(buf.len(), MAX_EVENTS);
        let events = buf.drain();
        assert_eq!(events.first().unwrap().data, b"50");
        assert_eq!(events.last().unwrap().data, b"249");
    }
}
