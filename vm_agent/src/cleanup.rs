//! Cleanup policy with injectable cache and credential paths.

use common::telemetry::Operation;
use std::{
    io,
    path::{Path, PathBuf},
};
use tokio::{fs, process::Command};
use tracing::Instrument;

/// Guest files to remove after a task.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CleanupStrategy {
    /// Remove the workspace, Claude cache, and credentials.
    Full,
    /// Remove the workspace and credentials, retaining the cache.
    KeepCache,
    /// Retain the workspace and cache, removing credential access.
    KeepWorkspace,
    /// Leave all task files and configuration unchanged.
    None,
}

impl CleanupStrategy {
    /// Parse a strategy; unknown or empty values select full cleanup.
    pub fn from_string(value: &str) -> Self {
        match value {
            "keep_cache" => Self::KeepCache,
            "keep_workspace" => Self::KeepWorkspace,
            "none" => Self::None,
            _ => Self::Full,
        }
    }

    /// Return the configuration spelling of this strategy.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Full => "full",
            Self::KeepCache => "keep_cache",
            Self::KeepWorkspace => "keep_workspace",
            Self::None => "none",
        }
    }
}

impl std::fmt::Display for CleanupStrategy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Cleanup policy with configurable cache and credential paths.
pub struct Cleanup {
    /// Files and configuration to remove.
    pub strategy: CleanupStrategy,
    /// Claude cache directory removed by full cleanup.
    pub cache_path: PathBuf,
    /// Credential file removed by every strategy except none.
    pub credentials_path: PathBuf,
}

impl Default for Cleanup {
    fn default() -> Self {
        Self::new(CleanupStrategy::from_string(
            &std::env::var("MARATHON_CLEANUP_STRATEGY").unwrap_or_default(),
        ))
    }
}

impl Cleanup {
    /// Create a policy using the standard guest paths.
    pub fn new(strategy: CleanupStrategy) -> Self {
        Self {
            strategy,
            cache_path: "/root/.claude".into(),
            credentials_path: "/tmp/.git-credentials".into(),
        }
    }

    /// Apply cleanup, tolerating missing paths and logging failures.
    pub async fn execute(&self, work_dir: &Path, task_id: &str) {
        let op = Operation::start("cleanup").task_id(&task_id);
        async {
            if matches!(
                self.strategy,
                CleanupStrategy::Full | CleanupStrategy::KeepCache
            ) {
                remove(work_dir, true).await;
            }
            if self.strategy == CleanupStrategy::Full {
                remove(&self.cache_path, true).await;
            }
            if self.strategy != CleanupStrategy::None {
                remove(&self.credentials_path, false).await;
            }
            if self.strategy == CleanupStrategy::KeepWorkspace {
                let result = Command::new("git")
                    .args(["config", "--unset", "credential.helper"])
                    .current_dir(work_dir)
                    .output()
                    .await;
                if let Err(error) = result {
                    tracing::warn!(%error, "Could not clear credential helper");
                }
            }
        }
        .instrument(op.span().clone())
        .await;
        op.finish();
    }
}

async fn remove(path: &Path, tree: bool) {
    let result = if tree {
        fs::remove_dir_all(path).await
    } else {
        fs::remove_file(path).await
    };
    if let Err(error) = result
        && error.kind() != io::ErrorKind::NotFound
    {
        tracing::warn!(%error, path = %path.display(), "Cleanup removal failed");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleanup_strategy_from_string_parses_valid_values() {
        for (s, v) in [
            ("full", CleanupStrategy::Full),
            ("keep_cache", CleanupStrategy::KeepCache),
            ("keep_workspace", CleanupStrategy::KeepWorkspace),
            ("none", CleanupStrategy::None),
        ] {
            assert_eq!(CleanupStrategy::from_string(s), v);
        }
    }

    #[test]
    fn cleanup_strategy_from_string_defaults_to_full_for_invalid() {
        assert_eq!(
            CleanupStrategy::from_string("invalid"),
            CleanupStrategy::Full
        );
        assert_eq!(CleanupStrategy::from_string(""), CleanupStrategy::Full);
    }

    #[test]
    fn cleanup_strategy_to_string_returns_correct_strings() {
        for (s, v) in [
            ("full", CleanupStrategy::Full),
            ("keep_cache", CleanupStrategy::KeepCache),
            ("keep_workspace", CleanupStrategy::KeepWorkspace),
            ("none", CleanupStrategy::None),
        ] {
            assert_eq!(v.to_string(), s);
        }
    }

    #[test]
    fn cleanup_init_creates_with_strategy_from_env_default() {
        assert_eq!(
            Cleanup::new(CleanupStrategy::from_string("")).strategy,
            CleanupStrategy::Full
        );
    }

    #[test]
    fn cleanup_init_with_strategy_creates_with_specified_strategy() {
        assert_eq!(
            Cleanup::new(CleanupStrategy::KeepCache).strategy,
            CleanupStrategy::KeepCache
        );
    }
}

#[cfg(test)]
mod filesystem_tests {
    use super::*;

    #[tokio::test]
    async fn injectable_paths_obey_each_strategy_and_missing_paths_are_ok() {
        for strategy in [
            CleanupStrategy::Full,
            CleanupStrategy::KeepCache,
            CleanupStrategy::KeepWorkspace,
            CleanupStrategy::None,
        ] {
            let tmp = tempfile::tempdir().unwrap();
            let work = tmp.path().join("work");
            let cache = tmp.path().join("cache");
            let credentials = tmp.path().join("credentials");
            fs::create_dir(&work).await.unwrap();
            fs::create_dir(&cache).await.unwrap();
            fs::write(&credentials, b"credential").await.unwrap();
            let cleaner = Cleanup {
                strategy,
                cache_path: cache.clone(),
                credentials_path: credentials.clone(),
            };
            cleaner.execute(&work, "cleanup-test").await;
            assert_eq!(
                work.exists(),
                matches!(
                    strategy,
                    CleanupStrategy::KeepWorkspace | CleanupStrategy::None
                )
            );
            assert_eq!(cache.exists(), strategy != CleanupStrategy::Full);
            assert_eq!(credentials.exists(), strategy == CleanupStrategy::None);
            cleaner.execute(&work, "cleanup-test").await;
        }
    }
}
