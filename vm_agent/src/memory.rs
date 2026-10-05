//! Byte-capped persistent iteration notes, matching the guest prompt contract.

use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
};

/// Byte-capped persistent notes and iteration summaries.
pub struct MemoryManager {
    /// Repository directory containing MEMORY.md and the iteration log.
    pub work_dir: PathBuf,
}

impl MemoryManager {
    /// Create a manager for a repository directory.
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            work_dir: path.into(),
        }
    }

    fn read_capped(path: &Path, cap: usize) -> Option<Vec<u8>> {
        let file = File::open(path).ok()?;
        let mut bytes = Vec::new();
        file.take(cap as u64 + 1).read_to_end(&mut bytes).ok()?;
        if bytes.is_empty() || bytes.len() > cap {
            None
        } else {
            Some(bytes)
        }
    }

    /// Read nonempty MEMORY.md content up to 256 KiB.
    pub fn read_memory(&self) -> Option<Vec<u8>> {
        Self::read_capped(&self.work_dir.join("MEMORY.md"), 256 * 1024)
    }

    /// Read a nonempty iteration log up to 128 KiB.
    pub fn read_iteration_log(&self) -> Option<Vec<u8>> {
        Self::read_capped(&self.work_dir.join(".marathon/iterations.log"), 128 * 1024)
    }

    /// Append the iteration status and a 2048-byte output summary.
    pub fn log_iteration(&self, iteration: u32, exit_code: i32, output: &[u8]) {
        let result = (|| -> std::io::Result<()> {
            fs::create_dir_all(self.work_dir.join(".marathon"))?;
            let mut file = OpenOptions::new()
                .create(true)
                .append(true)
                .open(self.work_dir.join(".marathon/iterations.log"))?;
            write!(
                file,
                "\n--- Iteration {iteration} (exit_code={exit_code}) ---\n"
            )?;
            file.write_all(&output[..output.len().min(2048)])?;
            file.write_all(b"\n")
        })();
        if let Err(error) = result {
            tracing::warn!(operation = "memory_log", %error, "Could not persist iteration summary");
        }
    }

    /// Build the next prompt prefix from notes and capped output.
    pub fn build_context_prefix(&self, iteration: u32, last_output: &[u8]) -> String {
        let mut out = format!(
            "# Context from previous iterations\n\nThis is iteration {iteration}. The previous iteration did not complete the task.\n\n"
        );
        if let Some(memory) = self.read_memory() {
            out.push_str("## MEMORY.md (persistent notes from previous iterations)\n\n");
            out.push_str(&String::from_utf8_lossy(
                &memory[..memory.len().min(32 * 1024)],
            ));
            out.push_str("\n\n");
        }
        if !last_output.is_empty() {
            out.push_str("## Last iteration output (summary)\n\n");
            let cap = last_output.len().min(4096);
            out.push_str(&String::from_utf8_lossy(&last_output[..cap]));
            if last_output.len() > cap {
                out.push_str("\n... (truncated)");
            }
            out.push_str("\n\n");
        }
        out.push_str("## Your task\n\nContinue working. If you need to persist information across iterations, write to MEMORY.md.\nWhen complete, output <promise>TASK_COMPLETE</promise> (or the configured completion promise).\nIf you need clarification, output <clarification>your question</clarification>.\n\n");
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_manager_init() {
        let tmp = tempfile::tempdir().unwrap();
        let m = MemoryManager::new(tmp.path());
        assert_eq!(m.work_dir, tmp.path());
    }

    #[test]
    fn read_memory_returns_null_for_missing_file() {
        let tmp = tempfile::tempdir().unwrap();
        assert!(MemoryManager::new(tmp.path()).read_memory().is_none());
    }

    #[test]
    fn build_context_prefix_produces_valid_output() {
        let tmp = tempfile::tempdir().unwrap();
        let p = MemoryManager::new(tmp.path()).build_context_prefix(2, b"Previous output here");
        assert!(p.contains("iteration 2"));
        assert!(p.contains("Previous output here"));
        assert!(p.contains("MEMORY.md"));
    }

    #[test]
    fn memory_caps_and_byte_boundaries() {
        let tmp = tempfile::tempdir().unwrap();
        let m = MemoryManager::new(tmp.path());
        fs::write(tmp.path().join("MEMORY.md"), b"").unwrap();
        assert!(m.read_memory().is_none());
        fs::write(tmp.path().join("MEMORY.md"), vec![b'x'; 256 * 1024 + 1]).unwrap();
        assert!(m.read_memory().is_none());
        let bytes = "é".repeat(20000).into_bytes();
        fs::write(tmp.path().join("MEMORY.md"), &bytes).unwrap();
        assert_eq!(m.read_memory().unwrap(), bytes);
        let output = [vec![b'a'; 4095], vec![0xc3, 0xa9]].concat();
        let p = m.build_context_prefix(3, &output);
        assert!(p.contains("\u{fffd}\n... (truncated)"));
        assert!(p.contains(&"é".repeat(16 * 1024)));
        m.log_iteration(1, -1, &vec![b'x'; 3000]);
        let log = m.read_iteration_log().unwrap();
        assert_eq!(
            log,
            [
                b"\n--- Iteration 1 (exit_code=-1) ---\n".as_slice(),
                &vec![b'x'; 2048],
                b"\n"
            ]
            .concat()
        );
        fs::write(
            tmp.path().join(".marathon/iterations.log"),
            vec![0; 128 * 1024 + 1],
        )
        .unwrap();
        assert!(m.read_iteration_log().is_none());
    }
}
