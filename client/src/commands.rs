//! Command handlers. Messages and their order follow the Zig CLI; results
//! go to `ctx.out`, progress and errors to `ctx.err`.

use common::client_auth::ClientCredential;
use common::config::ClientConfig;
use common::pb::{self, task_event::Event};
use common::types::now_ms;
use common::{TaskId, TaskState};
use tonic::{Code, Status, Streaming};

use crate::cli::{AuthArgs, Cmd, StatusArgs, SubmitArgs, TaskArgs};
use crate::connect::{self, Client, TraceContext};
use crate::credentials::{self, Credentials};
use crate::{Context, EXIT_FAILURE, EXIT_OK, ExitCode, err, out};

const NOT_LOGGED_IN: &str = "Not logged in. Run 'marathon login' or 'marathon register' first.";

/// `operation` field of the command's span.
pub fn operation_name(cmd: &Cmd) -> &'static str {
    match cmd {
        Cmd::Register(_) => "register",
        Cmd::Login(_) => "login",
        Cmd::Logout => "logout",
        Cmd::Whoami => "whoami",
        Cmd::Submit(_) => "submit_task",
        Cmd::Status(_) => "get_task",
        Cmd::Cancel(_) => "cancel_task",
        Cmd::Usage => "get_usage",
    }
}

pub async fn dispatch(cmd: Cmd, ctx: &mut Context<'_>) -> ExitCode {
    let trace = TraceContext::new();
    tracing::debug!(trace_id = %trace.trace_id(), "trace context");
    match cmd {
        Cmd::Register(args) => auth(ctx, &trace, args, AuthKind::Register).await,
        Cmd::Login(args) => auth(ctx, &trace, args, AuthKind::Login).await,
        Cmd::Logout => logout(ctx),
        Cmd::Whoami => whoami(ctx),
        Cmd::Submit(args) => submit(ctx, &trace, args).await,
        Cmd::Status(args) => status(ctx, &trace, args).await,
        Cmd::Cancel(args) => cancel(ctx, &trace, args).await,
        Cmd::Usage => usage(ctx, &trace).await,
    }
}

// --- shared helpers ---

fn config<'c>(ctx: &'c mut Context<'_>) -> Option<&'c ClientConfig> {
    match &ctx.config {
        Ok(_) => ctx.config.as_ref().ok(),
        Err(e) => {
            let _ = writeln!(ctx.err, "Error: invalid configuration: {e}");
            None
        }
    }
}

/// The stored credential, or an error message when not logged in.
fn credential(ctx: &mut Context<'_>) -> Option<ClientCredential> {
    let path = ctx.credentials_path();
    match credentials::load(&path) {
        Ok(Some(creds)) => match creds.credential() {
            Some(c) => Some(c),
            None => {
                err!(ctx, "{NOT_LOGGED_IN}");
                None
            }
        },
        Ok(None) => {
            err!(ctx, "{NOT_LOGGED_IN}");
            None
        }
        Err(e) => {
            tracing::error!(operation = "load_credentials", error = %e, "cannot read credentials");
            err!(ctx, "Error: {e}");
            None
        }
    }
}

async fn connect_client(ctx: &mut Context<'_>) -> Option<Client> {
    let config = config(ctx)?.clone();
    match connect::connect(&config).await {
        Ok(client) => Some(client),
        Err(e) => {
            err!(ctx, "Error: Failed to connect to orchestrator: {e}");
            None
        }
    }
}

fn rpc_failed(ctx: &mut Context<'_>, what: &str, status: &Status) -> ExitCode {
    tracing::error!(
        operation = what,
        code = ?status.code(),
        message = status.message(),
        "rpc failed"
    );
    err!(
        ctx,
        "Error: Failed to {what}: {} ({:?})",
        status.message(),
        status.code()
    );
    if status.code() == Code::Unauthenticated {
        err!(ctx, "Run 'marathon login' to refresh your credentials.");
    }
    EXIT_FAILURE
}

fn parse_task_id(ctx: &mut Context<'_>, arg: Option<&str>) -> Option<TaskId> {
    let Some(arg) = arg else {
        err!(ctx, "Error: task ID required");
        return None;
    };
    match TaskId::parse(arg) {
        Ok(id) => {
            tracing::Span::current().record(common::telemetry::fields::TASK_ID, id.to_hex());
            Some(id)
        }
        Err(_) => {
            err!(ctx, "Error: invalid task ID: {arg}");
            None
        }
    }
}

fn state_of(wire: i32) -> TaskState {
    TaskState::from_wire(wire)
}

fn state_icon(state: TaskState) -> &'static str {
    match state {
        TaskState::Queued => "⏳",
        TaskState::Starting => "🖥️ ",
        TaskState::Running => "🔥",
        TaskState::Completed => "✅",
        TaskState::Failed => "❌",
        TaskState::Cancelled => "🚫",
        TaskState::Unspecified => "❓",
    }
}

fn print_state_change(ctx: &mut Context<'_>, state: TaskState) {
    out!(ctx, "{} State: {}", state_icon(state), state.as_str());
}

// --- auth ---

#[derive(Clone, Copy)]
enum AuthKind {
    Register,
    Login,
}

async fn auth(
    ctx: &mut Context<'_>,
    trace: &TraceContext,
    args: AuthArgs,
    kind: AuthKind,
) -> ExitCode {
    let Some(email) = args.email else {
        err!(ctx, "Error: --email is required");
        return EXIT_FAILURE;
    };
    let password = match args.password {
        Some(p) => p,
        None => match (ctx.password)("Password: ") {
            Ok(p) => p,
            Err(e) => {
                err!(ctx, "Error: cannot read password: {e}");
                return EXIT_FAILURE;
            }
        },
    };
    if password.is_empty() {
        err!(ctx, "Error: --password is required");
        return EXIT_FAILURE;
    }

    let Some(config) = config(ctx) else {
        return EXIT_FAILURE;
    };
    let (address, port) = (
        config.orchestrator_address.clone(),
        config.orchestrator_port,
    );
    err!(ctx, "Connecting to {address}:{port}...");
    let Some(mut client) = connect_client(ctx).await else {
        return EXIT_FAILURE;
    };

    let result = match kind {
        AuthKind::Register => {
            let req = pb::RegisterRequest {
                email: email.clone(),
                password,
            };
            client
                .register(connect::request(req, trace, None).expect("no credential to apply"))
                .await
        }
        AuthKind::Login => {
            let req = pb::LoginRequest {
                email: email.clone(),
                password,
            };
            client
                .login(connect::request(req, trace, None).expect("no credential to apply"))
                .await
        }
    };
    let (verb, done, failed) = match kind {
        AuthKind::Register => (
            "register",
            "✓ Registration successful!",
            "Registration failed",
        ),
        AuthKind::Login => ("login", "✓ Login successful!", "Login failed"),
    };
    let response = match result {
        Ok(r) => r.into_inner(),
        Err(status) => return rpc_failed(ctx, verb, &status),
    };
    if !response.success {
        tracing::warn!(operation = verb, "{failed}");
        err!(ctx, "{failed}: {}", response.message);
        return EXIT_FAILURE;
    }

    out!(ctx, "{done}");
    if let (Some(token), Some(api_key)) = (response.token, response.api_key) {
        let creds = Credentials {
            token,
            api_key,
            email,
        };
        let path = ctx.credentials_path();
        if let Err(e) = credentials::save(&path, &creds) {
            tracing::error!(operation = "save_credentials", error = %e, "cannot save credentials");
            err!(ctx, "Error: cannot save credentials: {e}");
            return EXIT_FAILURE;
        }
        out!(ctx, "Credentials saved to {}", path.display());
        if matches!(kind, AuthKind::Register) {
            out!(ctx, "API Key: {}", creds.api_key);
        }
    }
    tracing::info!(operation = verb, "authenticated");
    EXIT_OK
}

fn whoami(ctx: &mut Context<'_>) -> ExitCode {
    let path = ctx.credentials_path();
    match credentials::load(&path) {
        Ok(Some(creds)) => {
            out!(ctx, "Logged in as: {}", creds.email);
            out!(ctx, "API Key:      {}", creds.masked_api_key());
            EXIT_OK
        }
        Ok(None) => {
            err!(ctx, "{NOT_LOGGED_IN}");
            EXIT_FAILURE
        }
        Err(e) => {
            err!(ctx, "Error: {e}");
            EXIT_FAILURE
        }
    }
}

fn logout(ctx: &mut Context<'_>) -> ExitCode {
    let path = ctx.credentials_path();
    match credentials::delete(&path) {
        Ok(()) => {
            tracing::info!(operation = "logout", "credentials removed");
            out!(ctx, "✓ Logged out. Credentials removed.");
            EXIT_OK
        }
        Err(e) => {
            tracing::error!(operation = "logout", error = %e, "cannot remove credentials");
            err!(ctx, "Error: {e}");
            EXIT_FAILURE
        }
    }
}

// --- tasks ---

async fn submit(ctx: &mut Context<'_>, trace: &TraceContext, args: SubmitArgs) -> ExitCode {
    let Some(repo) = args.repo else {
        err!(ctx, "Error: --repo is required");
        return EXIT_FAILURE;
    };
    let Some(prompt) = args.prompt else {
        err!(ctx, "Error: --prompt is required");
        return EXIT_FAILURE;
    };
    let Some(config) = config(ctx) else {
        return EXIT_FAILURE;
    };
    let Some(github_token) = config.github_token.clone() else {
        err!(ctx, "Error: GITHUB_TOKEN environment variable is required");
        return EXIT_FAILURE;
    };
    let (address, port, tls) = (
        config.orchestrator_address.clone(),
        config.orchestrator_port,
        config.tls_enabled,
    );
    let Some(cred) = credential(ctx) else {
        return EXIT_FAILURE;
    };

    err!(ctx, "Connecting to orchestrator at {address}:{port}...");
    let Some(mut client) = connect_client(ctx).await else {
        return EXIT_FAILURE;
    };
    err!(ctx, "[client] Connected, TLS enabled: {tls}");
    err!(ctx, "Submitting task...");

    let request = pb::SubmitTaskRequest {
        repo_url: repo,
        branch: args.branch,
        prompt,
        github_token,
        create_pr: args.pr,
        pr_title: args.pr_title,
        pr_body: args.pr_body,
        env_vars: args.env,
        max_iterations: args.max_iterations,
        completion_promise: args.completion_promise,
    };
    let request = match connect::request(request, trace, Some(&cred)) {
        Ok(r) => r,
        Err(e) => {
            err!(ctx, "Error: stored credentials are unusable: {e}");
            return EXIT_FAILURE;
        }
    };
    let mut stream = match client.submit_task(request).await {
        Ok(r) => r.into_inner(),
        Err(status) => return rpc_failed(ctx, "submit task", &status),
    };
    let first = match stream.message().await {
        Ok(Some(event)) => event,
        Ok(None) => {
            err!(
                ctx,
                "Error: Failed to submit task: server sent no task event"
            );
            return EXIT_FAILURE;
        }
        Err(status) => return rpc_failed(ctx, "submit task", &status),
    };
    tracing::Span::current().record(common::telemetry::fields::TASK_ID, &first.task_id);
    tracing::info!(task_id = %first.task_id, "task submitted");

    if !args.follow {
        out!(ctx, "{}", first.task_id);
        return EXIT_OK;
    }

    let state = state_of(first.state);
    out!(ctx, "⏳ Task submitted: {}", first.task_id);
    out!(ctx, "📋 State: {}", state.as_str());
    let task_id = first.task_id.clone();
    // The first event can itself carry output or completion.
    if let Some(code) = print_event(ctx, &first, &mut Some(state)) {
        return code;
    }
    follow(ctx, &task_id, stream, Some(state)).await
}

/// Print one streamed event. Returns the exit code once the task finished.
fn print_event(
    ctx: &mut Context<'_>,
    event: &pb::TaskEvent,
    last_state: &mut Option<TaskState>,
) -> Option<ExitCode> {
    let state = state_of(event.state);
    if *last_state != Some(state) {
        *last_state = Some(state);
        print_state_change(ctx, state);
    }
    match &event.event {
        Some(Event::Output(output)) => {
            let data = String::from_utf8_lossy(&output.data);
            let data = data.strip_suffix('\n').unwrap_or(&data);
            if !data.is_empty() {
                out!(ctx, "📋 {data}");
            }
        }
        Some(Event::Error(e)) => {
            err!(ctx, "   Error: {} — {}", e.code, e.message);
        }
        Some(Event::Complete(done)) => {
            if let Some(msg) = &done.error_message {
                err!(ctx, "   Error: {msg}");
            }
            if let Some(url) = &done.pr_url {
                out!(ctx, "   PR: {url}");
            }
            return Some(terminal_exit(state));
        }
        Some(Event::StateChange(_)) | None => {}
    }
    None
}

fn terminal_exit(state: TaskState) -> ExitCode {
    if state == TaskState::Completed {
        EXIT_OK
    } else {
        EXIT_FAILURE
    }
}

/// Print streamed events until the task completes or the stream ends.
async fn follow(
    ctx: &mut Context<'_>,
    task_id: &str,
    mut stream: Streaming<pb::TaskEvent>,
    mut last_state: Option<TaskState>,
) -> ExitCode {
    loop {
        match stream.message().await {
            Ok(Some(event)) => {
                if let Some(code) = print_event(ctx, &event, &mut last_state) {
                    tracing::info!(task_id, state = ?last_state, "task finished");
                    return code;
                }
            }
            Ok(None) => {
                // A stream that ends in a terminal state without a
                // TaskComplete event still reports that state.
                if let Some(state) = last_state.filter(|s| s.is_terminal()) {
                    return terminal_exit(state);
                }
                tracing::warn!(task_id, "event stream ended before the task finished");
                err!(
                    ctx,
                    "⚠️  Connection lost: the event stream ended before the task finished"
                );
                err!(ctx, "   Resume with: marathon status {task_id} --follow");
                return EXIT_FAILURE;
            }
            Err(status) => {
                tracing::error!(task_id, code = ?status.code(), message = status.message(), "event stream failed");
                err!(
                    ctx,
                    "⚠️  Connection lost: {} ({:?})",
                    status.message(),
                    status.code()
                );
                err!(ctx, "   Resume with: marathon status {task_id} --follow");
                return EXIT_FAILURE;
            }
        }
    }
}

async fn status(ctx: &mut Context<'_>, trace: &TraceContext, args: StatusArgs) -> ExitCode {
    let Some(task_id) = parse_task_id(ctx, args.task_id.as_deref()) else {
        return EXIT_FAILURE;
    };
    let task_id = task_id.to_hex();
    let Some(cred) = credential(ctx) else {
        return EXIT_FAILURE;
    };
    let Some(mut client) = connect_client(ctx).await else {
        return EXIT_FAILURE;
    };

    if args.follow {
        let req = pb::GetTaskEventsRequest {
            task_id: task_id.clone(),
            follow: true,
        };
        let stream = match connect::request(req, trace, Some(&cred)) {
            Ok(r) => client.get_task_events(r).await,
            Err(e) => {
                err!(ctx, "Error: stored credentials are unusable: {e}");
                return EXIT_FAILURE;
            }
        };
        return match stream {
            Ok(r) => follow(ctx, &task_id, r.into_inner(), None).await,
            Err(status) => rpc_failed(ctx, "get task events", &status),
        };
    }

    let req = pb::GetTaskRequest { task_id };
    let result = match connect::request(req, trace, Some(&cred)) {
        Ok(r) => client.get_task(r).await,
        Err(e) => {
            err!(ctx, "Error: stored credentials are unusable: {e}");
            return EXIT_FAILURE;
        }
    };
    let task = match result {
        Ok(r) => r.into_inner(),
        Err(status) => return rpc_failed(ctx, "get task status", &status),
    };
    out!(ctx, "Task:      {}", task.id);
    out!(ctx, "State:     {}", state_of(task.state).as_str());
    out!(ctx, "Repo:      {}", task.repo_url);
    out!(ctx, "Branch:    {}", task.branch);
    out!(ctx, "Created:   {}", task.created_at);
    if let Some(t) = task.started_at {
        out!(ctx, "Started:   {t}");
    }
    if let Some(t) = task.completed_at {
        out!(ctx, "Completed: {t}");
    }
    if let Some(msg) = &task.error_message {
        out!(ctx, "Error:     {msg}");
    }
    if let Some(url) = &task.pr_url {
        out!(ctx, "PR:        {url}");
    }
    EXIT_OK
}

async fn cancel(ctx: &mut Context<'_>, trace: &TraceContext, args: TaskArgs) -> ExitCode {
    let Some(task_id) = parse_task_id(ctx, args.task_id.as_deref()) else {
        return EXIT_FAILURE;
    };
    let Some(cred) = credential(ctx) else {
        return EXIT_FAILURE;
    };
    let Some(mut client) = connect_client(ctx).await else {
        return EXIT_FAILURE;
    };
    let req = pb::CancelTaskRequest {
        task_id: task_id.to_hex(),
    };
    let result = match connect::request(req, trace, Some(&cred)) {
        Ok(r) => client.cancel_task(r).await,
        Err(e) => {
            err!(ctx, "Error: stored credentials are unusable: {e}");
            return EXIT_FAILURE;
        }
    };
    let response = match result {
        Ok(r) => r.into_inner(),
        Err(status) => return rpc_failed(ctx, "cancel task", &status),
    };
    if response.success {
        tracing::info!(task_id = %task_id, "task cancelled");
        out!(ctx, "Task cancelled.");
        EXIT_OK
    } else {
        tracing::warn!(task_id = %task_id, message = %response.message, "cancel refused");
        err!(ctx, "Cancel failed: {}", response.message);
        EXIT_FAILURE
    }
}

async fn usage(ctx: &mut Context<'_>, trace: &TraceContext) -> ExitCode {
    let Some(cred) = credential(ctx) else {
        return EXIT_FAILURE;
    };
    let Some(mut client) = connect_client(ctx).await else {
        return EXIT_FAILURE;
    };
    let req = pb::GetUsageRequest {
        start_time: 0,
        end_time: now_ms(),
    };
    let result = match connect::request(req, trace, Some(&cred)) {
        Ok(r) => client.get_usage(r).await,
        Err(e) => {
            err!(ctx, "Error: stored credentials are unusable: {e}");
            return EXIT_FAILURE;
        }
    };
    let report = match result {
        Ok(r) => r.into_inner(),
        Err(status) => return rpc_failed(ctx, "get usage", &status),
    };
    let total = report.total.unwrap_or_default();
    out!(ctx, "Usage Report");
    out!(ctx, "============");
    out!(ctx, "Tasks:              {}", report.task_count);
    out!(ctx, "Compute time:       {} ms", total.compute_time_ms);
    out!(ctx, "Input tokens:       {}", total.input_tokens);
    out!(ctx, "Output tokens:      {}", total.output_tokens);
    out!(ctx, "Cache read tokens:  {}", total.cache_read_tokens);
    out!(ctx, "Cache write tokens: {}", total.cache_write_tokens);
    out!(ctx, "Tool calls:         {}", total.tool_calls);
    EXIT_OK
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn icons_match_zig() {
        assert_eq!(state_icon(TaskState::Queued), "⏳");
        assert_eq!(state_icon(TaskState::Starting), "🖥️ ");
        assert_eq!(state_icon(TaskState::Running), "🔥");
        assert_eq!(state_icon(TaskState::Completed), "✅");
        assert_eq!(state_icon(TaskState::Failed), "❌");
        assert_eq!(state_icon(TaskState::Cancelled), "🚫");
        assert_eq!(state_icon(TaskState::Unspecified), "❓");
    }

    #[test]
    fn exit_code_by_terminal_state() {
        assert_eq!(terminal_exit(TaskState::Completed), EXIT_OK);
        assert_eq!(terminal_exit(TaskState::Failed), EXIT_FAILURE);
        assert_eq!(terminal_exit(TaskState::Cancelled), EXIT_FAILURE);
    }
}
