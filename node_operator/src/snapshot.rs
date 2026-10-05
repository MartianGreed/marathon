//! Firecracker snapshots on disk.
//!
//! Each subdirectory of the snapshot base path that holds both a `snapshot`
//! and a `mem` file is a snapshot named after the directory. The default
//! snapshot is `base`. A missing base path is created.

use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// Name of the snapshot used to restore VMs.
pub const DEFAULT_SNAPSHOT: &str = "base";

/// One discovered snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SnapshotInfo {
    pub name: String,
    pub path: PathBuf,
    /// Unix seconds at discovery.
    pub created_at: i64,
    /// Size of the `snapshot` and `mem` files together.
    pub size_bytes: u64,
}

/// The snapshots found under a base path.
#[derive(Debug)]
pub struct SnapshotManager {
    base_path: PathBuf,
    snapshots: Mutex<HashMap<String, SnapshotInfo>>,
}

impl SnapshotManager {
    /// Scan `base_path`, creating it when it does not exist.
    pub fn new(base_path: impl AsRef<Path>) -> io::Result<Self> {
        let mgr = Self {
            base_path: base_path.as_ref().to_path_buf(),
            snapshots: Mutex::new(HashMap::new()),
        };
        mgr.scan()?;
        Ok(mgr)
    }

    pub fn base_path(&self) -> &Path {
        &self.base_path
    }

    fn scan(&self) -> io::Result<()> {
        let entries = match std::fs::read_dir(&self.base_path) {
            Ok(entries) => entries,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                tracing::info!(
                    operation = "snapshot_scan",
                    path = %self.base_path.display(),
                    "snapshot directory not found, creating"
                );
                std::fs::create_dir_all(&self.base_path)?;
                return Ok(());
            }
            Err(e) => return Err(e),
        };
        let created_at = common::types::now_ms() / 1000;
        let mut found = HashMap::new();
        for entry in entries {
            let entry = entry?;
            if !entry.file_type()?.is_dir() {
                continue;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            let path = self.base_path.join(&name);
            if !validate_snapshot(&path) {
                continue;
            }
            let info = SnapshotInfo {
                name: name.clone(),
                size_bytes: snapshot_size(&path),
                path,
                created_at,
            };
            tracing::info!(
                operation = "snapshot_scan",
                snapshot = %info.name,
                size_bytes = info.size_bytes,
                "snapshot found"
            );
            found.insert(name, info);
        }
        *self.lock() = found;
        Ok(())
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, SnapshotInfo>> {
        self.snapshots
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub fn get_snapshot(&self, name: &str) -> Option<SnapshotInfo> {
        self.lock().get(name).cloned()
    }

    pub fn get_default_snapshot(&self) -> Option<SnapshotInfo> {
        self.get_snapshot(DEFAULT_SNAPSHOT)
    }

    pub fn list_snapshots(&self) -> Vec<SnapshotInfo> {
        self.lock().values().cloned().collect()
    }
}

/// A snapshot directory needs both its `snapshot` and `mem` files.
pub fn validate_snapshot(path: &Path) -> bool {
    path.join("snapshot").exists() && path.join("mem").exists()
}

fn snapshot_size(path: &Path) -> u64 {
    ["snapshot", "mem"]
        .iter()
        .filter_map(|f| std::fs::metadata(path.join(f)).ok())
        .map(|m| m.len())
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    // Port of Zig `test "snapshot manager init"`: the type is usable across
    // threads, as the pool and launcher share it.
    #[test]
    fn snapshot_manager_init() {
        fn shareable<T: Send + Sync>() {}
        shareable::<SnapshotManager>();
    }

    // Port of Zig `test "snapshot manager init with temp dir"`.
    #[test]
    fn snapshot_manager_init_with_temp_dir() {
        let dir = tempfile::tempdir().unwrap();
        let mgr = SnapshotManager::new(dir.path()).unwrap();
        assert_eq!(mgr.base_path(), dir.path());
    }

    // Port of Zig `test "getSnapshot returns null for unknown name"`.
    #[test]
    fn get_snapshot_returns_none_for_unknown_name() {
        let dir = tempfile::tempdir().unwrap();
        let mgr = SnapshotManager::new(dir.path()).unwrap();
        assert!(mgr.get_snapshot("nonexistent-snapshot").is_none());
    }

    // Port of Zig `test "getDefaultSnapshot returns null when no base snapshot"`.
    #[test]
    fn get_default_snapshot_returns_none_without_base() {
        let dir = tempfile::tempdir().unwrap();
        let mgr = SnapshotManager::new(dir.path()).unwrap();
        assert!(mgr.get_default_snapshot().is_none());
    }

    // Port of Zig `test "listSnapshots returns empty for empty directory"`.
    #[test]
    fn list_snapshots_empty_for_empty_directory() {
        let dir = tempfile::tempdir().unwrap();
        let mgr = SnapshotManager::new(dir.path()).unwrap();
        assert!(mgr.list_snapshots().is_empty());
    }

    // Port of Zig `test "SnapshotInfo struct fields"`.
    #[test]
    fn snapshot_info_fields() {
        let info = SnapshotInfo {
            name: "test-snapshot".into(),
            path: "/tmp/test-snapshot".into(),
            created_at: 1_234_567_890,
            size_bytes: 1024,
        };
        assert_eq!(info.name, "test-snapshot");
        assert_eq!(info.size_bytes, 1024);
    }

    // Port of Zig `test "snapshot manager with valid snapshot directory"`.
    #[test]
    fn finds_valid_snapshot_directory() {
        let dir = tempfile::tempdir().unwrap();
        let snap = dir.path().join("test-snap");
        std::fs::create_dir(&snap).unwrap();
        std::fs::write(snap.join("snapshot"), "snapshot data content").unwrap();
        std::fs::write(snap.join("mem"), "memory data content here").unwrap();
        // A stray file at the top level is not a snapshot.
        std::fs::write(dir.path().join("README"), "x").unwrap();

        let mgr = SnapshotManager::new(dir.path()).unwrap();
        let info = mgr.get_snapshot("test-snap").unwrap();
        assert_eq!(info.name, "test-snap");
        assert_eq!(info.path, snap);
        assert_eq!(info.size_bytes, 21 + 24);
        assert_eq!(mgr.list_snapshots().len(), 1);
    }

    #[test]
    fn default_snapshot_is_base() {
        let dir = tempfile::tempdir().unwrap();
        let base = dir.path().join("base");
        std::fs::create_dir(&base).unwrap();
        std::fs::write(base.join("snapshot"), "s").unwrap();
        std::fs::write(base.join("mem"), "m").unwrap();
        let mgr = SnapshotManager::new(dir.path()).unwrap();
        assert_eq!(mgr.get_default_snapshot().unwrap().path, base);
    }

    // Port of Zig `test "snapshot manager creates directory when not found"`.
    #[test]
    fn creates_directory_when_not_found() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested").join("snapshots");
        let _mgr = SnapshotManager::new(&path).unwrap();
        assert!(path.is_dir());
        let _again = SnapshotManager::new(&path).unwrap();
    }

    // Port of Zig `test "validateSnapshot returns false for missing snapshot file"`.
    #[test]
    fn incomplete_snapshot_is_ignored() {
        let dir = tempfile::tempdir().unwrap();
        let snap = dir.path().join("incomplete");
        std::fs::create_dir(&snap).unwrap();
        std::fs::write(snap.join("mem"), "").unwrap();
        let mgr = SnapshotManager::new(dir.path()).unwrap();
        assert!(mgr.get_snapshot("incomplete").is_none());
        assert!(!validate_snapshot(&snap));
    }
}
