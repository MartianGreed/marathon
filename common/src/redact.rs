//! `Debug` for generated messages that carry secrets.
//!
//! `build.rs` generates these messages without `#[derive(Debug)]` so that
//! logging a request never prints a password, token, API key or env var
//! value. A secret prints as `<redacted>` when set and `""` when empty, so
//! a missing value stays visible.

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
            .field("repo_url", &self.repo_url)
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
            .field("repo_url", &self.repo_url)
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
            .field("repo_url", &self.repo_url)
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pb::{node_command, vsock_message};

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
    fn empty_and_absent_secrets_stay_visible() {
        let debug = format!("{:?}", pb::SubmitTaskRequest::default());
        assert!(debug.contains("github_token: \"\""), "{debug}");
        let debug = format!("{:?}", pb::AuthResponse::default());
        assert!(debug.contains("token: None"), "{debug}");
        let debug = format!("{:?}", pb::NodeAuth::default());
        assert!(debug.contains("token: []"), "{debug}");
    }
}
