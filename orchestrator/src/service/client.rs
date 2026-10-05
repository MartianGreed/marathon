//! Client-facing RPC authentication, task ownership and account operations.

use super::{EventStream, Service};
use crate::{
    auth,
    events::{complete_event, state_event},
    store::User,
    telemetry::{RpcOperation, auth_failure, db_error},
};
use common::{
    ClientId, TaskId, UserId,
    client_auth::ClientCredential,
    pb,
    types::{Task, TaskState, now_ms},
};
use futures::{StreamExt, stream};
use std::collections::VecDeque;
use tonic::{Request, Response, Status};
use tracing::Instrument;

impl Service {
    /// Resolve sensitive client metadata to the credential owner.
    pub async fn authenticate<T>(&self, request: &Request<T>) -> Result<ClientId, Status> {
        let credential = ClientCredential::from_metadata(request.metadata())
            .map_err(|_| auth_failure("client"))?
            .ok_or_else(|| auth_failure("client"))?;
        match credential {
            ClientCredential::Bearer(token) => self
                .app
                .jwt
                .validate(&token)
                .ok_or_else(|| auth_failure("client")),
            ClientCredential::ApiKey(key) => self
                .app
                .store
                .user_by_api_key(&key)
                .await
                .map_err(|e| db_error("authenticate", &e))?
                .map(|u| ClientId(u.id.0))
                .ok_or_else(|| auth_failure("client")),
        }
    }

    /// Subscribe before snapshotting, then stream retained and optional live events.
    pub async fn event_stream(
        &self,
        id: TaskId,
        follow: bool,
        queued_first: bool,
    ) -> Result<EventStream, Status> {
        let s = self.app.state.lock().await;
        let Some(t) = s.tasks.get(&id) else {
            drop(s);
            let task = self
                .app
                .get_task(id)
                .await?
                .ok_or_else(|| Status::not_found("Task not found"))?;
            return Ok(Box::pin(stream::iter([Ok(state_event(&task, 0))])));
        };
        // Subscription and snapshot share the task mutation lock. A sequence fence
        // prevents snapshot events from being replayed through the broadcast.
        let receiver = t.events.sender.subscribe();
        let fence = t.events.sequence;
        let task = t.task.clone();
        let mut initial = VecDeque::new();
        if queued_first {
            let mut queued = task.clone();
            queued.state = TaskState::Queued;
            initial.push_back(Ok(state_event(&queued, 0)));
        }
        if !queued_first || task.state != TaskState::Queued {
            initial.push_back(Ok(state_event(&task, 0)));
        }
        initial.extend(t.events.outputs.iter().map(|e| Ok(e.event.clone())));
        if follow && task.state.is_terminal() {
            initial.push_back(Ok(complete_event(&task)));
        }
        let live = follow && !task.state.is_terminal();
        let shutdown = self.app.shutdown.subscribe();
        drop(s);
        let live = stream::unfold(
            (receiver, fence, !live, task, shutdown),
            |(mut rx, fence, done, task, mut shutdown)| async move {
                if done || *shutdown.borrow() {
                    return None;
                }
                loop {
                    let received = tokio::select! {
                        _ = shutdown.changed() => return None,
                        event = rx.recv() => event,
                    };
                    match received {
                        Ok(e) if e.sequence <= fence => continue,
                        Ok(e) => {
                            let done =
                                matches!(e.event.event, Some(pb::task_event::Event::Complete(_)));
                            return Some((Ok(e.event), (rx, e.sequence, done, task, shutdown)));
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                            let event = pb::TaskEvent {
                                task_id: task.id.to_hex(),
                                state: task.state.to_wire(),
                                timestamp: now_ms(),
                                event: Some(pb::task_event::Event::Error(pb::TaskError {
                                    code: "EVENTS_DROPPED".into(),
                                    message: "Subscriber fell behind; some events were dropped"
                                        .into(),
                                })),
                            };
                            return Some((Ok(event), (rx, fence, false, task, shutdown)));
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => return None,
                    }
                }
            },
        );
        Ok(Box::pin(stream::iter(initial).chain(live)))
    }

    fn auth_response(&self, user: &User, message: &str) -> Result<pb::AuthResponse, Status> {
        let token = self
            .app
            .jwt
            .create(user.id, &user.email)
            .map_err(|_| Status::internal("Token creation failed"))?;
        Ok(pb::AuthResponse {
            success: true,
            token: Some(token),
            api_key: Some(user.api_key.clone()),
            message: message.into(),
        })
    }
}

fn rejected(message: &str) -> pb::AuthResponse {
    pb::AuthResponse {
        success: false,
        token: None,
        api_key: None,
        message: message.into(),
    }
}

fn task_id(s: &str) -> Result<TaskId, Status> {
    TaskId::parse(s).map_err(|_| Status::invalid_argument("Invalid task id"))
}

#[tonic::async_trait]
impl pb::marathon_service_server::MarathonService for Service {
    type SubmitTaskStream = EventStream;

    type GetTaskEventsStream = EventStream;

    async fn submit_task(
        &self,
        mut request: Request<pb::SubmitTaskRequest>,
    ) -> Result<Response<EventStream>, Status> {
        let op = RpcOperation::start("SubmitTask", &mut request);
        let trace = op.trace.trace_id.clone();
        let result = async {
            let client = self.authenticate(&request).await?;
            let r = request.into_inner();
            if !auth::validate_repo_url(&r.repo_url) {
                return Err(Status::invalid_argument("Invalid repository URL format"));
            }
            if !auth::validate_github_token(&r.github_token) {
                return Err(Status::invalid_argument("Invalid GitHub token format"));
            }
            tracing::info!(
                operation="submit",
                client_id = %client,
                repo_url = ?common::redact::SafeUrl(&r.repo_url),
                "submission validated"
            );
            let mut task = Task::new(client, r.repo_url, r.branch, r.prompt);
            task.github_token = Some(r.github_token);
            task.create_pr = r.create_pr;
            task.pr_title = r.pr_title;
            task.pr_body = r.pr_body;
            task.env_vars = r.env_vars.into_iter().map(Into::into).collect();
            task.max_iterations = r.max_iterations;
            task.completion_promise = r.completion_promise;
            let id = self.app.submit(task, trace).await?;
            Ok(Response::new(self.event_stream(id, true, true).await?))
        }
        .instrument(op.span.clone())
        .await;
        op.finish(&result);
        result
    }

    async fn get_task(
        &self,
        mut request: Request<pb::GetTaskRequest>,
    ) -> Result<Response<pb::Task>, Status> {
        let op = RpcOperation::start("GetTask", &mut request);
        let result = async {
            let client = self.authenticate(&request).await?;
            let id = task_id(&request.get_ref().task_id)?;
            op.span.record("task_id", id.to_hex());
            Ok(Response::new(
                self.app.owned_task(id, client).await?.to_proto(),
            ))
        }
        .instrument(op.span.clone())
        .await;
        op.finish(&result);
        result
    }

    async fn cancel_task(
        &self,
        mut request: Request<pb::CancelTaskRequest>,
    ) -> Result<Response<pb::CancelTaskResponse>, Status> {
        let op = RpcOperation::start("CancelTask", &mut request);
        let result = async {
            let client = self.authenticate(&request).await?;
            let id = task_id(&request.get_ref().task_id)?;
            op.span.record("task_id", id.to_hex());
            let success = self.app.cancel(id, client).await?;
            Ok(Response::new(pb::CancelTaskResponse {
                success,
                message: if success {
                    "Task cancelled successfully"
                } else {
                    "Failed to cancel task"
                }
                .into(),
            }))
        }
        .instrument(op.span.clone())
        .await;
        op.finish(&result);
        result
    }

    async fn get_usage(
        &self,
        mut request: Request<pb::GetUsageRequest>,
    ) -> Result<Response<pb::UsageReport>, Status> {
        let op = RpcOperation::start("GetUsage", &mut request);
        let result = async {
            let client = self.authenticate(&request).await?;
            let r = request.into_inner();
            let (total, task_count) = self
                .app
                .store
                .usage_report(client, r.start_time, r.end_time)
                .await
                .map_err(|e| db_error("usage_report", &e))?;
            Ok(Response::new(pb::UsageReport {
                client_id: client.to_hex(),
                start_time: r.start_time,
                end_time: r.end_time,
                total: Some(total.into()),
                task_count,
            }))
        }
        .instrument(op.span.clone())
        .await;
        op.finish(&result);
        result
    }

    async fn list_tasks(
        &self,
        mut request: Request<pb::ListTasksRequest>,
    ) -> Result<Response<pb::ListTasksResponse>, Status> {
        let op = RpcOperation::start("ListTasks", &mut request);
        let result = async {
            let client = self.authenticate(&request).await?;
            let r = request.into_inner();
            let filter = r
                .state_filter
                .map(|s| {
                    pb::TaskState::try_from(s)
                        .map(TaskState::from)
                        .map_err(|_| Status::invalid_argument("Invalid state filter"))
                })
                .transpose()?;
            let (tasks, total_count) = self
                .app
                .store
                .list_tasks(client, filter, r.limit, r.offset)
                .await
                .map_err(|e| db_error("list_tasks", &e))?;
            Ok(Response::new(pb::ListTasksResponse {
                tasks: tasks
                    .into_iter()
                    .map(|t| pb::TaskSummary {
                        task_id: t.id.to_hex(),
                        state: t.state.to_wire(),
                        repo_url: t.repo_url,
                        created_at: t.created_at,
                        completed_at: t.completed_at,
                    })
                    .collect(),
                total_count,
            }))
        }
        .instrument(op.span.clone())
        .await;
        op.finish(&result);
        result
    }

    async fn get_task_events(
        &self,
        mut request: Request<pb::GetTaskEventsRequest>,
    ) -> Result<Response<EventStream>, Status> {
        let op = RpcOperation::start("GetTaskEvents", &mut request);
        let result = async {
            let client = self.authenticate(&request).await?;
            let r = request.into_inner();
            let id = task_id(&r.task_id)?;
            self.app.owned_task(id, client).await?;
            Ok(Response::new(self.event_stream(id, r.follow, false).await?))
        }
        .instrument(op.span.clone())
        .await;
        op.finish(&result);
        result
    }

    async fn register(
        &self,
        mut request: Request<pb::RegisterRequest>,
    ) -> Result<Response<pb::AuthResponse>, Status> {
        let op = RpcOperation::start("Register", &mut request);
        let result = async {
            let r = request.into_inner();
            if r.email.is_empty() || r.password.is_empty() {
                return Ok(Response::new(rejected("Email and password are required")));
            }
            let password_hash =
                tokio::task::spawn_blocking(move || auth::hash_password(&r.password))
                    .await
                    .map_err(|_| Status::internal("Password hashing failed"))?;
            let now = now_ms();
            let user = User {
                id: UserId::random(),
                email: r.email,
                password_hash,
                api_key: auth::generate_api_key(),
                github_id: None,
                created_at: now,
                updated_at: now,
            };
            match self.app.store.create_user(&user).await {
                Ok(()) => Ok(Response::new(
                    self.auth_response(&user, "Registration successful")?,
                )),
                Err(crate::db::DbError::EmailTaken) => {
                    Ok(Response::new(rejected("Email already registered")))
                }
                Err(e) => {
                    db_error("create_user", &e);
                    Ok(Response::new(rejected("Failed to create user")))
                }
            }
        }
        .instrument(op.span.clone())
        .await;
        op.finish(&result);
        result
    }

    async fn login(
        &self,
        mut request: Request<pb::LoginRequest>,
    ) -> Result<Response<pb::AuthResponse>, Status> {
        let op = RpcOperation::start("Login", &mut request);
        let result = async {
            let r = request.into_inner();
            let user = self
                .app
                .store
                .user_by_email(&r.email)
                .await
                .map_err(|e| db_error("user_by_email", &e))?;
            let hash = user
                .as_ref()
                .map(|u| u.password_hash.clone())
                .unwrap_or_else(|| self.app.dummy_password_hash.clone());
            let valid =
                tokio::task::spawn_blocking(move || auth::verify_password(&r.password, &hash))
                    .await
                    .map_err(|_| Status::internal("Password verification failed"))?;
            match user.filter(|_| valid) {
                Some(u) => Ok(Response::new(self.auth_response(&u, "Login successful")?)),
                None => Ok(Response::new(rejected("Invalid email or password"))),
            }
        }
        .instrument(op.span.clone())
        .await;
        op.finish(&result);
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        scheduler::Orchestrator,
        store::{MemoryStore, Store},
    };
    use std::sync::Arc;

    async fn identity() -> (Service, User, User) {
        let store = Arc::new(MemoryStore::default());
        let user = |email: &str| User {
            id: UserId::random(),
            email: email.into(),
            password_hash: "unused".into(),
            api_key: auth::generate_api_key(),
            github_id: None,
            created_at: 0,
            updated_at: 0,
        };
        let a = user("a");
        let b = user("b");
        store.create_user(&a).await.unwrap();
        store.create_user(&b).await.unwrap();
        (
            Service {
                app: Orchestrator::new(
                    common::config::OrchestratorConfig {
                        jwt_secret: Some("identity-test".into()),
                        ..Default::default()
                    },
                    store,
                ),
            },
            a,
            b,
        )
    }

    async fn key(s: &Service, u: &User) -> ClientId {
        let mut r = Request::new(());
        ClientCredential::ApiKey(u.api_key.clone())
            .apply(r.metadata_mut())
            .unwrap();
        s.authenticate(&r).await.unwrap()
    }

    async fn jwt(s: &Service, u: &User) -> ClientId {
        let mut r = Request::new(());
        ClientCredential::Bearer(s.app.jwt.create(u.id, &u.email).unwrap())
            .apply(r.metadata_mut())
            .unwrap();
        s.authenticate(&r).await.unwrap()
    }

    // Port of grpc/server.zig "request handler"
    #[tokio::test]
    async fn request_handler() {
        let (s, a, _) = identity().await;
        assert_eq!(key(&s, &a).await, ClientId(a.id.0));
        assert_eq!(
            s.authenticate(&Request::new(())).await.unwrap_err().code(),
            tonic::Code::Unauthenticated
        );
    }

    // Port of auth/auth.zig "authenticator register and authenticate"
    #[tokio::test]
    async fn register_authenticate() {
        let (s, a, _) = identity().await;
        assert_eq!(key(&s, &a).await, ClientId(a.id.0));
        let mut r = Request::new(());
        ClientCredential::ApiKey("wrong".into())
            .apply(r.metadata_mut())
            .unwrap();
        assert!(s.authenticate(&r).await.is_err());
    }

    // Port of grpc/server.zig "generateClientId determinism - same IPv4 produces same result"
    // IP-derived identity is replaced by API key-derived identity.
    #[tokio::test]
    async fn same_key_identity() {
        let (s, a, _) = identity().await;
        assert_eq!(key(&s, &a).await, key(&s, &a).await);
    }

    // Port of grpc/server.zig
    // "generateClientId uniqueness - different IPv4 produces different results"
    // Different accounts replace different source IPs.
    #[tokio::test]
    async fn different_key_identities() {
        let (s, a, b) = identity().await;
        assert_ne!(key(&s, &a).await, key(&s, &b).await);
    }

    // Port of grpc/server.zig "generateClientId determinism - same IPv6 produces same result"
    // JWT identity replaces IPv6-derived identity.
    #[tokio::test]
    async fn same_jwt_identity() {
        let (s, a, _) = identity().await;
        assert_eq!(jwt(&s, &a).await, jwt(&s, &a).await);
    }

    // Port of grpc/server.zig
    // "generateClientId uniqueness - different IPv6 produces different results"
    // Different JWT accounts replace different IPv6 addresses.
    #[tokio::test]
    async fn different_jwt_identities() {
        let (s, a, b) = identity().await;
        assert_ne!(jwt(&s, &a).await, jwt(&s, &b).await);
    }

    // Port of grpc/server.zig "generateClientId - IPv4 and IPv6 produce different results"
    // Accounts differ regardless of credential transport.
    #[tokio::test]
    async fn different_credential_users() {
        let (s, a, b) = identity().await;
        assert_ne!(jwt(&s, &a).await, key(&s, &b).await);
    }

    // Port of grpc/server.zig "generateClientId - returns valid 16-byte ClientId"
    // Credential-derived client ids have the same nonzero 16-byte representation.
    #[tokio::test]
    async fn valid_client_id() {
        let (s, a, _) = identity().await;
        let id = key(&s, &a).await;
        assert_eq!(id.as_bytes().len(), 16);
        assert_ne!(id, ClientId([0; 16]));
    }

    // Port of grpc/server.zig "generateClientId - consistent across multiple calls"
    // API key and JWT resolve to the same identity on repeated calls.
    #[tokio::test]
    async fn consistent_identity() {
        let (s, a, _) = identity().await;
        for _ in 0..10 {
            assert_eq!(key(&s, &a).await, jwt(&s, &a).await);
        }
    }
}
