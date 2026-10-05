//! Runs the `marathon` CLI in-process against a fake `MarathonService` on an
//! ephemeral loopback port, with a temporary HOME.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::Path;
use std::pin::Pin;
use std::sync::{Arc, Mutex};

use common::config::ClientConfig;
use common::pb::marathon_service_server::{MarathonService, MarathonServiceServer};
use common::pb::{self, task_event::Event};
use common::{TaskId, TaskState};
use marathon_client::{Context, run};
use tokio_stream::Stream;
use tokio_stream::wrappers::TcpListenerStream;
use tonic::transport::{Identity, Server, ServerTlsConfig};
use tonic::{Request, Response, Status};

type EventStream = Pin<Box<dyn Stream<Item = Result<pb::TaskEvent, Status>> + Send>>;

const GITHUB_TOKEN: &str = "ghp_test_token";

#[derive(Clone)]
struct Account {
    password: String,
    token: String,
    api_key: String,
}

/// Metadata of one received call.
#[derive(Debug, Clone)]
struct Call {
    rpc: &'static str,
    api_key: Option<String>,
    authorization: Option<String>,
    traceparent: Option<String>,
}

#[derive(Default)]
struct State {
    accounts: HashMap<String, Account>,
    tasks: HashMap<String, pb::Task>,
    submits: Vec<pb::SubmitTaskRequest>,
    calls: Vec<Call>,
    /// When set, the submit stream ends after the first event.
    drop_after_first_event: bool,
}

#[derive(Clone, Default)]
struct Fake {
    state: Arc<Mutex<State>>,
}

fn header(req: &Request<impl Sized>, key: &str) -> Option<String> {
    req.metadata()
        .get(key)
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned)
}

impl Fake {
    fn record(&self, rpc: &'static str, req: &Request<impl Sized>) {
        self.state.lock().unwrap().calls.push(Call {
            rpc,
            api_key: header(req, "x-api-key"),
            authorization: header(req, "authorization"),
            traceparent: header(req, "traceparent"),
        });
    }

    /// The caller's email, from `x-api-key` or `authorization: Bearer`.
    fn authenticate(&self, req: &Request<impl Sized>) -> Result<String, Status> {
        let state = self.state.lock().unwrap();
        let bearer =
            header(req, "authorization").and_then(|v| v.strip_prefix("Bearer ").map(str::to_owned));
        let key = header(req, "x-api-key");
        state
            .accounts
            .iter()
            .find(|(_, a)| {
                bearer.as_deref() == Some(a.token.as_str())
                    || key.as_deref() == Some(a.api_key.as_str())
            })
            .map(|(email, _)| email.clone())
            .ok_or_else(|| Status::unauthenticated("invalid or missing credentials"))
    }

    fn calls(&self) -> Vec<Call> {
        self.state.lock().unwrap().calls.clone()
    }
}

fn event(task_id: &str, state: TaskState, event: Event) -> Result<pb::TaskEvent, Status> {
    Ok(pb::TaskEvent {
        task_id: task_id.to_owned(),
        state: state.to_wire(),
        timestamp: 1,
        event: Some(event),
    })
}

fn change(task_id: &str, from: TaskState, to: TaskState) -> Result<pb::TaskEvent, Status> {
    event(
        task_id,
        to,
        Event::StateChange(pb::TaskStateChange {
            previous_state: from.to_wire(),
        }),
    )
}

fn output(task_id: &str, data: &str) -> Result<pb::TaskEvent, Status> {
    event(
        task_id,
        TaskState::Running,
        Event::Output(pb::TaskOutput {
            r#type: common::OutputType::Stdout.to_wire(),
            data: data.as_bytes().to_vec(),
        }),
    )
}

/// The events of a task run: completed with a PR, or failed when the prompt
/// contains "fail".
fn run_events(task_id: &str, prompt: &str) -> Vec<Result<pb::TaskEvent, Status>> {
    let fail = prompt.contains("fail");
    let end = if fail {
        TaskState::Failed
    } else {
        TaskState::Completed
    };
    let mut events = vec![
        change(task_id, TaskState::Queued, TaskState::Starting),
        change(task_id, TaskState::Starting, TaskState::Running),
        output(task_id, "agent: cloning repository\n"),
        output(task_id, "agent: tests pass\n"),
    ];
    if fail {
        events.push(event(
            task_id,
            TaskState::Running,
            Event::Error(pb::TaskError {
                code: "agent_exit".into(),
                message: "exit status 1".into(),
            }),
        ));
    }
    events.extend([
        change(task_id, TaskState::Running, end),
        event(
            task_id,
            end,
            Event::Complete(pb::TaskComplete {
                usage: Some(pb::UsageMetrics::default()),
                pr_url: (!fail).then(|| "https://github.com/user/repo/pull/7".to_owned()),
                error_message: fail.then(|| "agent exited with status 1".to_owned()),
            }),
        ),
    ]);
    events
}

#[tonic::async_trait]
impl MarathonService for Fake {
    type SubmitTaskStream = EventStream;
    type GetTaskEventsStream = EventStream;

    async fn submit_task(
        &self,
        req: Request<pb::SubmitTaskRequest>,
    ) -> Result<Response<EventStream>, Status> {
        self.record("SubmitTask", &req);
        let email = self.authenticate(&req)?;
        let req = req.into_inner();
        let id = TaskId::random().to_hex();
        let mut state = self.state.lock().unwrap();
        state.tasks.insert(
            id.clone(),
            pb::Task {
                id: id.clone(),
                client_id: email,
                state: TaskState::Completed.to_wire(),
                repo_url: req.repo_url.clone(),
                branch: req.branch.clone(),
                prompt: req.prompt.clone(),
                created_at: 1_700_000_000_000,
                started_at: Some(1_700_000_001_000),
                completed_at: Some(1_700_000_002_000),
                pr_url: Some("https://github.com/user/repo/pull/7".into()),
                ..Default::default()
            },
        );
        let mut events = vec![change(&id, TaskState::Unspecified, TaskState::Queued)];
        if !state.drop_after_first_event {
            events.extend(run_events(&id, &req.prompt));
        }
        state.submits.push(req);
        Ok(Response::new(Box::pin(tokio_stream::iter(events))))
    }

    async fn get_task(
        &self,
        req: Request<pb::GetTaskRequest>,
    ) -> Result<Response<pb::Task>, Status> {
        self.record("GetTask", &req);
        self.authenticate(&req)?;
        let id = req.into_inner().task_id;
        self.state
            .lock()
            .unwrap()
            .tasks
            .get(&id)
            .cloned()
            .map(Response::new)
            .ok_or_else(|| Status::not_found("task not found"))
    }

    async fn cancel_task(
        &self,
        req: Request<pb::CancelTaskRequest>,
    ) -> Result<Response<pb::CancelTaskResponse>, Status> {
        self.record("CancelTask", &req);
        self.authenticate(&req)?;
        let id = req.into_inner().task_id;
        let mut state = self.state.lock().unwrap();
        let task = state
            .tasks
            .get_mut(&id)
            .ok_or_else(|| Status::not_found("task not found"))?;
        if TaskState::from_wire(task.state).is_terminal() {
            return Ok(Response::new(pb::CancelTaskResponse {
                success: false,
                message: "task already finished".into(),
            }));
        }
        task.state = TaskState::Cancelled.to_wire();
        Ok(Response::new(pb::CancelTaskResponse {
            success: true,
            message: String::new(),
        }))
    }

    async fn get_usage(
        &self,
        req: Request<pb::GetUsageRequest>,
    ) -> Result<Response<pb::UsageReport>, Status> {
        self.record("GetUsage", &req);
        self.authenticate(&req)?;
        let r = req.into_inner();
        assert_eq!(r.start_time, 0);
        assert!(r.end_time > 1_700_000_000_000);
        Ok(Response::new(pb::UsageReport {
            client_id: "c".into(),
            start_time: r.start_time,
            end_time: r.end_time,
            total: Some(pb::UsageMetrics {
                compute_time_ms: 120_000,
                input_tokens: 1500,
                output_tokens: 700,
                cache_read_tokens: 300,
                cache_write_tokens: 40,
                tool_calls: 12,
            }),
            task_count: 3,
        }))
    }

    async fn list_tasks(
        &self,
        _req: Request<pb::ListTasksRequest>,
    ) -> Result<Response<pb::ListTasksResponse>, Status> {
        Err(Status::unimplemented("not used by the CLI"))
    }

    async fn get_task_events(
        &self,
        req: Request<pb::GetTaskEventsRequest>,
    ) -> Result<Response<EventStream>, Status> {
        self.record("GetTaskEvents", &req);
        self.authenticate(&req)?;
        let r = req.into_inner();
        assert!(r.follow, "the CLI follows");
        let state = self.state.lock().unwrap();
        let task = state
            .tasks
            .get(&r.task_id)
            .ok_or_else(|| Status::not_found("task not found"))?;
        let mut events = vec![event(
            &r.task_id,
            TaskState::Running,
            Event::StateChange(pb::TaskStateChange {
                previous_state: TaskState::Starting.to_wire(),
            }),
        )];
        events.extend(run_events(&r.task_id, &task.prompt).into_iter().skip(2));
        Ok(Response::new(Box::pin(tokio_stream::iter(events))))
    }

    async fn register(
        &self,
        req: Request<pb::RegisterRequest>,
    ) -> Result<Response<pb::AuthResponse>, Status> {
        self.record("Register", &req);
        let r = req.into_inner();
        let mut state = self.state.lock().unwrap();
        if state.accounts.contains_key(&r.email) {
            return Ok(Response::new(pb::AuthResponse {
                success: false,
                token: None,
                api_key: None,
                message: "email already registered".into(),
            }));
        }
        let n = state.accounts.len() + 1;
        let account = Account {
            password: r.password,
            token: format!("eyJhbGciOiJIUzI1NiJ9.user{n}.sig"),
            api_key: format!("mk_{}", TaskId::random().to_hex()),
        };
        state.accounts.insert(r.email, account.clone());
        Ok(Response::new(pb::AuthResponse {
            success: true,
            token: Some(account.token),
            api_key: Some(account.api_key),
            message: String::new(),
        }))
    }

    async fn login(
        &self,
        req: Request<pb::LoginRequest>,
    ) -> Result<Response<pb::AuthResponse>, Status> {
        self.record("Login", &req);
        let r = req.into_inner();
        let state = self.state.lock().unwrap();
        match state.accounts.get(&r.email) {
            Some(a) if a.password == r.password => Ok(Response::new(pb::AuthResponse {
                success: true,
                token: Some(a.token.clone()),
                api_key: Some(a.api_key.clone()),
                message: String::new(),
            })),
            _ => Ok(Response::new(pb::AuthResponse {
                success: false,
                token: None,
                api_key: None,
                message: "invalid email or password".into(),
            })),
        }
    }
}

/// Serve the fake on an ephemeral loopback port.
async fn serve(fake: Fake, tls: Option<Identity>) -> SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let mut builder = Server::builder();
    if let Some(identity) = tls {
        builder = builder
            .tls_config(ServerTlsConfig::new().identity(identity))
            .unwrap();
    }
    let router = builder.add_service(MarathonServiceServer::new(fake));
    tokio::spawn(router.serve_with_incoming(TcpListenerStream::new(listener)));
    addr
}

fn config(addr: SocketAddr) -> ClientConfig {
    ClientConfig {
        orchestrator_address: addr.ip().to_string(),
        orchestrator_port: addr.port(),
        github_token: Some(GITHUB_TOKEN.into()),
        tls_enabled: false,
        tls_ca_path: None,
    }
}

struct Outcome {
    code: u8,
    out: String,
    err: String,
}

impl std::fmt::Debug for Outcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "exit {}\n--- stdout\n{}--- stderr\n{}",
            self.code, self.out, self.err
        )
    }
}

async fn cli_with(
    config: ClientConfig,
    home: &Path,
    args: &[&str],
    password: Option<&str>,
) -> Outcome {
    let args: Vec<String> = std::iter::once("marathon")
        .chain(args.iter().copied())
        .map(str::to_owned)
        .collect();
    let mut out = Vec::new();
    let mut err = Vec::new();
    let password = password.map(str::to_owned);
    let mut prompt = move |_: &str| {
        password
            .clone()
            .ok_or_else(|| std::io::Error::other("no password prompt in this test"))
    };
    let mut ctx = Context {
        config: Ok(config),
        home: Some(home.to_owned()),
        out: &mut out,
        err: &mut err,
        password: &mut prompt,
    };
    let code = run(&args, &mut ctx).await;
    Outcome {
        code,
        out: String::from_utf8(out).unwrap(),
        err: String::from_utf8(err).unwrap(),
    }
}

async fn cli(addr: SocketAddr, home: &Path, args: &[&str]) -> Outcome {
    cli_with(config(addr), home, args, None).await
}

fn creds_path(home: &Path) -> std::path::PathBuf {
    home.join(".marathon").join("credentials")
}

#[cfg(unix)]
fn mode(path: &Path) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

#[tokio::test]
async fn register_login_whoami_logout() {
    let fake = Fake::default();
    let addr = serve(fake.clone(), None).await;
    let home = tempfile::tempdir().unwrap();
    let home = home.path();
    let path = creds_path(home);

    let r = cli(
        addr,
        home,
        &[
            "register",
            "--email",
            "dev@example.com",
            "--password",
            "pw1",
        ],
    )
    .await;
    assert_eq!(r.code, 0, "{r:?}");
    assert!(
        r.err
            .contains(&format!("Connecting to 127.0.0.1:{}...", addr.port())),
        "{r:?}"
    );
    assert!(r.out.contains("✓ Registration successful!"), "{r:?}");
    assert!(
        r.out
            .contains(&format!("Credentials saved to {}", path.display())),
        "{r:?}"
    );
    let account = fake.state.lock().unwrap().accounts["dev@example.com"].clone();
    assert!(
        r.out.contains(&format!("API Key: {}", account.api_key)),
        "{r:?}"
    );
    assert_eq!(
        std::fs::read_to_string(&path).unwrap(),
        format!(
            "token={}\napi_key={}\nemail=dev@example.com\n",
            account.token, account.api_key
        )
    );
    #[cfg(unix)]
    assert_eq!(mode(&path), 0o600);

    let r = cli(addr, home, &["whoami"]).await;
    assert_eq!(r.code, 0, "{r:?}");
    assert_eq!(
        r.out,
        format!(
            "Logged in as: dev@example.com\nAPI Key:      {}...{}\n",
            &account.api_key[..8],
            &account.api_key[account.api_key.len() - 4..]
        )
    );

    let r = cli(addr, home, &["logout"]).await;
    assert_eq!(r.code, 0, "{r:?}");
    assert_eq!(r.out, "✓ Logged out. Credentials removed.\n");
    assert!(!path.exists());

    let r = cli(addr, home, &["whoami"]).await;
    assert_eq!(r.code, 1, "{r:?}");
    assert!(r.err.contains("Not logged in."), "{r:?}");

    let r = cli(
        addr,
        home,
        &["login", "--email", "dev@example.com", "--password", "pw1"],
    )
    .await;
    assert_eq!(r.code, 0, "{r:?}");
    assert!(r.out.contains("✓ Login successful!"), "{r:?}");
    assert!(
        !r.out.contains("API Key:"),
        "login does not print the key: {r:?}"
    );
    assert!(
        std::fs::read_to_string(&path)
            .unwrap()
            .contains(&account.api_key)
    );
    #[cfg(unix)]
    assert_eq!(mode(&path), 0o600);

    let r = cli(addr, home, &["whoami"]).await;
    assert_eq!(r.code, 0, "{r:?}");
    assert!(
        r.out.starts_with("Logged in as: dev@example.com\n"),
        "{r:?}"
    );

    // Register and Login carry no credential; both carry trace context.
    for call in fake.calls() {
        assert!(
            call.api_key.is_none() && call.authorization.is_none(),
            "{call:?}"
        );
        assert!(call.traceparent.is_some(), "{call:?}");
    }
}

#[tokio::test]
async fn auth_failures_keep_existing_credentials() {
    let fake = Fake::default();
    let addr = serve(fake.clone(), None).await;
    let home = tempfile::tempdir().unwrap();
    let home = home.path();

    let r = cli(
        addr,
        home,
        &["register", "--email", "a@x", "--password", "p"],
    )
    .await;
    assert_eq!(r.code, 0, "{r:?}");
    let saved = std::fs::read_to_string(creds_path(home)).unwrap();

    let r = cli(
        addr,
        home,
        &["register", "--email", "a@x", "--password", "p"],
    )
    .await;
    assert_eq!(r.code, 1, "{r:?}");
    assert!(
        r.err
            .contains("Registration failed: email already registered"),
        "{r:?}"
    );

    let r = cli(
        addr,
        home,
        &["login", "--email", "a@x", "--password", "wrong"],
    )
    .await;
    assert_eq!(r.code, 1, "{r:?}");
    assert!(
        r.err.contains("Login failed: invalid email or password"),
        "{r:?}"
    );

    assert_eq!(std::fs::read_to_string(creds_path(home)).unwrap(), saved);

    // Argument errors, before contacting the server.
    let before = fake.calls().len();
    let r = cli(addr, home, &["login", "--password", "p"]).await;
    assert_eq!(r.code, 1, "{r:?}");
    assert!(r.err.contains("Error: --email is required"), "{r:?}");
    let r = cli(addr, home, &["login", "--email"]).await;
    assert_eq!(r.code, 2, "{r:?}");
    assert_eq!(fake.calls().len(), before);
}

#[tokio::test]
async fn missing_password_is_prompted() {
    let fake = Fake::default();
    let addr = serve(fake.clone(), None).await;
    let home = tempfile::tempdir().unwrap();
    let home = home.path();

    let r = cli_with(
        config(addr),
        home,
        &["register", "--email", "p@x"],
        Some("secret"),
    )
    .await;
    assert_eq!(r.code, 0, "{r:?}");
    assert_eq!(
        fake.state.lock().unwrap().accounts["p@x"].password,
        "secret"
    );

    // An empty answer is refused without contacting the server.
    let before = fake.calls().len();
    let r = cli_with(config(addr), home, &["login", "--email", "p@x"], Some("")).await;
    assert_eq!(r.code, 1, "{r:?}");
    assert!(r.err.contains("Error: --password is required"), "{r:?}");
    let r = cli_with(config(addr), home, &["login", "--email", "p@x"], None).await;
    assert_eq!(r.code, 1, "{r:?}");
    assert!(r.err.contains("cannot read password"), "{r:?}");
    assert_eq!(fake.calls().len(), before);
}

async fn registered(fake: &Fake, home: &Path) -> (SocketAddr, Account) {
    let addr = serve(fake.clone(), None).await;
    let r = cli(
        addr,
        home,
        &["register", "--email", "dev@example.com", "--password", "pw"],
    )
    .await;
    assert_eq!(r.code, 0, "{r:?}");
    let account = fake.state.lock().unwrap().accounts["dev@example.com"].clone();
    (addr, account)
}

#[tokio::test]
async fn submit_follow_streams_output() {
    let fake = Fake::default();
    let home = tempfile::tempdir().unwrap();
    let home = home.path();
    let (addr, account) = registered(&fake, home).await;

    let r = cli(
        addr,
        home,
        &[
            "submit",
            "--repo",
            "https://github.com/user/repo",
            "--prompt",
            "Fix the bug",
            "--branch",
            "dev",
            "--pr",
            "--pr-title",
            "Fix",
            "-e",
            "DATABASE_URL=postgres://db",
            "-e",
            "API_KEY=sk=1",
            "--max-iterations",
            "10",
            "--completion-promise",
            "TASK_COMPLETE",
            "--follow",
        ],
    )
    .await;
    assert_eq!(r.code, 0, "{r:?}");
    let task_id = fake
        .state
        .lock()
        .unwrap()
        .tasks
        .keys()
        .next()
        .unwrap()
        .clone();
    assert_eq!(
        r.out,
        format!(
            "⏳ Task submitted: {task_id}\n\
             📋 State: queued\n\
             🖥️  State: starting\n\
             🔥 State: running\n\
             📋 agent: cloning repository\n\
             📋 agent: tests pass\n\
             ✅ State: completed\n   \
             PR: https://github.com/user/repo/pull/7\n"
        )
    );
    assert!(
        r.err.contains("[client] Connected, TLS enabled: false"),
        "{r:?}"
    );
    assert!(r.err.contains("Submitting task..."), "{r:?}");

    let submit = fake.state.lock().unwrap().submits[0].clone();
    assert_eq!(submit.repo_url, "https://github.com/user/repo");
    assert_eq!(submit.branch, "dev");
    assert_eq!(submit.prompt, "Fix the bug");
    assert_eq!(submit.github_token, GITHUB_TOKEN);
    assert!(submit.create_pr);
    assert_eq!(submit.pr_title.as_deref(), Some("Fix"));
    assert_eq!(submit.pr_body, None);
    let env: Vec<(&str, &str)> = submit
        .env_vars
        .iter()
        .map(|e| (e.key.as_str(), e.value.as_str()))
        .collect();
    assert_eq!(
        env,
        [("DATABASE_URL", "postgres://db"), ("API_KEY", "sk=1")]
    );
    assert_eq!(submit.max_iterations, Some(10));
    assert_eq!(submit.completion_promise.as_deref(), Some("TASK_COMPLETE"));

    // Authenticated with the stored API key, and trace context attached.
    let call = fake
        .calls()
        .into_iter()
        .find(|c| c.rpc == "SubmitTask")
        .unwrap();
    assert_eq!(call.api_key.as_deref(), Some(account.api_key.as_str()));
    assert_eq!(call.authorization, None);
    let tp = call.traceparent.unwrap();
    assert!(
        tp.starts_with("00-") && tp.ends_with("-01") && tp.len() == 55,
        "{tp}"
    );
}

#[tokio::test]
async fn submit_without_follow_prints_task_id() {
    let fake = Fake::default();
    let home = tempfile::tempdir().unwrap();
    let home = home.path();
    let (addr, _) = registered(&fake, home).await;

    let r = cli(
        addr,
        home,
        &[
            "submit",
            "--repo",
            "https://github.com/u/r",
            "--prompt",
            "p",
        ],
    )
    .await;
    assert_eq!(r.code, 0, "{r:?}");
    let task_id = fake
        .state
        .lock()
        .unwrap()
        .tasks
        .keys()
        .next()
        .unwrap()
        .clone();
    assert_eq!(r.out, format!("{task_id}\n"));
    let submit = fake.state.lock().unwrap().submits[0].clone();
    assert_eq!(submit.branch, "main");
    assert!(!submit.create_pr);
    assert!(submit.env_vars.is_empty());
    assert_eq!(submit.max_iterations, None);
    assert_eq!(submit.completion_promise, None);
}

#[tokio::test]
async fn submit_follow_failed_task_exits_nonzero() {
    let fake = Fake::default();
    let home = tempfile::tempdir().unwrap();
    let home = home.path();
    let (addr, _) = registered(&fake, home).await;

    let r = cli(
        addr,
        home,
        &[
            "submit",
            "--repo",
            "https://github.com/u/r",
            "--prompt",
            "please fail",
            "-f",
        ],
    )
    .await;
    assert_eq!(r.code, 1, "{r:?}");
    assert!(r.out.ends_with("❌ State: failed\n"), "{r:?}");
    assert!(!r.out.contains("Error"), "errors go to stderr: {r:?}");
    assert!(!r.out.contains("PR:"), "{r:?}");
    assert!(
        r.err.ends_with(
            "   Error: agent_exit — exit status 1\n   Error: agent exited with status 1\n"
        ),
        "{r:?}"
    );
}

#[tokio::test]
async fn submit_follow_reports_dropped_stream() {
    let fake = Fake::default();
    let home = tempfile::tempdir().unwrap();
    let home = home.path();
    let (addr, _) = registered(&fake, home).await;
    fake.state.lock().unwrap().drop_after_first_event = true;

    let r = cli(
        addr,
        home,
        &[
            "submit",
            "--repo",
            "https://github.com/u/r",
            "--prompt",
            "p",
            "-f",
        ],
    )
    .await;
    assert_eq!(r.code, 1, "{r:?}");
    let task_id = fake
        .state
        .lock()
        .unwrap()
        .tasks
        .keys()
        .next()
        .unwrap()
        .clone();
    assert!(r.err.contains("Connection lost"), "{r:?}");
    assert!(
        r.err
            .contains(&format!("marathon status {task_id} --follow")),
        "{r:?}"
    );
}

#[tokio::test]
async fn submit_argument_errors() {
    let fake = Fake::default();
    let home = tempfile::tempdir().unwrap();
    let home = home.path();
    let (addr, _) = registered(&fake, home).await;
    let before = fake.calls().len();

    let r = cli(addr, home, &["submit", "--prompt", "p"]).await;
    assert_eq!((r.code, r.err.as_str()), (1, "Error: --repo is required\n"));
    let r = cli(addr, home, &["submit", "--repo", "r"]).await;
    assert_eq!(
        (r.code, r.err.as_str()),
        (1, "Error: --prompt is required\n")
    );
    let mut no_token = config(addr);
    no_token.github_token = None;
    let r = cli_with(
        no_token,
        home,
        &["submit", "--repo", "r", "--prompt", "p"],
        None,
    )
    .await;
    assert_eq!(
        (r.code, r.err.as_str()),
        (1, "Error: GITHUB_TOKEN environment variable is required\n")
    );
    let r = cli(
        addr,
        home,
        &["submit", "--repo", "r", "--prompt", "p", "-e", "NOEQ"],
    )
    .await;
    assert_eq!(r.code, 2, "{r:?}");
    assert!(
        r.err.contains("-e requires KEY=VALUE format, got: NOEQ"),
        "{r:?}"
    );
    let r = cli(
        addr,
        home,
        &[
            "submit",
            "--repo",
            "r",
            "--prompt",
            "p",
            "--max-iterations",
            "x",
        ],
    )
    .await;
    assert_eq!(r.code, 2, "{r:?}");
    assert_eq!(fake.calls().len(), before);
}

#[tokio::test]
async fn status_cancel_usage() {
    let fake = Fake::default();
    let home = tempfile::tempdir().unwrap();
    let home = home.path();
    let (addr, account) = registered(&fake, home).await;
    let r = cli(
        addr,
        home,
        &[
            "submit",
            "--repo",
            "https://github.com/u/r",
            "--prompt",
            "p",
        ],
    )
    .await;
    let task_id = r.out.trim().to_owned();

    // Status of a finished task; ids are accepted in either case.
    let r = cli(addr, home, &["status", &task_id.to_uppercase()]).await;
    assert_eq!(r.code, 0, "{r:?}");
    assert_eq!(
        r.out,
        format!(
            "Task:      {task_id}\n\
             State:     completed\n\
             Repo:      https://github.com/u/r\n\
             Branch:    main\n\
             Created:   1700000000000\n\
             Started:   1700000001000\n\
             Completed: 1700000002000\n\
             PR:        https://github.com/user/repo/pull/7\n"
        )
    );

    // Follow an existing task.
    let r = cli(addr, home, &["status", &task_id, "--follow"]).await;
    assert_eq!(r.code, 0, "{r:?}");
    assert_eq!(
        r.out,
        "🔥 State: running\n\
         📋 agent: cloning repository\n\
         📋 agent: tests pass\n\
         ✅ State: completed\n   \
         PR: https://github.com/user/repo/pull/7\n"
    );

    // Cancel: refused for a finished task, accepted for a running one.
    let r = cli(addr, home, &["cancel", &task_id]).await;
    assert_eq!(r.code, 1, "{r:?}");
    assert_eq!(r.err, "Cancel failed: task already finished\n");
    fake.state
        .lock()
        .unwrap()
        .tasks
        .get_mut(&task_id)
        .unwrap()
        .state = TaskState::Running.to_wire();
    let r = cli(addr, home, &["cancel", &task_id]).await;
    assert_eq!(r.code, 0, "{r:?}");
    assert_eq!(r.out, "Task cancelled.\n");
    assert_eq!(
        fake.state.lock().unwrap().tasks[&task_id].state,
        TaskState::Cancelled.to_wire()
    );

    let r = cli(addr, home, &["usage"]).await;
    assert_eq!(r.code, 0, "{r:?}");
    assert_eq!(
        r.out,
        "Usage Report\n\
         ============\n\
         Tasks:              3\n\
         Compute time:       120000 ms\n\
         Input tokens:       1500\n\
         Output tokens:      700\n\
         Cache read tokens:  300\n\
         Cache write tokens: 40\n\
         Tool calls:         12\n"
    );

    // Unknown task.
    let r = cli(addr, home, &["status", &"0".repeat(64)]).await;
    assert_eq!(r.code, 1, "{r:?}");
    assert!(
        r.err
            .contains("Error: Failed to get task status: task not found (NotFound)"),
        "{r:?}"
    );

    // Every authenticated call carried the API key and a traceparent.
    for call in fake.calls() {
        if matches!(call.rpc, "Register" | "Login") {
            continue;
        }
        assert_eq!(
            call.api_key.as_deref(),
            Some(account.api_key.as_str()),
            "{call:?}"
        );
        assert!(call.traceparent.is_some(), "{call:?}");
    }
}

#[tokio::test]
async fn task_id_validation() {
    let fake = Fake::default();
    let home = tempfile::tempdir().unwrap();
    let home = home.path();
    let (addr, _) = registered(&fake, home).await;
    let before = fake.calls().len();
    for cmd in ["status", "cancel"] {
        let r = cli(addr, home, &[cmd]).await;
        assert_eq!((r.code, r.err.as_str()), (1, "Error: task ID required\n"));
        let r = cli(addr, home, &[cmd, "abc123"]).await;
        assert_eq!(
            (r.code, r.err.as_str()),
            (1, "Error: invalid task ID: abc123\n")
        );
    }
    assert_eq!(fake.calls().len(), before);
}

#[tokio::test]
async fn not_logged_in_fails_before_connecting() {
    let fake = Fake::default();
    let addr = serve(fake.clone(), None).await;
    let home = tempfile::tempdir().unwrap();
    let home = home.path();
    let id = "a".repeat(64);
    for args in [
        vec!["status", id.as_str()],
        vec!["status", id.as_str(), "-f"],
        vec!["cancel", id.as_str()],
        vec!["usage"],
        vec!["submit", "--repo", "r", "--prompt", "p"],
    ] {
        let r = cli(addr, home, &args).await;
        assert_eq!(r.code, 1, "{args:?} {r:?}");
        assert!(
            r.err
                .contains("Not logged in. Run 'marathon login' or 'marathon register' first."),
            "{args:?} {r:?}"
        );
    }
    assert!(fake.calls().is_empty());
}

#[tokio::test]
async fn rejected_credentials_suggest_login() {
    let fake = Fake::default();
    let addr = serve(fake.clone(), None).await;
    let home = tempfile::tempdir().unwrap();
    let home = home.path();
    std::fs::create_dir_all(home.join(".marathon")).unwrap();
    std::fs::write(
        creds_path(home),
        "token=stale\napi_key=mk_revoked_key_000\nemail=old@example.com\n",
    )
    .unwrap();
    let r = cli(addr, home, &["usage"]).await;
    assert_eq!(r.code, 1, "{r:?}");
    assert!(r.err.contains("(Unauthenticated)"), "{r:?}");
    assert!(r.err.contains("Run 'marathon login'"), "{r:?}");
}

/// A file written by the Zig client (`saveCredentials` formats
/// `token={s}\napi_key={s}\nemail={s}\n` and creates it 0600) is read
/// unchanged and its API key authenticates.
#[tokio::test]
async fn zig_credentials_file_is_read() {
    let fake = Fake::default();
    let addr = serve(fake.clone(), None).await;
    let home = tempfile::tempdir().unwrap();
    let home = home.path();
    let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1In0.c2ln";
    let api_key = "mk_7f3a9c2e5b1d4f6a8c0e2b4d6f8a0c2e";
    fake.state.lock().unwrap().accounts.insert(
        "zig@example.com".into(),
        Account {
            password: "pw".into(),
            token: token.into(),
            api_key: api_key.into(),
        },
    );
    let zig_bytes = format!("token={token}\napi_key={api_key}\nemail=zig@example.com\n");
    std::fs::create_dir_all(home.join(".marathon")).unwrap();
    std::fs::write(creds_path(home), &zig_bytes).unwrap();

    let r = cli(addr, home, &["whoami"]).await;
    assert_eq!(r.code, 0, "{r:?}");
    assert_eq!(
        r.out,
        "Logged in as: zig@example.com\nAPI Key:      mk_7f3a9...0c2e\n"
    );

    let r = cli(addr, home, &["usage"]).await;
    assert_eq!(r.code, 0, "{r:?}");
    let call = fake.calls().pop().unwrap();
    assert_eq!(call.api_key.as_deref(), Some(api_key));

    // A Rust login writes the same bytes the Zig client would have.
    let r = cli(
        addr,
        home,
        &["login", "--email", "zig@example.com", "--password", "pw"],
    )
    .await;
    assert_eq!(r.code, 0, "{r:?}");
    assert_eq!(
        std::fs::read_to_string(creds_path(home)).unwrap(),
        zig_bytes
    );
}

/// With an empty stored API key the JWT is sent as a Bearer token.
#[tokio::test]
async fn bearer_token_when_no_api_key() {
    let fake = Fake::default();
    let home = tempfile::tempdir().unwrap();
    let home = home.path();
    let (addr, account) = registered(&fake, home).await;
    std::fs::write(
        creds_path(home),
        format!("token={}\napi_key=\nemail=dev@example.com\n", account.token),
    )
    .unwrap();
    let r = cli(addr, home, &["usage"]).await;
    assert_eq!(r.code, 0, "{r:?}");
    let call = fake.calls().pop().unwrap();
    assert_eq!(call.api_key, None);
    assert_eq!(
        call.authorization,
        Some(format!("Bearer {}", account.token))
    );
}

#[tokio::test]
async fn connection_failure_is_reported() {
    // Bind then drop a listener so the port is closed.
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    drop(listener);
    let home = tempfile::tempdir().unwrap();
    let r = cli(
        addr,
        home.path(),
        &["register", "--email", "a@x", "--password", "p"],
    )
    .await;
    assert_eq!(r.code, 1, "{r:?}");
    assert!(
        r.err.contains("Error: Failed to connect to orchestrator:"),
        "{r:?}"
    );
    assert!(!creds_path(home.path()).exists());
}

#[tokio::test]
async fn invalid_configuration_is_reported() {
    let home = tempfile::tempdir().unwrap();
    let args: Vec<String> = ["marathon", "register", "--email", "a@x", "--password", "p"]
        .map(str::to_owned)
        .to_vec();
    let mut out = Vec::new();
    let mut err = Vec::new();
    let mut prompt = |_: &str| Ok(String::new());
    let mut ctx = Context {
        config: ClientConfig::from_sources(
            |k| (k == "MARATHON_ORCHESTRATOR_PORT").then(|| "99999".to_owned()),
            None,
        ),
        home: Some(home.path().to_owned()),
        out: &mut out,
        err: &mut err,
        password: &mut prompt,
    };
    assert_eq!(run(&args, &mut ctx).await, 1);
    let err = String::from_utf8(err).unwrap();
    assert!(err.contains("Error: invalid configuration"), "{err}");
    assert!(err.contains("MARATHON_ORCHESTRATOR_PORT"), "{err}");

    // Commands that need no orchestrator still work.
    let mut out = Vec::new();
    let mut err = Vec::new();
    let mut ctx = Context {
        config: ClientConfig::from_sources(
            |k| (k == "MARATHON_ORCHESTRATOR_PORT").then(|| "99999".to_owned()),
            None,
        ),
        home: Some(home.path().to_owned()),
        out: &mut out,
        err: &mut err,
        password: &mut prompt,
    };
    assert_eq!(
        run(&["marathon".to_owned(), "logout".to_owned()], &mut ctx).await,
        0
    );
}

#[tokio::test]
async fn help_and_unknown_commands() {
    let home = tempfile::tempdir().unwrap();
    let home = home.path();
    let addr: SocketAddr = "127.0.0.1:9".parse().unwrap();
    for args in [&[][..], &["help"], &["--help"], &["-h"]] {
        let r = cli(addr, home, args).await;
        assert_eq!(r.code, 0, "{args:?} {r:?}");
        assert_eq!(r.out, marathon_client::cli::USAGE, "{args:?}");
        assert!(r.err.is_empty());
    }
    let r = cli(addr, home, &["frobnicate"]).await;
    assert_eq!(r.code, 2, "{r:?}");
    assert!(r.out.is_empty());
    assert_eq!(
        r.err,
        format!(
            "Unknown command: frobnicate\n{}",
            marathon_client::cli::USAGE
        )
    );

    let r = cli(addr, home, &["submit", "--help"]).await;
    assert_eq!(r.code, 0, "{r:?}");
    assert!(r.out.contains("--completion-promise"), "{r:?}");

    let r = cli(addr, home, &["status", "--bogus"]).await;
    assert_eq!(r.code, 2, "{r:?}");
    assert!(r.err.contains("--bogus"), "{r:?}");
}

/// The built `marathon` binary as a user runs it: configuration from the
/// environment and `./.env`, HOME for the credentials, the password from
/// stdin when it is not a terminal, and exit codes.
#[tokio::test(flavor = "multi_thread")]
async fn binary_end_to_end() {
    use std::io::Write as _;
    use std::process::{Command, Stdio};

    let fake = Fake::default();
    let addr = serve(fake.clone(), None).await;
    let home = tempfile::tempdir().unwrap();
    let cwd = tempfile::tempdir().unwrap();
    // The port comes from `.env`, the address and token from the environment.
    std::fs::write(
        cwd.path().join(".env"),
        format!(
            "MARATHON_ORCHESTRATOR_PORT={}\nMARATHON_ORCHESTRATOR_ADDRESS=10.255.255.1\n",
            addr.port()
        ),
    )
    .unwrap();
    let run_bin = |args: &[&str], stdin: Option<&str>| {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_marathon"));
        cmd.args(args)
            .current_dir(cwd.path())
            .env_clear()
            .env("HOME", home.path())
            .env("MARATHON_ORCHESTRATOR_ADDRESS", "127.0.0.1")
            .env("GITHUB_TOKEN", GITHUB_TOKEN)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = cmd.spawn().unwrap();
        let mut pipe = child.stdin.take().unwrap();
        if let Some(input) = stdin {
            pipe.write_all(input.as_bytes()).unwrap();
        }
        drop(pipe);
        let output = child.wait_with_output().unwrap();
        Outcome {
            code: output.status.code().unwrap() as u8,
            out: String::from_utf8(output.stdout).unwrap(),
            err: String::from_utf8(output.stderr).unwrap(),
        }
    };
    let run_async = |args: Vec<&'static str>, stdin: Option<&'static str>| {
        let run_bin = &run_bin;
        async move { tokio::task::block_in_place(|| run_bin(&args, stdin)) }
    };

    let r = run_async(
        vec!["register", "--email", "bin@example.com"],
        Some("from-stdin\n"),
    )
    .await;
    assert_eq!(r.code, 0, "{r:?}");
    assert_eq!(
        fake.state.lock().unwrap().accounts["bin@example.com"].password,
        "from-stdin"
    );
    let path = creds_path(home.path());
    #[cfg(unix)]
    assert_eq!(mode(&path), 0o600);

    let r = run_async(
        vec![
            "submit",
            "--repo",
            "https://github.com/u/r",
            "--prompt",
            "p",
            "-f",
        ],
        None,
    )
    .await;
    assert_eq!(r.code, 0, "{r:?}");
    assert!(r.out.contains("📋 agent: tests pass\n"), "{r:?}");
    assert!(r.out.contains("✅ State: completed\n"), "{r:?}");
    assert_eq!(
        fake.state.lock().unwrap().submits[0].github_token,
        GITHUB_TOKEN
    );

    let r = run_async(
        vec!["submit", "--repo", "r", "--prompt", "please fail", "-f"],
        None,
    )
    .await;
    assert_eq!(r.code, 1, "{r:?}");

    let r = run_async(vec!["whoami"], None).await;
    assert_eq!(r.code, 0, "{r:?}");
    assert!(
        r.out.starts_with("Logged in as: bin@example.com\n"),
        "{r:?}"
    );
    // Logs are off unless RUST_LOG asks for them.
    assert!(r.err.is_empty(), "{r:?}");

    let r = run_async(vec!["logout"], None).await;
    assert_eq!(r.code, 0, "{r:?}");
    assert!(!path.exists());

    let r = run_async(vec!["bogus"], None).await;
    assert_eq!(r.code, 2, "{r:?}");
    let r = run_async(vec![], None).await;
    assert_eq!(r.code, 0, "{r:?}");
    assert_eq!(r.out, marathon_client::cli::USAGE);
}

struct TestPki {
    ca_pem: String,
    identity: Identity,
}

fn test_pki() -> TestPki {
    use rcgen::{BasicConstraints, CertificateParams, DnType, IsCa, Issuer, KeyPair};
    let ca_key = KeyPair::generate().unwrap();
    let mut ca_params = CertificateParams::new(Vec::<String>::new()).unwrap();
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    ca_params
        .distinguished_name
        .push(DnType::CommonName, "Marathon Test CA");
    let ca_cert = ca_params.self_signed(&ca_key).unwrap();
    let issuer = Issuer::new(ca_params, ca_key);

    let server_key = KeyPair::generate().unwrap();
    let server_params =
        CertificateParams::new(vec!["localhost".to_owned(), "127.0.0.1".to_owned()]).unwrap();
    let server_cert = server_params.signed_by(&server_key, &issuer).unwrap();
    TestPki {
        ca_pem: ca_cert.pem(),
        identity: Identity::from_pem(server_cert.pem(), server_key.serialize_pem()),
    }
}

#[tokio::test]
async fn tls_with_custom_ca() {
    let pki = test_pki();
    let fake = Fake::default();
    let addr = serve(fake.clone(), Some(pki.identity)).await;
    let home = tempfile::tempdir().unwrap();
    let home = home.path();
    let ca_path = home.join("ca.pem");
    std::fs::write(&ca_path, &pki.ca_pem).unwrap();

    let mut tls = config(addr);
    tls.tls_enabled = true;
    tls.tls_ca_path = Some(ca_path.to_string_lossy().into_owned());
    for (host, label) in [("127.0.0.1", "ip"), ("localhost", "dns")] {
        let mut c = tls.clone();
        c.orchestrator_address = host.to_owned();
        let r = cli_with(
            c,
            home,
            &["register", "--email", label, "--password", "p"],
            None,
        )
        .await;
        assert_eq!(r.code, 0, "{host}: {r:?}");
    }

    // Without the CA the server certificate is not trusted.
    let mut untrusted = tls.clone();
    untrusted.tls_ca_path = None;
    let r = cli_with(
        untrusted,
        home,
        &["login", "--email", "ip", "--password", "p"],
        None,
    )
    .await;
    assert_eq!(r.code, 1, "{r:?}");
    assert!(
        r.err.contains("Error: Failed to connect to orchestrator:")
            || r.err.contains("Error: Failed to login:"),
        "{r:?}"
    );

    // Plain-text client against the TLS server fails too.
    let r = cli(addr, home, &["login", "--email", "ip", "--password", "p"]).await;
    assert_eq!(r.code, 1, "{r:?}");

    // A missing CA file is reported.
    let mut missing = tls;
    missing.tls_ca_path = Some("/nonexistent/ca.pem".into());
    let r = cli_with(
        missing,
        home,
        &["login", "--email", "ip", "--password", "p"],
        None,
    )
    .await;
    assert_eq!(r.code, 1, "{r:?}");
    assert!(
        r.err
            .contains("cannot read CA certificate /nonexistent/ca.pem"),
        "{r:?}"
    );
}
