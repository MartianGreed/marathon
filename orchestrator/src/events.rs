//! Bounded, non-consuming output snapshots and sequenced broadcasts.

use common::{pb, types::Task};
use std::collections::VecDeque;
use tokio::sync::broadcast;

/// One task event with its broadcast sequence number.
#[derive(Clone)]
pub struct SequencedEvent {
    /// Monotonic sequence used to fence snapshots against live broadcasts.
    pub sequence: u64,
    /// The protobuf event delivered to readers.
    pub event: pb::TaskEvent,
}

/// Retained task output and live broadcasts sharing a sequence fence.
pub struct Events {
    /// At most 500 retained output events, oldest first.
    pub outputs: VecDeque<SequencedEvent>,
    /// Live task-event broadcast channel.
    pub sender: broadcast::Sender<SequencedEvent>,
    /// Monotonic sequence used to fence snapshots against live broadcasts.
    pub sequence: u64,
}

impl Default for Events {
    fn default() -> Self {
        let (sender, _) = broadcast::channel(500);
        Self {
            outputs: VecDeque::new(),
            sender,
            sequence: 0,
        }
    }
}

impl Events {
    /// Retain output up to the buffer limit and broadcast the sequenced event.
    pub fn publish(&mut self, event: pb::TaskEvent) {
        self.sequence = self.sequence.saturating_add(1);
        let value = SequencedEvent {
            sequence: self.sequence,
            event,
        };
        if matches!(value.event.event, Some(pb::task_event::Event::Output(_))) {
            if self.outputs.len() == 500 {
                self.outputs.pop_front();
            }
            self.outputs.push_back(value.clone());
        }
        let _ = self.sender.send(value);
    }
}

/// Build a state-change event from the current task snapshot.
pub fn state_event(task: &Task, previous: i32) -> pb::TaskEvent {
    pb::TaskEvent {
        task_id: task.id.to_hex(),
        state: task.state.to_wire(),
        timestamp: common::types::now_ms(),
        event: Some(pb::task_event::Event::StateChange(pb::TaskStateChange {
            previous_state: previous,
        })),
    }
}

/// Build a terminal event with the task usage, PR URL and error.
pub fn complete_event(task: &Task) -> pb::TaskEvent {
    pb::TaskEvent {
        task_id: task.id.to_hex(),
        state: task.state.to_wire(),
        timestamp: task.completed_at.unwrap_or_else(common::types::now_ms),
        event: Some(pb::task_event::Event::Complete(pb::TaskComplete {
            usage: Some(task.usage.into()),
            pr_url: task.pr_url.clone(),
            error_message: task.error_message.clone(),
        })),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{scheduler::Orchestrator, service::Service, store::MemoryStore};
    use common::{ClientId, NodeId, TaskId, types::NodeStatus};
    use futures::StreamExt;
    use std::{sync::Arc, time::Duration};

    #[tokio::test]
    async fn output_bound_snapshot_fence_and_lag() {
        let app = Orchestrator::new(
            common::config::OrchestratorConfig {
                jwt_secret: Some("test".into()),
                ..Default::default()
            },
            Arc::new(MemoryStore::default()),
        );
        let id = app
            .submit(
                Task::new(
                    ClientId::random(),
                    "https://example.com/repo",
                    "main",
                    "prompt",
                ),
                "trace".into(),
            )
            .await
            .unwrap();
        let node = NodeId::random();
        app.heartbeat(
            node,
            NodeStatus {
                node_id: node,
                total_vm_slots: 1,
                healthy: true,
                ..Default::default()
            },
            1,
        )
        .await
        .unwrap();
        let service = Service { app: app.clone() };
        let output = |n: u32| pb::TaskOutputEvent {
            task_id: id.to_hex(),
            r#type: 1,
            timestamp: i64::from(n),
            data: n.to_le_bytes().to_vec(),
        };
        for n in 0..505 {
            app.output(node, output(n), id).await.unwrap();
        }
        for _ in 0..2 {
            let mut snapshot = service.event_stream(id, false, false).await.unwrap();
            assert_eq!(snapshot.next().await.unwrap().unwrap().state, 3);
            let mut count = 0;
            while let Some(event) = snapshot.next().await {
                let event = event.unwrap();
                let Some(pb::task_event::Event::Output(out)) = event.event else {
                    panic!("output required")
                };
                assert_eq!(out.data, (count + 5u32).to_le_bytes());
                count += 1;
            }
            assert_eq!(count, 500);
        }
        let mut follow = service.event_stream(id, true, false).await.unwrap();
        // Live events published after snapshot are received exactly once.
        app.output(node, output(505), id).await.unwrap();
        for _ in 0..501 {
            follow.next().await.unwrap().unwrap();
        }
        let event = follow.next().await.unwrap().unwrap();
        assert_eq!(event.timestamp, 505);
        // Force broadcast lag while the subscriber is not polled.
        for n in 506..1106 {
            app.output(node, output(n), id).await.unwrap();
        }
        app.result(
            node,
            pb::TaskResult {
                task_id: id.to_hex(),
                success: true,
                ..Default::default()
            },
            id,
        )
        .await
        .unwrap();
        let dropped = follow.next().await.unwrap().unwrap();
        assert!(matches!(
        dropped.event,
        Some(pb::task_event::Event::Error(pb::TaskError{
        ref code,..
        })) if code=="EVENTS_DROPPED"
        ));
        tokio::time::timeout(Duration::from_secs(2), async {
            while let Some(event) = follow.next().await {
                if matches!(
                    event.unwrap().event,
                    Some(pb::task_event::Event::Complete(_))
                ) {
                    break;
                }
            }
            assert!(follow.next().await.is_none());
        })
        .await
        .unwrap();
        assert!(app.get_task(TaskId::random()).await.unwrap().is_none());
    }
}
