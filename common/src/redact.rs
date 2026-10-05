//! `Debug` for generated messages that carry secrets.
//!
//! `build.rs` generates these messages without `#[derive(Debug)]` so that
//! logging a request never prints a password, token, API key or env var
//! value. A secret prints as `<redacted>` when set and `""` when empty, so
//! a missing value stays visible.
//!
//! Also: [`redact_url`] / [`SafeUrl`] for connection URLs, and [`Secret`] /
//! [`OptSecret`] for hand-written `Debug` impls. Credentials in gRPC
//! metadata are handled by [`crate::client_auth`].

use std::fmt;

use crate::pb;

/// Placeholder printed instead of a secret.
pub const REDACTED: &str = "<redacted>";

/// Debug-formats a secret string without its content.
pub struct Secret<'a>(pub &'a str);

impl fmt::Debug for Secret<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.0.is_empty() {
            f.write_str("\"\"")
        } else {
            f.write_str(REDACTED)
        }
    }
}

/// Debug-formats an optional secret string without its content.
pub struct OptSecret<'a>(pub Option<&'a str>);

impl fmt::Debug for OptSecret<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.0 {
            None => f.write_str("None"),
            Some(s) => write!(f, "Some({:?})", Secret(s)),
        }
    }
}

/// A URL safe to log: user info (`user:password@`) and the query string and
/// fragment (which can carry `password=` or tokens) become `<redacted>`.
///
/// Errs on the side of hiding:
/// - a scheme is kept only when the string starts with a valid one
///   (`ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) "://"`);
/// - everything before the last `@` is treated as user info, so `/`, `?`,
///   `#` or `://` inside an unencoded password are hidden too;
/// - SSH-style `git@host:path` keeps only `host:path`.
///
/// `redis://:pw@host:6379/0` becomes `redis://<redacted>@host:6379/0`.
pub fn redact_url(url: &str) -> String {
    let (scheme, rest) = split_scheme(url);
    let host_part = match rest.rfind('@') {
        Some(at) => &rest[at + 1..],
        None => rest,
    };
    let userinfo = if host_part.len() < rest.len() {
        format!("{REDACTED}@")
    } else {
        String::new()
    };
    let (main, tail) = match host_part.find(['?', '#']) {
        Some(i) => host_part.split_at(i),
        None => (host_part, ""),
    };
    let tail = match tail.chars().next() {
        Some(c) => format!("{c}{REDACTED}"),
        None => String::new(),
    };
    format!("{scheme}{userinfo}{main}{tail}")
}

/// Split off a leading RFC 3986 scheme and `://`, if there is a valid one.
fn split_scheme(url: &str) -> (&str, &str) {
    let Some(i) = url.find("://") else {
        return ("", url);
    };
    let scheme = &url[..i];
    let mut chars = scheme.chars();
    let valid = chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
    if valid {
        url.split_at(i + 3)
    } else {
        ("", url)
    }
}

/// Debug-formats a URL through [`redact_url`].
pub struct SafeUrl<'a>(pub &'a str);

impl fmt::Debug for SafeUrl<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(&redact_url(self.0), f)
    }
}

/// Debug-formats secret bytes without their content.
struct SecretBytes<'a>(&'a [u8]);

impl fmt::Debug for SecretBytes<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.0.is_empty() {
            f.write_str("[]")
        } else {
            write!(f, "<redacted {} bytes>", self.0.len())
        }
    }
}

impl fmt::Debug for pb::EnvVar {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("EnvVar")
            .field("key", &self.key)
            .field("value", &Secret(&self.value))
            .finish()
    }
}

impl fmt::Debug for pb::SubmitTaskRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SubmitTaskRequest")
            .field("repo_url", &SafeUrl(&self.repo_url))
            .field("branch", &self.branch)
            .field("prompt", &self.prompt)
            .field("github_token", &Secret(&self.github_token))
            .field("create_pr", &self.create_pr)
            .field("pr_title", &self.pr_title)
            .field("pr_body", &self.pr_body)
            .field("env_vars", &self.env_vars)
            .field("max_iterations", &self.max_iterations)
            .field("completion_promise", &self.completion_promise)
            .finish()
    }
}

impl fmt::Debug for pb::RegisterRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RegisterRequest")
            .field("email", &self.email)
            .field("password", &Secret(&self.password))
            .finish()
    }
}

impl fmt::Debug for pb::LoginRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LoginRequest")
            .field("email", &self.email)
            .field("password", &Secret(&self.password))
            .finish()
    }
}

impl fmt::Debug for pb::AuthResponse {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AuthResponse")
            .field("success", &self.success)
            .field("token", &OptSecret(self.token.as_deref()))
            .field("api_key", &OptSecret(self.api_key.as_deref()))
            .field("message", &self.message)
            .finish()
    }
}

impl fmt::Debug for pb::NodeAuth {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("NodeAuth")
            .field("node_id", &self.node_id)
            .field("timestamp_ms", &self.timestamp_ms)
            .field("token", &SecretBytes(&self.token))
            .finish()
    }
}

impl fmt::Debug for pb::ExecuteTask {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ExecuteTask")
            .field("task_id", &self.task_id)
            .field("repo_url", &SafeUrl(&self.repo_url))
            .field("branch", &self.branch)
            .field("prompt", &self.prompt)
            .field("github_token", &Secret(&self.github_token))
            .field("anthropic_api_key", &Secret(&self.anthropic_api_key))
            .field("create_pr", &self.create_pr)
            .field("pr_title", &self.pr_title)
            .field("pr_body", &self.pr_body)
            .field("timeout_ms", &self.timeout_ms)
            .field("max_tokens", &self.max_tokens)
            .field("env_vars", &self.env_vars)
            .field("max_iterations", &self.max_iterations)
            .field("completion_promise", &self.completion_promise)
            .finish()
    }
}

impl fmt::Debug for pb::VsockStart {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("VsockStart")
            .field("task_id", &self.task_id)
            .field("repo_url", &SafeUrl(&self.repo_url))
            .field("branch", &self.branch)
            .field("prompt", &self.prompt)
            .field("github_token", &Secret(&self.github_token))
            .field("anthropic_api_key", &Secret(&self.anthropic_api_key))
            .field("create_pr", &self.create_pr)
            .field("pr_title", &self.pr_title)
            .field("pr_body", &self.pr_body)
            .field("max_iterations", &self.max_iterations)
            .field("completion_promise", &self.completion_promise)
            .field("env_vars", &self.env_vars)
            .finish()
    }
}

impl fmt::Debug for pb::Task {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Task")
            .field("id", &self.id)
            .field("client_id", &self.client_id)
            .field("state", &self.state)
            .field("repo_url", &SafeUrl(&self.repo_url))
            .field("branch", &self.branch)
            .field("prompt", &self.prompt)
            .field("node_id", &self.node_id)
            .field("vm_id", &self.vm_id)
            .field("created_at", &self.created_at)
            .field("started_at", &self.started_at)
            .field("completed_at", &self.completed_at)
            .field("error_message", &self.error_message)
            .field("pr_url", &self.pr_url)
            .field("usage", &self.usage)
            .field("create_pr", &self.create_pr)
            .field("pr_title", &self.pr_title)
            .field("pr_body", &self.pr_body)
            .field("max_iterations", &self.max_iterations)
            .field("completion_promise", &self.completion_promise)
            .finish()
    }
}

impl fmt::Debug for pb::TaskSummary {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TaskSummary")
            .field("task_id", &self.task_id)
            .field("state", &self.state)
            .field("repo_url", &SafeUrl(&self.repo_url))
            .field("created_at", &self.created_at)
            .field("completed_at", &self.completed_at)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pb::{node_command, vsock_message};

    const REPO_WITH_CREDS: &str = "https://user:repo-SECRET7@github.com/example/repo.git";

    #[test]
    fn repo_urls_redacted_everywhere() {
        let check = |debug: String| {
            assert!(!debug.contains("SECRET"), "{debug}");
            assert!(debug.contains("github.com/example/repo.git"), "{debug}");
        };
        check(format!(
            "{:?}",
            pb::SubmitTaskRequest {
                repo_url: REPO_WITH_CREDS.into(),
                ..Default::default()
            }
        ));
        check(format!(
            "{:?}",
            pb::HeartbeatResponse {
                commands: vec![pb::NodeCommand {
                    command: Some(node_command::Command::ExecuteTask(pb::ExecuteTask {
                        repo_url: REPO_WITH_CREDS.into(),
                        ..Default::default()
                    })),
                }],
                ..Default::default()
            }
        ));
        check(format!(
            "{:?}",
            pb::VsockMessage {
                payload: Some(vsock_message::Payload::Start(pb::VsockStart {
                    repo_url: REPO_WITH_CREDS.into(),
                    ..Default::default()
                })),
            }
        ));
        check(format!(
            "{:?}",
            pb::Task {
                repo_url: REPO_WITH_CREDS.into(),
                ..Default::default()
            }
        ));
        check(format!(
            "{:?}",
            pb::ListTasksResponse {
                tasks: vec![pb::TaskSummary {
                    repo_url: REPO_WITH_CREDS.into(),
                    ..Default::default()
                }],
                total_count: 1,
            }
        ));
        check(format!(
            "{:?}",
            tonic::Response::new(pb::Task {
                repo_url: REPO_WITH_CREDS.into(),
                ..Default::default()
            })
        ));
        let mut task = crate::Task::new(crate::ClientId::random(), REPO_WITH_CREDS, "main", "p");
        check(format!("{task:?}"));
        task.repo_url = "git@github.com:example/repo.git".into();
        assert!(format!("{task:?}").contains("<redacted>@github.com:example/repo.git"));
    }

    const SECRETS: [&str; 6] = [
        "ghp_SECRET1",
        "sk-ant-SECRET2",
        "pw-SECRET3",
        "jwt-SECRET4",
        "mk-SECRET5",
        "env-SECRET6",
    ];

    fn env() -> Vec<pb::EnvVar> {
        vec![pb::EnvVar {
            key: "DATABASE_URL".into(),
            value: SECRETS[5].into(),
        }]
    }

    fn assert_clean(debug: String) {
        for s in SECRETS {
            assert!(!debug.contains(s), "{s} leaked in {debug}");
        }
        assert!(!debug.contains("SECRET"), "{debug}");
    }

    #[test]
    fn secret_messages_redact() {
        let submit = pb::SubmitTaskRequest {
            repo_url: "https://github.com/a/b".into(),
            github_token: SECRETS[0].into(),
            env_vars: env(),
            ..Default::default()
        };
        let debug = format!("{submit:?}");
        assert!(debug.contains("https://github.com/a/b"), "{debug}");
        assert!(debug.contains("DATABASE_URL"), "{debug}");
        assert!(debug.contains(REDACTED), "{debug}");
        assert_clean(debug);

        assert_clean(format!(
            "{:?}",
            pb::RegisterRequest {
                email: "a@b.c".into(),
                password: SECRETS[2].into()
            }
        ));
        assert_clean(format!(
            "{:?}",
            pb::LoginRequest {
                email: "a@b.c".into(),
                password: SECRETS[2].into()
            }
        ));
        assert_clean(format!(
            "{:?}",
            pb::AuthResponse {
                success: true,
                token: Some(SECRETS[3].into()),
                api_key: Some(SECRETS[4].into()),
                message: "ok".into(),
            }
        ));
        assert_clean(format!(
            "{:?}",
            pb::NodeAuth {
                node_id: "00".repeat(16),
                timestamp_ms: 1,
                token: b"SECRET-token-bytes".to_vec(),
            }
        ));

        let exec = pb::ExecuteTask {
            github_token: SECRETS[0].into(),
            anthropic_api_key: SECRETS[1].into(),
            env_vars: env(),
            ..Default::default()
        };
        // Also through the containing messages, as a log line would.
        let response = pb::HeartbeatResponse {
            timestamp: 1,
            acknowledged: true,
            commands: vec![pb::NodeCommand {
                command: Some(node_command::Command::ExecuteTask(exec)),
            }],
        };
        assert_clean(format!("{response:?}"));

        let start = pb::VsockMessage {
            payload: Some(vsock_message::Payload::Start(pb::VsockStart {
                github_token: SECRETS[0].into(),
                anthropic_api_key: SECRETS[1].into(),
                env_vars: env(),
                ..Default::default()
            })),
        };
        assert_clean(format!("{start:?}"));
        assert_clean(format!(
            "{:?}",
            tonic::Request::new(pb::LoginRequest {
                email: "a@b.c".into(),
                password: SECRETS[2].into(),
            })
        ));
    }

    #[test]
    fn node_auth_token_bytes_hidden() {
        let token: Vec<u8> = (0u8..32)
            .map(|i| i.wrapping_mul(7).wrapping_add(200))
            .collect();
        let auth = pb::NodeAuth {
            node_id: "0f".repeat(16),
            timestamp_ms: 42,
            token: token.clone(),
        };
        assert_eq!(
            format!("{auth:?}"),
            format!(
                "NodeAuth {{ node_id: \"{}\", timestamp_ms: 42, token: <redacted 32 bytes> }}",
                "0f".repeat(16)
            )
        );
        // No rendering of the bytes appears, whatever the format.
        let debug = format!("{auth:#?}");
        assert!(!debug.contains(&format!("{token:?}")[1..20]), "{debug}");
        assert!(
            !debug.contains(&format!("{:02x}{:02x}", token[0], token[1])),
            "{debug}"
        );
    }

    #[test]
    fn urls_lose_credentials() {
        let cases = [
            (
                "redis://:pw@cache:6379/0",
                "redis://<redacted>@cache:6379/0",
            ),
            (
                "postgresql://marathon:marathon@localhost:5432/marathon",
                "postgresql://<redacted>@localhost:5432/marathon",
            ),
            (
                "postgres://u@h/db?sslmode=require&password=pw",
                "postgres://<redacted>@h/db?<redacted>",
            ),
            ("redis://:p/w@h:1", "redis://<redacted>@h:1"),
            ("redis://:p@w@h:1#frag", "redis://<redacted>@h:1#<redacted>"),
            ("user:pw@host:5432", "<redacted>@host:5432"),
            ("redis://localhost:6379", "redis://localhost:6379"),
            ("localhost:2379", "localhost:2379"),
            ("", ""),
            // A-R3-01: `://` that is not a leading scheme is user info.
            ("user:scheme_secret://pw@host:5432", "<redacted>@host:5432"),
            ("1http://u:pw@h", "<redacted>@h"),
            ("://u:pw@h", "<redacted>@h"),
            // `?`, `#` or `@` inside an unencoded password.
            ("redis://:p?w@h:1/0", "redis://<redacted>@h:1/0"),
            ("redis://:p#w@h:1", "redis://<redacted>@h:1"),
            // Schemes with + - . digits, IPv6 hosts, encoded passwords.
            (
                "git+ssh://u:pw@h.example:22/r.git",
                "git+ssh://<redacted>@h.example:22/r.git",
            ),
            (
                "postgres://u:p%40ss@[::1]:5432/db",
                "postgres://<redacted>@[::1]:5432/db",
            ),
            ("https://[::1]:443/x", "https://[::1]:443/x"),
            ("git@github.com:o/r.git", "<redacted>@github.com:o/r.git"),
            ("https://h/x#tok", "https://h/x#<redacted>"),
        ];
        for (input, want) in cases {
            assert_eq!(redact_url(input), want, "{input}");
        }
        assert_eq!(
            format!("{:?}", SafeUrl("redis://:pw@h:1")),
            "\"redis://<redacted>@h:1\""
        );
    }

    #[test]
    fn empty_and_absent_secrets_stay_visible() {
        let debug = format!("{:?}", pb::SubmitTaskRequest::default());
        assert!(debug.contains("github_token: \"\""), "{debug}");
        let debug = format!("{:?}", pb::AuthResponse::default());
        assert!(debug.contains("token: None"), "{debug}");
        let debug = format!("{:?}", pb::NodeAuth::default());
        assert!(debug.contains("token: []"), "{debug}");
    }
}
