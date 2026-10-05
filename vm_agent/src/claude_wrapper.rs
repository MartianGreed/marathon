//! Claude subprocess isolation and concurrent byte streaming.

use common::{
    pb::{OutputType, VsockMessage, VsockOutput, VsockStart, vsock_message::Payload},
    telemetry::Operation,
    types::UsageMetrics,
};
use std::os::unix::process::ExitStatusExt;
use std::{collections::BTreeMap, io, path::PathBuf, process::Stdio};
use tokio::{
    io::{AsyncRead, AsyncReadExt},
    process::Command,
    sync::mpsc,
};
use tracing::Instrument;

/// Claude subprocess settings and output streaming.
pub struct ClaudeWrapper {
    /// Executable used for each Claude iteration.
    pub claude_code_path: PathBuf,
    /// Working directory inherited by the child.
    pub work_dir: PathBuf,
    /// Set the child uid/gid to 1000 when enabled.
    pub run_as_marathon: bool,
}

/// Exit status, captured output, and usage from one iteration.
pub struct RunResult {
    /// Process exit code, negative signal number, or -1.
    pub exit_code: i32,
    /// First GitHub pull request URL found in stdout.
    pub pr_url: Option<String>,
    /// Usage reported by this iteration.
    pub metrics: UsageMetrics,
    /// Whether stdout contains the configured completion text.
    pub output_contains_promise: bool,
    /// Accumulated stdout bytes.
    pub stdout: Vec<u8>,
    /// Accumulated stderr bytes.
    pub stderr: Vec<u8>,
}

/// Read integer usage fields; absent or invalid fields become zero.
pub fn parse_json_metrics(output: &[u8]) -> UsageMetrics {
    let value: serde_json::Value = serde_json::from_slice(output).unwrap_or_default();
    metrics_from_usage(&value["usage"])
}

/// Read token counts from a JSON usage object.
pub(crate) fn metrics_from_usage(usage: &serde_json::Value) -> UsageMetrics {
    let number = |key: &str| usage[key].as_i64().unwrap_or(0);
    UsageMetrics {
        input_tokens: number("input_tokens"),
        output_tokens: number("output_tokens"),
        cache_read_tokens: number("cache_read_input_tokens"),
        cache_write_tokens: number("cache_creation_input_tokens"),
        ..Default::default()
    }
}

/// Check for the configured completion text in output.
pub fn check_completion_promise(output: &str, promise: Option<&str>) -> bool {
    promise.is_some_and(|p| output.contains(p))
}

/// Find the first GitHub pull request URL in stdout.
pub fn extract_pr_url(output: &str) -> Option<String> {
    crate::signal_parser::extract_url(output, false)
}

/// Build the isolated child environment; later task entries win.
pub fn build_env_map(task: &VsockStart) -> BTreeMap<String, String> {
    let mut env: BTreeMap<String, String> = [
        ("HOME", "/home/marathon"),
        (
            "PATH",
            "/usr/local/bin:/usr/bin:/bin:/home/marathon/.local/bin",
        ),
        ("TERM", "xterm-256color"),
        ("USER", "marathon"),
        ("SHELL", "/bin/bash"),
        ("ANTHROPIC_API_KEY", task.anthropic_api_key.as_str()),
        ("GITHUB_TOKEN", task.github_token.as_str()),
    ]
    .into_iter()
    .map(|(k, v)| (k.into(), v.into()))
    .collect();
    for entry in &task.env_vars {
        env.insert(entry.key.clone(), entry.value.clone());
    }
    env
}

async fn read_output(
    mut reader: impl AsyncRead + Unpin,
    kind: OutputType,
    tx: &mpsc::Sender<VsockMessage>,
) -> io::Result<Vec<u8>> {
    let mut total = Vec::new();
    let mut buf = [0; 4096];
    loop {
        let n = reader.read(&mut buf).await?;
        if n == 0 {
            return Ok(total);
        }
        total.extend_from_slice(&buf[..n]);
        if tx
            .send(
                Payload::Output(VsockOutput {
                    r#type: kind as i32,
                    data: buf[..n].to_vec(),
                })
                .into(),
            )
            .await
            .is_err()
        {
            tracing::warn!(operation = "claude_output", "Output consumer closed");
        }
    }
}

impl ClaudeWrapper {
    /// Create a wrapper with explicit executable, cwd, and run-as policy.
    pub fn new(
        path: impl Into<PathBuf>,
        work_dir: impl Into<PathBuf>,
        run_as_marathon: bool,
    ) -> Self {
        Self {
            claude_code_path: path.into(),
            work_dir: work_dir.into(),
            run_as_marathon,
        }
    }

    /// Run one iteration while streaming both output pipes.
    pub async fn run(
        &self,
        task: &VsockStart,
        prompt: &str,
        tx: &mpsc::Sender<VsockMessage>,
    ) -> io::Result<RunResult> {
        let op = Operation::start("claude_run").task_id(&task.task_id);
        let result = async {
            let mut command = Command::new(&self.claude_code_path);
            if !self.claude_code_path.to_string_lossy().ends_with("/env") {
                command.args([
                    "--print",
                    "--dangerously-skip-permissions",
                    "--output-format",
                    "json",
                    prompt,
                ]);
            }
            command
                .current_dir(&self.work_dir)
                .env_clear()
                .envs(build_env_map(task))
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .kill_on_drop(true);
            if self.run_as_marathon {
                command.uid(1000).gid(1000);
            }
            let mut child = command.spawn()?;
            let stdout = child
                .stdout
                .take()
                .ok_or_else(|| io::Error::other("stdout pipe missing"))?;
            let stderr = child
                .stderr
                .take()
                .ok_or_else(|| io::Error::other("stderr pipe missing"))?;
            let (stdout, stderr) = tokio::try_join!(
                read_output(stdout, OutputType::Stdout, tx),
                read_output(stderr, OutputType::Stderr, tx)
            )?;
            let status = child.wait().await?;
            let text = String::from_utf8_lossy(&stdout);
            Ok(RunResult {
                exit_code: status
                    .code()
                    .or_else(|| status.signal().map(|s| -s))
                    .unwrap_or(-1),
                pr_url: extract_pr_url(&text),
                metrics: parse_json_metrics(&stdout),
                output_contains_promise: check_completion_promise(
                    &text,
                    task.completion_promise.as_deref(),
                ),
                stdout,
                stderr,
            })
        }
        .instrument(op.span().clone())
        .await;
        match &result {
            Ok(_) => {
                op.finish();
            }
            Err(error) => {
                op.fail(error);
            }
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn task() -> VsockStart {
        VsockStart {
            anthropic_api_key: "test-api".into(),
            github_token: "test-token".into(),
            ..Default::default()
        }
    }

    async fn run_command(path: &str) -> RunResult {
        let tmp = tempfile::tempdir().unwrap();
        let w = ClaudeWrapper::new(path, tmp.path(), false);
        let (tx, mut rx) = mpsc::channel(64);
        let drain = tokio::spawn(async move { while rx.recv().await.is_some() {} });
        let r = w.run(&task(), "test", &tx).await.unwrap();
        drop(tx);
        drain.await.unwrap();
        r
    }

    #[test]
    fn claude_wrapper_init() {
        let w = ClaudeWrapper::new("/usr/local/bin/claude", "/workspace", false);
        assert!(!w.run_as_marathon);
    }

    #[test]
    fn parse_json_metrics_extracts_all_token_fields() {
        let m = parse_json_metrics(br#"{"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":10,"cache_creation_input_tokens":5}}"#);
        assert_eq!(
            (
                m.input_tokens,
                m.output_tokens,
                m.cache_read_tokens,
                m.cache_write_tokens
            ),
            (100, 50, 10, 5)
        );
    }

    #[test]
    fn parse_json_metrics_handles_missing_usage() {
        assert_eq!(
            parse_json_metrics(br#"{"result":"success","model":"claude-3"}"#),
            UsageMetrics::default()
        );
    }

    #[test]
    fn parse_json_metrics_handles_invalid_json() {
        assert_eq!(
            parse_json_metrics(b"not valid json {{{"),
            UsageMetrics::default()
        );
    }

    #[test]
    fn parse_json_metrics_handles_partial_usage_fields() {
        let m = parse_json_metrics(br#"{"usage":{"input_tokens":100}}"#);
        assert_eq!(m.input_tokens, 100);
        assert_eq!(m.output_tokens, 0);
        assert_eq!(m.cache_read_tokens, 0);
    }

    #[test]
    fn check_completion_promise_returns_true_when_found() {
        assert!(check_completion_promise(
            "Task completed successfully. TASK_COMPLETE: All done!",
            Some("TASK_COMPLETE")
        ));
    }

    #[test]
    fn check_completion_promise_returns_false_when_missing() {
        assert!(!check_completion_promise(
            "Task is still running, not complete yet.",
            Some("TASK_COMPLETE")
        ));
    }

    #[test]
    fn check_completion_promise_returns_false_when_null_promise() {
        assert!(!check_completion_promise("TASK_COMPLETE: All done!", None));
    }

    #[test]
    fn check_completion_promise_finds_promise_at_start() {
        assert!(check_completion_promise(
            "DONE: Task finished",
            Some("DONE:")
        ));
    }

    #[test]
    fn extract_pr_url_finds_github_pr_url() {
        assert_eq!(
            extract_pr_url("Created PR: https://github.com/owner/repo/pull/123\nDone."),
            Some("https://github.com/owner/repo/pull/123".into())
        );
    }

    #[test]
    fn extract_pr_url_returns_null_for_non_pr_github_urls() {
        assert_eq!(
            extract_pr_url("See issue: https://github.com/owner/repo/issues/456"),
            None
        );
    }

    #[test]
    fn extract_pr_url_returns_null_when_no_url() {
        assert_eq!(extract_pr_url("No URLs in this output at all."), None);
    }

    #[test]
    fn extract_pr_url_handles_url_at_end_of_output() {
        assert_eq!(
            extract_pr_url("Done! https://github.com/foo/bar/pull/42"),
            Some("https://github.com/foo/bar/pull/42".into())
        );
    }

    #[test]
    fn extract_pr_url_ignores_gitlab_urls() {
        assert_eq!(
            extract_pr_url("Check: https://gitlab.com/owner/repo/pull/789"),
            None
        );
    }

    #[test]
    fn build_env_map_includes_required_env_vars() {
        let e = build_env_map(&task());
        assert_eq!(e["ANTHROPIC_API_KEY"], "test-api");
        assert_eq!(e["GITHUB_TOKEN"], "test-token");
        assert_eq!(e["HOME"], "/home/marathon");
        assert!(e.contains_key("PATH"));
    }

    #[test]
    fn build_env_map_includes_all_required_environment_variables() {
        let e = build_env_map(&task());
        assert_eq!(e.len(), 7);
        assert_eq!(e["HOME"], "/home/marathon");
        assert_eq!(
            e["PATH"],
            "/usr/local/bin:/usr/bin:/bin:/home/marathon/.local/bin"
        );
        assert_eq!(e["TERM"], "xterm-256color");
        assert_eq!(e["USER"], "marathon");
        assert_eq!(e["SHELL"], "/bin/bash");
        assert_eq!(e["ANTHROPIC_API_KEY"], "test-api");
        assert_eq!(e["GITHUB_TOKEN"], "test-token");
    }

    #[tokio::test]
    async fn run_method_spawns_process_with_correct_environment_variables() {
        let r = run_command("/usr/bin/env").await;
        assert_eq!(r.exit_code, 0);
        let text = String::from_utf8(r.stdout).unwrap();
        for v in [
            "ANTHROPIC_API_KEY=test-api",
            "GITHUB_TOKEN=test-token",
            "HOME=/home/marathon",
            "USER=marathon",
            "SHELL=/bin/bash",
        ] {
            assert!(text.contains(v));
        }
    }

    #[tokio::test]
    async fn run_method_handles_process_failure() {
        assert_eq!(
            run_command(if std::path::Path::new("/bin/false").exists() {
                "/bin/false"
            } else {
                "/usr/bin/false"
            })
            .await
            .exit_code,
            1
        );
    }

    #[test]
    fn metrics_reject_non_integers() {
        assert_eq!(parse_json_metrics(br#"{"usage":{"input_tokens":"100","output_tokens":1.5,"cache_read_input_tokens":true,"cache_creation_input_tokens":null}}"#),UsageMetrics::default());
        for output in [b"null".as_slice(), b"[]", b"1", br#"{"usage":[]}"#] {
            assert_eq!(parse_json_metrics(output), UsageMetrics::default());
        }
    }

    #[test]
    fn env_duplicates_last_wins() {
        let mut t = task();
        t.env_vars = vec![
            common::pb::EnvVar {
                key: "USER".into(),
                value: "first".into(),
            },
            common::pb::EnvVar {
                key: "USER".into(),
                value: "last".into(),
            },
        ];
        assert_eq!(build_env_map(&t)["USER"], "last");
    }
}
