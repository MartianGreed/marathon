//! Authenticated node heartbeat streams and task output/result reports.

use super::{HeartbeatStream, Service};
use crate::telemetry::{RpcOperation, auth_failure};
use common::{
    NodeId, TaskId,
    node_auth::verify_node_auth,
    pb,
    types::{NodeStatus, now_ms},
};
use tokio_stream::wrappers::ReceiverStream;
use tonic::{Request, Response, Status, Streaming};
use tracing::Instrument;

/// Check the resource ranges reported in a heartbeat before converting its status.
fn validate_node_status(status: &pb::NodeStatus) -> Result<(), Status> {
    if !status.cpu_usage.is_finite()
        || !status.memory_usage.is_finite()
        || !(0.0..=1.0).contains(&status.cpu_usage)
        || !(0.0..=1.0).contains(&status.memory_usage)
        || status.active_vms > status.total_vm_slots
        || status.warm_vms > status.total_vm_slots
        || status.disk_available_bytes < 0
        || status.uptime_seconds < 0
    {
        return Err(Status::invalid_argument("Invalid node status"));
    }
    Ok(())
}

impl Service {
    /// Parse a node identity and verify its HMAC when a key is configured.
    pub fn authenticate_node(&self, auth: Option<&pb::NodeAuth>) -> Result<NodeId, Status> {
        if let Some(key) = &self.app.config.node_auth_key {
            verify_node_auth(key.as_bytes(), auth, now_ms()).map_err(|_| auth_failure("node"))
        } else {
            NodeId::parse(
                &auth
                    .ok_or_else(|| Status::invalid_argument("Missing node identity"))?
                    .node_id,
            )
            .map_err(|_| Status::invalid_argument("Invalid node id"))
        }
    }
}

#[tonic::async_trait]
impl pb::node_service_server::NodeService for Service {
    type HeartbeatStream = HeartbeatStream;

    async fn heartbeat(
        &self,
        mut request: Request<Streaming<pb::NodeHeartbeat>>,
    ) -> Result<Response<HeartbeatStream>, Status> {
        let op = RpcOperation::start("Heartbeat", &mut request);
        let span = op.span.clone();
        let mut incoming = request.into_inner();
        let service = self.clone();
        let (tx, rx) = tokio::sync::mpsc::channel(1);
        let generation = rand::random::<u64>();
        let worker = async move {
            let mut shutdown = service.app.shutdown.subscribe();
            let mut bound = None;
            let result: Result<(), Status> = async {
                loop {
                    if *shutdown.borrow() {
                        break;
                    }
                    let message = tokio::select! {
                        _ = shutdown.changed() => break,
                        _ = tx.closed() => break,
                        message = incoming.message() => message?,
                    };
                    let Some(message) = message else {
                        break;
                    };
                    let node = service.authenticate_node(message.auth.as_ref())?;
                    if bound.is_some_and(|id| id != node) {
                        return Err(auth_failure("node"));
                    }
                    if bound.is_some()
                        && service
                            .app
                            .state
                            .lock()
                            .await
                            .sessions
                            .get(&node)
                            .is_some_and(|s| s.generation != generation)
                    {
                        return Err(Status::aborted(
                            "Heartbeat stream superseded by a new connection",
                        ));
                    }
                    op.span.record("node_id", node.to_hex());
                    let status = message
                        .status
                        .ok_or_else(|| Status::invalid_argument("Missing node status"))?;
                    validate_node_status(&status)?;
                    let status = NodeStatus::from_proto(node, &status)
                        .map_err(|_| Status::invalid_argument("Invalid active task id"))?;
                    bound = Some(node);
                    // Wait for response capacity before changing task states. There
                    // is exactly one response per received heartbeat.
                    let permit = tokio::select! {
                        _ = shutdown.changed() => break,
                        _ = tx.closed() => break,
                        p = tx.reserve() => {
                            p.map_err(|_| Status::cancelled("Heartbeat closed"))?
                        },
                    };
                    let response = service.app.heartbeat(node, status, generation).await?;
                    permit.send(Ok(response));
                }
                Ok(())
            }
            .await;
            if let Some(node) = bound {
                let mut state = service.app.state.lock().await;
                service.app.release(&mut state, node, generation);
            }
            op.finish(&result);
            if let Err(status) = result {
                let _ = tx.send(Err(status)).await;
            }
        };
        tokio::spawn(worker.instrument(span));
        Ok(Response::new(
            Box::pin(ReceiverStream::new(rx)) as HeartbeatStream
        ))
    }

    async fn report_task_result(
        &self,
        mut request: Request<pb::ReportTaskResultRequest>,
    ) -> Result<Response<pb::ReportTaskResultResponse>, Status> {
        let op = RpcOperation::start("ReportTaskResult", &mut request);
        let result = async {
            let r = request.into_inner();
            let node = self.authenticate_node(r.auth.as_ref())?;
            op.span.record("node_id", node.to_hex());
            let parsed = r
                .results
                .into_iter()
                .map(|r| {
                    TaskId::parse(&r.task_id)
                        .map(|id| (id, r))
                        .map_err(|_| Status::invalid_argument("Invalid task id"))
                })
                .collect::<Result<Vec<_>, _>>()?;
            for (id, r) in parsed {
                self.app.result(node, r, id).await?;
            }
            Ok(Response::new(pb::ReportTaskResultResponse {}))
        }
        .instrument(op.span.clone())
        .await;
        op.finish(&result);
        result
    }

    async fn report_task_output(
        &self,
        mut request: Request<pb::ReportTaskOutputRequest>,
    ) -> Result<Response<pb::ReportTaskOutputResponse>, Status> {
        let op = RpcOperation::start("ReportTaskOutput", &mut request);
        let result = async {
            let r = request.into_inner();
            let node = self.authenticate_node(r.auth.as_ref())?;
            op.span.record("node_id", node.to_hex());
            let parsed = r
                .events
                .into_iter()
                .map(|r| {
                    TaskId::parse(&r.task_id)
                        .map(|id| (id, r))
                        .map_err(|_| Status::invalid_argument("Invalid task id"))
                })
                .collect::<Result<Vec<_>, _>>()?;
            for (id, r) in parsed {
                self.app.output(node, r, id).await?;
            }
            Ok(Response::new(pb::ReportTaskOutputResponse {}))
        }
        .instrument(op.span.clone())
        .await;
        op.finish(&result);
        result
    }
}
