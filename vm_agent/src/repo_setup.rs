//! Guest repository preparation and credential ownership.

use common::{pb::VsockStart, telemetry::Operation};
use std::{future::Future, io, os::unix::fs::PermissionsExt, path::Path};
use tokio::{fs, process::Command};
use tracing::Instrument;

/// Repository clone, configuration, or filesystem failure.
#[derive(Debug, thiserror::Error)]
pub enum SetupError {
    /// The repository URL is not a supported GitHub format.
    #[error("UnsupportedRepoUrl")]
    UnsupportedRepoUrl,
    /// The git clone command failed.
    #[error("GitCloneFailed")]
    GitCloneFailed,
    /// A required local git setting could not be written.
    #[error("GitConfigFailed")]
    GitConfigFailed,
    /// A repository filesystem operation failed.
    #[error("Repository filesystem error: {0}")]
    Io(#[from] io::Error),
}

/// Repository preparation boundary for production and tests.
pub trait RepoPreparer: Send + Sync {
    /// Prepare the task repository and its git configuration.
    fn prepare(
        &self,
        task: &VsockStart,
        work_dir: &Path,
    ) -> impl Future<Output = Result<(), SetupError>> + Send;
}

/// Guest repository preparation using git and standard credential paths.
pub struct RepoSetup;

/// Extract a GitHub repository spec or reject unsupported URL formats.
pub fn extract_repo_spec(url: &str) -> Result<&str, SetupError> {
    if let Some(spec) = url
        .strip_prefix("https://github.com/")
        .or_else(|| url.strip_prefix("git@github.com:"))
    {
        return Ok(spec.strip_suffix(".git").unwrap_or(spec));
    }
    if url.contains('/') && !url.contains("://") {
        return Ok(url);
    }
    Err(SetupError::UnsupportedRepoUrl)
}

/// Quote a value as one POSIX shell argument.
pub fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// Replace occurrences of a nonempty token before logging.
pub fn redact(value: &str, token: &str) -> String {
    if token.is_empty() {
        value.into()
    } else {
        value.replace(token, "[REDACTED]")
    }
}

async fn run(args: &[&str], cwd: Option<&Path>, token: &str) -> bool {
    let Some((program, args)) = args.split_first() else {
        return false;
    };
    let mut cmd = Command::new(program);
    cmd.args(args).kill_on_drop(true);
    if let Some(path) = cwd {
        cmd.current_dir(path);
    }
    match cmd.output().await {
        Ok(output) if output.status.success() => true,
        Ok(output) => {
            tracing::warn!(operation = "repo_command", stderr = %redact(&String::from_utf8_lossy(&output.stderr), token), "Repository command failed");
            false
        }
        Err(error) => {
            tracing::warn!(operation = "repo_command", %error, "Repository command spawn failed");
            false
        }
    }
}

impl RepoPreparer for RepoSetup {
    async fn prepare(&self, task: &VsockStart, work_dir: &Path) -> Result<(), SetupError> {
        let clone = Operation::start("repo_clone").task_id(&task.task_id);
        let result = async {
            match fs::remove_dir_all(work_dir).await {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                Err(error) => {
                    tracing::warn!(operation = "repo_clone", %error, "Could not remove previous workspace, continuing");
                }
            }
            fs::create_dir_all(work_dir).await?;
            let dir = work_dir.to_string_lossy();
            run(
                &["chown", "-R", "1000:1000", &dir],
                None,
                &task.github_token,
            )
            .await;
            let spec = extract_repo_spec(&task.repo_url)?;
            let url = format!(
                "https://x-access-token:{}@github.com/{spec}",
                task.github_token
            );
            if !run(
                &[
                    "git",
                    "clone",
                    "--branch",
                    &task.branch,
                    "--depth",
                    "1",
                    &url,
                    &dir,
                ],
                None,
                &task.github_token,
            )
            .await
            {
                return Err(SetupError::GitCloneFailed);
            }
            run(
                &["chown", "-R", "1000:1000", &dir],
                None,
                &task.github_token,
            )
            .await;
            Ok(())
        }
        .instrument(clone.span().clone())
        .await;
        match result {
            Ok(()) => {
                clone.finish();
            }
            Err(e) => {
                clone.fail(&e);
                return Err(e);
            }
        }
        let config = Operation::start("repo_config").task_id(&task.task_id);
        let result = async {
            let dir = work_dir.to_string_lossy();
            run(
                &["git", "config", "--global", "--add", "safe.directory", &dir],
                None,
                &task.github_token,
            )
            .await;
            let command = format!(
                "git config --global --add safe.directory {}",
                shell_quote(&dir)
            );
            run(
                &["su", "-s", "/bin/sh", "marathon", "-c", &command],
                None,
                &task.github_token,
            )
            .await;
            for (key, value) in [
                ("user.name", "Marathon Agent"),
                ("user.email", "marathon@local"),
                ("credential.helper", "store --file=/tmp/.git-credentials"),
            ] {
                if !run(
                    &["git", "config", key, value],
                    Some(work_dir),
                    &task.github_token,
                )
                .await
                {
                    return Err(SetupError::GitConfigFailed);
                }
            }
            let path = Path::new("/tmp/.git-credentials");
            let mut options = fs::OpenOptions::new();
            options.write(true).create(true).truncate(true).mode(0o600);
            let mut file = options.open(path).await?;
            file.set_permissions(std::fs::Permissions::from_mode(0o600))
                .await?;
            use tokio::io::AsyncWriteExt;
            file.write_all(
                format!("https://x-access-token:{}@github.com\n", task.github_token).as_bytes(),
            )
            .await?;
            run(
                &["chown", "1000:1000", "/tmp/.git-credentials"],
                None,
                &task.github_token,
            )
            .await;
            Ok(())
        }
        .instrument(config.span().clone())
        .await;
        match &result {
            Ok(()) => {
                config.finish();
            }
            Err(e) => {
                config.fail(e);
            }
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_repo_spec_handles_https_url() {
        assert_eq!(
            extract_repo_spec("https://github.com/owner/repo").unwrap(),
            "owner/repo"
        );
    }

    #[test]
    fn extract_repo_spec_handles_https_url_with_git() {
        assert_eq!(
            extract_repo_spec("https://github.com/owner/repo.git").unwrap(),
            "owner/repo"
        );
    }

    #[test]
    fn extract_repo_spec_handles_ssh_url() {
        assert_eq!(
            extract_repo_spec("git@github.com:owner/repo.git").unwrap(),
            "owner/repo"
        );
    }

    #[test]
    fn extract_repo_spec_handles_short_form() {
        assert_eq!(extract_repo_spec("owner/repo").unwrap(), "owner/repo");
    }

    #[test]
    fn unsupported_repo_formats() {
        assert!(matches!(
            extract_repo_spec("https://gitlab.com/owner/repo"),
            Err(SetupError::UnsupportedRepoUrl)
        ));
        assert!(extract_repo_spec("repo").is_err());
        assert_eq!(
            extract_repo_spec("owner/repo.git").unwrap(),
            "owner/repo.git"
        );
    }

    #[test]
    fn shell_quote_and_redact() {
        assert_eq!(shell_quote("a b"), "'a b'");
        assert_eq!(shell_quote("a'b"), r#"'a'\''b'"#);
        assert_eq!(
            redact("fatal: secret-token", "secret-token"),
            "fatal: [REDACTED]"
        );
    }
}
