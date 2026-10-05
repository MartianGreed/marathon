//! Environment configuration for each binary.
//!
//! Defaults, variable names and parsing rules match the Zig
//! `common/src/config.zig`:
//! - a variable that is set (even to an empty string) overrides its default;
//! - numbers must parse as the field's integer type or loading fails;
//! - booleans are true only for exactly `true` or `1`;
//! - when `MARATHON_TLS_ENABLED` is not set, TLS is enabled for orchestrator
//!   port 443 (node operator and client).
//!
//! Each loader has a `from_env` that reads the process environment and a
//! `from_lookup` that takes any `Fn(&str) -> Option<String>`, which tests use
//! instead of mutating the process environment.

use std::collections::HashMap;
use std::fmt;
use std::io;
use std::path::{Path, PathBuf};

/// Environment variable names.
pub mod vars {
    pub const LISTEN_ADDRESS: &str = "MARATHON_LISTEN_ADDRESS";
    pub const LISTEN_PORT: &str = "MARATHON_LISTEN_PORT";
    pub const ANTHROPIC_API_KEY: &str = "MARATHON_ANTHROPIC_API_KEY";
    pub const REDIS_URL: &str = "MARATHON_REDIS_URL";
    pub const POSTGRES_URL: &str = "MARATHON_POSTGRES_URL";
    pub const NODE_AUTH_KEY: &str = "MARATHON_NODE_AUTH_KEY";
    pub const JWT_SECRET: &str = "MARATHON_JWT_SECRET";

    pub const NODE_ID: &str = "MARATHON_NODE_ID";
    pub const HOSTNAME: &str = "HOSTNAME";
    pub const ORCHESTRATOR_ADDRESS: &str = "MARATHON_ORCHESTRATOR_ADDRESS";
    pub const ORCHESTRATOR_PORT: &str = "MARATHON_ORCHESTRATOR_PORT";
    pub const TOTAL_VM_SLOTS: &str = "MARATHON_TOTAL_VM_SLOTS";
    pub const WARM_POOL_TARGET: &str = "MARATHON_WARM_POOL_TARGET";
    pub const SNAPSHOT_PATH: &str = "MARATHON_SNAPSHOT_PATH";
    pub const KERNEL_PATH: &str = "MARATHON_KERNEL_PATH";
    pub const ROOTFS_PATH: &str = "MARATHON_ROOTFS_PATH";
    pub const FIRECRACKER_BIN: &str = "MARATHON_FIRECRACKER_BIN";
    pub const TLS_ENABLED: &str = "MARATHON_TLS_ENABLED";
    pub const TLS_CA_PATH: &str = "MARATHON_TLS_CA_PATH";

    pub const VSOCK_PORT: &str = "MARATHON_VSOCK_PORT";
    pub const CLAUDE_CODE_PATH: &str = "MARATHON_CLAUDE_CODE_PATH";
    pub const WORK_DIR: &str = "MARATHON_WORK_DIR";
    pub const PROMPT_TEMPLATE: &str = "MARATHON_PROMPT_TEMPLATE";
    pub const CLEANUP_STRATEGY: &str = "MARATHON_CLEANUP_STRATEGY";

    pub const GITHUB_TOKEN: &str = "GITHUB_TOKEN";
}

/// Configuration that could not be loaded.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("{var}={value:?} is not a valid {expected}")]
    InvalidValue {
        var: &'static str,
        value: String,
        expected: &'static str,
    },
    #[error("failed to read {}: {source}", path.display())]
    DotEnv {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
}

/// Parse an unsigned decimal the way Zig's `std.fmt.parseInt(T, s, 10)`
/// (0.15) does:
/// - one optional leading `+` or `-`;
/// - ASCII digits, with `_` allowed anywhere except first or last;
/// - `-` is accepted only when the value is zero (`-0`, `-0_0`);
/// - no whitespace, no base prefix; overflow of `T` is an error.
pub fn parse_zig_unsigned<T: TryFrom<u64>>(s: &str) -> Option<T> {
    let (negative, digits) = match s.as_bytes().first()? {
        b'+' => (false, &s[1..]),
        b'-' => (true, &s[1..]),
        _ => (false, s),
    };
    let bytes = digits.as_bytes();
    if bytes.is_empty() || bytes[0] == b'_' || bytes[bytes.len() - 1] == b'_' {
        return None;
    }
    let mut value: u64 = 0;
    for &c in bytes {
        if c == b'_' {
            continue;
        }
        if !c.is_ascii_digit() {
            return None;
        }
        value = value.checked_mul(10)?.checked_add(u64::from(c - b'0'))?;
    }
    if negative && value != 0 {
        return None;
    }
    T::try_from(value).ok()
}

fn parse_num<T: TryFrom<u64>>(
    var: &'static str,
    value: String,
    expected: &'static str,
) -> Result<T, ConfigError> {
    parse_zig_unsigned(&value).ok_or(ConfigError::InvalidValue {
        var,
        value,
        expected,
    })
}

/// `true` only for exactly `true` or `1`, as in Zig.
fn parse_bool(value: &str) -> bool {
    value == "true" || value == "1"
}

fn process_env(name: &str) -> Option<String> {
    std::env::var_os(name).map(|v| v.to_string_lossy().into_owned())
}

const REDACTED: &str = "<redacted>";

fn redact(value: &Option<String>) -> Option<&'static str> {
    value.as_ref().map(|_| REDACTED)
}

/// Orchestrator settings.
#[derive(Clone, PartialEq)]
pub struct OrchestratorConfig {
    pub listen_address: String,
    pub listen_port: u16,
    pub node_timeout_ms: u64,
    pub heartbeat_interval_ms: u64,
    pub etcd_endpoints: Vec<String>,
    pub redis_url: String,
    pub postgres_url: String,
    pub anthropic_api_key: String,
    pub tls_cert_path: Option<String>,
    pub tls_key_path: Option<String>,
    pub node_auth_key: Option<String>,
    pub jwt_secret: Option<String>,
}

impl Default for OrchestratorConfig {
    fn default() -> Self {
        Self {
            listen_address: "0.0.0.0".into(),
            listen_port: 8080,
            node_timeout_ms: 30_000,
            heartbeat_interval_ms: 5_000,
            etcd_endpoints: vec!["localhost:2379".into()],
            redis_url: "redis://localhost:6379".into(),
            postgres_url: "postgresql://marathon:marathon@localhost:5432/marathon".into(),
            anthropic_api_key: String::new(),
            tls_cert_path: None,
            tls_key_path: None,
            node_auth_key: None,
            jwt_secret: None,
        }
    }
}

impl fmt::Debug for OrchestratorConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("OrchestratorConfig")
            .field("listen_address", &self.listen_address)
            .field("listen_port", &self.listen_port)
            .field("node_timeout_ms", &self.node_timeout_ms)
            .field("heartbeat_interval_ms", &self.heartbeat_interval_ms)
            .field("etcd_endpoints", &self.etcd_endpoints)
            .field("redis_url", &self.redis_url)
            .field("postgres_url", &REDACTED)
            .field(
                "anthropic_api_key",
                &if self.anthropic_api_key.is_empty() {
                    ""
                } else {
                    REDACTED
                },
            )
            .field("tls_cert_path", &self.tls_cert_path)
            .field("tls_key_path", &self.tls_key_path)
            .field("node_auth_key", &redact(&self.node_auth_key))
            .field("jwt_secret", &redact(&self.jwt_secret))
            .finish()
    }
}

impl OrchestratorConfig {
    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_lookup(process_env)
    }

    pub fn from_lookup(get: impl Fn(&str) -> Option<String>) -> Result<Self, ConfigError> {
        let mut c = Self::default();
        if let Some(v) = get(vars::LISTEN_ADDRESS) {
            c.listen_address = v;
        }
        if let Some(v) = get(vars::LISTEN_PORT) {
            c.listen_port = parse_num(vars::LISTEN_PORT, v, "port (u16)")?;
        }
        if let Some(v) = get(vars::ANTHROPIC_API_KEY) {
            c.anthropic_api_key = v;
        }
        if let Some(v) = get(vars::REDIS_URL) {
            c.redis_url = v;
        }
        if let Some(v) = get(vars::POSTGRES_URL) {
            c.postgres_url = v;
        }
        if let Some(v) = get(vars::NODE_AUTH_KEY) {
            c.node_auth_key = Some(v);
        }
        if let Some(v) = get(vars::JWT_SECRET) {
            c.jwt_secret = Some(v);
        }
        Ok(c)
    }
}

/// Node operator settings.
#[derive(Clone, PartialEq)]
pub struct NodeOperatorConfig {
    pub node_id: Option<String>,
    pub hostname: Option<String>,
    pub listen_address: String,
    pub listen_port: u16,
    pub orchestrator_address: String,
    pub orchestrator_port: u16,
    pub heartbeat_interval_ms: u64,
    pub total_vm_slots: u32,
    pub warm_pool_target: u32,
    pub firecracker_bin: String,
    pub jailer_bin: String,
    pub snapshot_path: String,
    pub rootfs_path: String,
    pub kernel_path: String,
    pub vsock_port: u32,
    pub task_timeout_ms: u64,
    pub max_tokens_per_task: u64,
    pub auth_key: Option<String>,
    pub tls_enabled: bool,
    pub tls_ca_path: Option<String>,
}

impl Default for NodeOperatorConfig {
    fn default() -> Self {
        Self {
            node_id: None,
            hostname: None,
            listen_address: "0.0.0.0".into(),
            listen_port: 8081,
            orchestrator_address: "127.0.0.1".into(),
            orchestrator_port: 8080,
            heartbeat_interval_ms: 5_000,
            total_vm_slots: 10,
            warm_pool_target: 5,
            firecracker_bin: "/usr/bin/firecracker".into(),
            jailer_bin: "/usr/bin/jailer".into(),
            snapshot_path: "/tmp/marathon/snapshots".into(),
            rootfs_path: "/tmp/marathon/rootfs/rootfs.ext4".into(),
            kernel_path: "/tmp/marathon/kernel/vmlinux".into(),
            vsock_port: 9999,
            task_timeout_ms: 600_000,
            max_tokens_per_task: 100_000,
            auth_key: None,
            tls_enabled: false,
            tls_ca_path: None,
        }
    }
}

impl fmt::Debug for NodeOperatorConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("NodeOperatorConfig")
            .field("node_id", &self.node_id)
            .field("hostname", &self.hostname)
            .field("listen_address", &self.listen_address)
            .field("listen_port", &self.listen_port)
            .field("orchestrator_address", &self.orchestrator_address)
            .field("orchestrator_port", &self.orchestrator_port)
            .field("heartbeat_interval_ms", &self.heartbeat_interval_ms)
            .field("total_vm_slots", &self.total_vm_slots)
            .field("warm_pool_target", &self.warm_pool_target)
            .field("firecracker_bin", &self.firecracker_bin)
            .field("jailer_bin", &self.jailer_bin)
            .field("snapshot_path", &self.snapshot_path)
            .field("rootfs_path", &self.rootfs_path)
            .field("kernel_path", &self.kernel_path)
            .field("vsock_port", &self.vsock_port)
            .field("task_timeout_ms", &self.task_timeout_ms)
            .field("max_tokens_per_task", &self.max_tokens_per_task)
            .field("auth_key", &redact(&self.auth_key))
            .field("tls_enabled", &self.tls_enabled)
            .field("tls_ca_path", &self.tls_ca_path)
            .finish()
    }
}

impl NodeOperatorConfig {
    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_lookup(process_env)
    }

    pub fn from_lookup(get: impl Fn(&str) -> Option<String>) -> Result<Self, ConfigError> {
        let mut c = Self::default();
        if let Some(v) = get(vars::NODE_ID) {
            c.node_id = Some(v);
        }
        if let Some(v) = get(vars::HOSTNAME) {
            c.hostname = Some(v);
        }
        if let Some(v) = get(vars::ORCHESTRATOR_ADDRESS) {
            c.orchestrator_address = v;
        }
        if let Some(v) = get(vars::ORCHESTRATOR_PORT) {
            c.orchestrator_port = parse_num(vars::ORCHESTRATOR_PORT, v, "port (u16)")?;
        }
        if let Some(v) = get(vars::TOTAL_VM_SLOTS) {
            c.total_vm_slots = parse_num(vars::TOTAL_VM_SLOTS, v, "count (u32)")?;
        }
        if let Some(v) = get(vars::WARM_POOL_TARGET) {
            c.warm_pool_target = parse_num(vars::WARM_POOL_TARGET, v, "count (u32)")?;
        }
        if let Some(v) = get(vars::SNAPSHOT_PATH) {
            c.snapshot_path = v;
        }
        if let Some(v) = get(vars::KERNEL_PATH) {
            c.kernel_path = v;
        }
        if let Some(v) = get(vars::ROOTFS_PATH) {
            c.rootfs_path = v;
        }
        if let Some(v) = get(vars::FIRECRACKER_BIN) {
            c.firecracker_bin = v;
        }
        if let Some(v) = get(vars::NODE_AUTH_KEY) {
            c.auth_key = Some(v);
        }
        if let Some(v) = get(vars::TLS_ENABLED) {
            c.tls_enabled = parse_bool(&v);
        } else if c.orchestrator_port == 443 {
            c.tls_enabled = true;
        }
        if let Some(v) = get(vars::TLS_CA_PATH) {
            c.tls_ca_path = Some(v);
        }
        Ok(c)
    }
}

/// VM agent settings.
#[derive(Debug, Clone, PartialEq)]
pub struct VmAgentConfig {
    pub vsock_port: u32,
    pub claude_code_path: String,
    pub work_dir: String,
    pub prompt_template: String,
    pub cleanup_strategy: String,
}

impl Default for VmAgentConfig {
    fn default() -> Self {
        Self {
            vsock_port: 9999,
            claude_code_path: "/usr/local/bin/claude".into(),
            work_dir: "/workspace".into(),
            prompt_template: "{prompt}".into(),
            cleanup_strategy: "full".into(),
        }
    }
}

impl VmAgentConfig {
    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_lookup(process_env)
    }

    pub fn from_lookup(get: impl Fn(&str) -> Option<String>) -> Result<Self, ConfigError> {
        let mut c = Self::default();
        if let Some(v) = get(vars::VSOCK_PORT) {
            c.vsock_port = parse_num(vars::VSOCK_PORT, v, "port (u32)")?;
        }
        if let Some(v) = get(vars::CLAUDE_CODE_PATH) {
            c.claude_code_path = v;
        }
        if let Some(v) = get(vars::WORK_DIR) {
            c.work_dir = v;
        }
        if let Some(v) = get(vars::PROMPT_TEMPLATE) {
            c.prompt_template = v;
        }
        if let Some(v) = get(vars::CLEANUP_STRATEGY) {
            c.cleanup_strategy = v;
        }
        Ok(c)
    }
}

/// `marathon` CLI settings.
///
/// Each variable comes from the process environment first, then from a
/// `.env` file in the current directory.
#[derive(Clone, PartialEq)]
pub struct ClientConfig {
    pub orchestrator_address: String,
    pub orchestrator_port: u16,
    pub github_token: Option<String>,
    pub tls_enabled: bool,
    pub tls_ca_path: Option<String>,
}

impl Default for ClientConfig {
    fn default() -> Self {
        Self {
            orchestrator_address: "127.0.0.1".into(),
            orchestrator_port: 8080,
            github_token: None,
            tls_enabled: false,
            tls_ca_path: None,
        }
    }
}

impl fmt::Debug for ClientConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ClientConfig")
            .field("orchestrator_address", &self.orchestrator_address)
            .field("orchestrator_port", &self.orchestrator_port)
            .field("github_token", &redact(&self.github_token))
            .field("tls_enabled", &self.tls_enabled)
            .field("tls_ca_path", &self.tls_ca_path)
            .finish()
    }
}

/// Name of the file the client reads from its working directory.
pub const CLIENT_DOTENV_FILE: &str = ".env";

impl ClientConfig {
    /// Process environment, then `./.env` if it exists.
    pub fn from_env() -> Result<Self, ConfigError> {
        let dotenv = DotEnv::load(CLIENT_DOTENV_FILE)?;
        Self::from_sources(process_env, dotenv.as_ref())
    }

    /// `env` takes precedence over `dotenv`.
    pub fn from_sources(
        env: impl Fn(&str) -> Option<String>,
        dotenv: Option<&DotEnv>,
    ) -> Result<Self, ConfigError> {
        let get =
            |name: &str| env(name).or_else(|| dotenv.and_then(|d| d.get(name).map(str::to_owned)));
        let mut c = Self::default();
        if let Some(v) = get(vars::ORCHESTRATOR_ADDRESS) {
            c.orchestrator_address = v;
        }
        if let Some(v) = get(vars::ORCHESTRATOR_PORT) {
            c.orchestrator_port = parse_num(vars::ORCHESTRATOR_PORT, v, "port (u16)")?;
        }
        match get(vars::TLS_ENABLED) {
            Some(v) => c.tls_enabled = parse_bool(&v),
            None => c.tls_enabled = c.orchestrator_port == 443,
        }
        if let Some(v) = get(vars::TLS_CA_PATH) {
            c.tls_ca_path = Some(v);
        }
        if let Some(v) = get(vars::GITHUB_TOKEN) {
            c.github_token = Some(v);
        }
        Ok(c)
    }
}

/// Largest `.env` file read, as in Zig.
pub const DOTENV_MAX_BYTES: u64 = 1024 * 1024;

/// A parsed `.env` file, with the Zig parser's rules:
/// - lines are split on `\n` and trimmed of spaces, tabs and `\r`;
/// - empty lines and lines starting with `#` are skipped;
/// - the key is the text before the first `=`, the value the text after it,
///   both trimmed of spaces and tabs; lines without `=` are skipped;
/// - one pair of matching surrounding `"` or `'` is removed from the value;
/// - a later duplicate key wins.
///
/// There is no `export` prefix, escape or interpolation support.
/// `Debug` lists the keys only, since values are often secrets.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct DotEnv {
    vars: HashMap<String, String>,
}

impl fmt::Debug for DotEnv {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut keys: Vec<&str> = self.vars.keys().map(String::as_str).collect();
        keys.sort_unstable();
        f.debug_struct("DotEnv").field("keys", &keys).finish()
    }
}

impl DotEnv {
    /// Read and parse `path`. `Ok(None)` when the file does not exist.
    pub fn load(path: impl AsRef<Path>) -> Result<Option<Self>, ConfigError> {
        let path = path.as_ref();
        let err = |source| ConfigError::DotEnv {
            path: path.to_path_buf(),
            source,
        };
        let meta = match std::fs::metadata(path) {
            Ok(meta) => meta,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(err(e)),
        };
        if meta.len() > DOTENV_MAX_BYTES {
            return Err(err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("file is larger than {DOTENV_MAX_BYTES} bytes"),
            )));
        }
        let content = std::fs::read_to_string(path).map_err(err)?;
        Ok(Some(Self::parse(&content)))
    }

    pub fn parse(content: &str) -> Self {
        let mut vars = HashMap::new();
        for line in content.split('\n') {
            let line = line.trim_matches([' ', '\t', '\r']);
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let key = key.trim_matches([' ', '\t']);
            let mut value = value.trim_matches([' ', '\t']);
            let b = value.as_bytes();
            if b.len() >= 2
                && ((b[0] == b'"' && b[b.len() - 1] == b'"')
                    || (b[0] == b'\'' && b[b.len() - 1] == b'\''))
            {
                value = &value[1..value.len() - 1];
            }
            vars.insert(key.to_owned(), value.to_owned());
        }
        Self { vars }
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        self.vars.get(key).map(String::as_str)
    }

    pub fn len(&self) -> usize {
        self.vars.len()
    }

    pub fn is_empty(&self) -> bool {
        self.vars.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> + use<> {
        let map: HashMap<String, String> = pairs
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect();
        move |k| map.get(k).cloned()
    }

    fn none(_: &str) -> Option<String> {
        None
    }

    // Port of config.zig "config defaults".
    #[test]
    fn orchestrator_defaults() {
        let c = OrchestratorConfig::from_lookup(none).unwrap();
        assert_eq!(c, OrchestratorConfig::default());
        assert_eq!(c.listen_port, 8080);
        assert_eq!(c.listen_address, "0.0.0.0");
        assert_eq!(c.node_timeout_ms, 30_000);
        assert_eq!(c.heartbeat_interval_ms, 5_000);
        assert_eq!(c.etcd_endpoints, vec!["localhost:2379".to_owned()]);
        assert_eq!(c.redis_url, "redis://localhost:6379");
        assert_eq!(
            c.postgres_url,
            "postgresql://marathon:marathon@localhost:5432/marathon"
        );
        assert_eq!(c.anthropic_api_key, "");
        assert_eq!(c.tls_cert_path, None);
        assert_eq!(c.tls_key_path, None);
        assert_eq!(c.node_auth_key, None);
        assert_eq!(c.jwt_secret, None);
    }

    #[test]
    fn orchestrator_every_variable() {
        let c = OrchestratorConfig::from_lookup(env(&[
            ("MARATHON_LISTEN_ADDRESS", "127.0.0.1"),
            ("MARATHON_LISTEN_PORT", "9090"),
            ("MARATHON_ANTHROPIC_API_KEY", "sk-ant"),
            ("MARATHON_REDIS_URL", "redis://r:1"),
            ("MARATHON_POSTGRES_URL", "postgresql://p"),
            ("MARATHON_NODE_AUTH_KEY", "nodekey"),
            ("MARATHON_JWT_SECRET", "jwt"),
        ]))
        .unwrap();
        assert_eq!(c.listen_address, "127.0.0.1");
        assert_eq!(c.listen_port, 9090);
        assert_eq!(c.anthropic_api_key, "sk-ant");
        assert_eq!(c.redis_url, "redis://r:1");
        assert_eq!(c.postgres_url, "postgresql://p");
        assert_eq!(c.node_auth_key.as_deref(), Some("nodekey"));
        assert_eq!(c.jwt_secret.as_deref(), Some("jwt"));
        // Not read from the environment.
        assert_eq!(c.node_timeout_ms, 30_000);
        assert_eq!(c.heartbeat_interval_ms, 5_000);
    }

    #[test]
    fn orchestrator_rejects_bad_port() {
        for bad in ["", "abc", "65536", "-1", " 80"] {
            let err =
                OrchestratorConfig::from_lookup(env(&[("MARATHON_LISTEN_PORT", bad)])).unwrap_err();
            assert!(
                matches!(
                    err,
                    ConfigError::InvalidValue {
                        var: "MARATHON_LISTEN_PORT",
                        ..
                    }
                ),
                "{bad:?}: {err}"
            );
        }
        let c = OrchestratorConfig::from_lookup(env(&[("MARATHON_LISTEN_PORT", "65535")])).unwrap();
        assert_eq!(c.listen_port, 65535);
    }

    #[test]
    fn orchestrator_debug_redacts_secrets() {
        let c = OrchestratorConfig::from_lookup(env(&[
            ("MARATHON_ANTHROPIC_API_KEY", "sk-ant-secret"),
            ("MARATHON_POSTGRES_URL", "postgresql://u:pw-secret@h/db"),
            ("MARATHON_NODE_AUTH_KEY", "node-secret"),
            ("MARATHON_JWT_SECRET", "jwt-secret"),
        ]))
        .unwrap();
        let debug = format!("{c:?}");
        for secret in ["sk-ant-secret", "pw-secret", "node-secret", "jwt-secret"] {
            assert!(!debug.contains(secret), "{debug}");
        }
    }

    #[test]
    fn node_operator_defaults() {
        let c = NodeOperatorConfig::from_lookup(none).unwrap();
        assert_eq!(c, NodeOperatorConfig::default());
        assert_eq!(c.node_id, None);
        assert_eq!(c.hostname, None);
        assert_eq!(c.listen_address, "0.0.0.0");
        assert_eq!(c.listen_port, 8081);
        assert_eq!(c.orchestrator_address, "127.0.0.1");
        assert_eq!(c.orchestrator_port, 8080);
        assert_eq!(c.heartbeat_interval_ms, 5_000);
        assert_eq!(c.total_vm_slots, 10);
        assert_eq!(c.warm_pool_target, 5);
        assert_eq!(c.firecracker_bin, "/usr/bin/firecracker");
        assert_eq!(c.jailer_bin, "/usr/bin/jailer");
        assert_eq!(c.snapshot_path, "/tmp/marathon/snapshots");
        assert_eq!(c.rootfs_path, "/tmp/marathon/rootfs/rootfs.ext4");
        assert_eq!(c.kernel_path, "/tmp/marathon/kernel/vmlinux");
        assert_eq!(c.vsock_port, 9999);
        assert_eq!(c.task_timeout_ms, 600_000);
        assert_eq!(c.max_tokens_per_task, 100_000);
        assert_eq!(c.auth_key, None);
        assert!(!c.tls_enabled);
        assert_eq!(c.tls_ca_path, None);
    }

    #[test]
    fn node_operator_every_variable() {
        let c = NodeOperatorConfig::from_lookup(env(&[
            ("MARATHON_NODE_ID", "node-1"),
            ("HOSTNAME", "host-a"),
            ("MARATHON_ORCHESTRATOR_ADDRESS", "orch.example"),
            ("MARATHON_ORCHESTRATOR_PORT", "9443"),
            ("MARATHON_TOTAL_VM_SLOTS", "32"),
            ("MARATHON_WARM_POOL_TARGET", "7"),
            ("MARATHON_SNAPSHOT_PATH", "/s"),
            ("MARATHON_KERNEL_PATH", "/k"),
            ("MARATHON_ROOTFS_PATH", "/r"),
            ("MARATHON_FIRECRACKER_BIN", "/fc"),
            ("MARATHON_NODE_AUTH_KEY", "nodekey"),
            ("MARATHON_TLS_ENABLED", "1"),
            ("MARATHON_TLS_CA_PATH", "/ca.pem"),
        ]))
        .unwrap();
        assert_eq!(c.node_id.as_deref(), Some("node-1"));
        assert_eq!(c.hostname.as_deref(), Some("host-a"));
        assert_eq!(c.orchestrator_address, "orch.example");
        assert_eq!(c.orchestrator_port, 9443);
        assert_eq!(c.total_vm_slots, 32);
        assert_eq!(c.warm_pool_target, 7);
        assert_eq!(c.snapshot_path, "/s");
        assert_eq!(c.kernel_path, "/k");
        assert_eq!(c.rootfs_path, "/r");
        assert_eq!(c.firecracker_bin, "/fc");
        assert_eq!(c.auth_key.as_deref(), Some("nodekey"));
        assert!(c.tls_enabled);
        assert_eq!(c.tls_ca_path.as_deref(), Some("/ca.pem"));
        // Not read from the environment.
        assert_eq!(c.jailer_bin, "/usr/bin/jailer");
        assert_eq!(c.vsock_port, 9999);
        assert_eq!(c.listen_port, 8081);
    }

    #[test]
    fn node_operator_tls_rules() {
        let tls = |pairs: &[(&str, &str)]| {
            NodeOperatorConfig::from_lookup(env(pairs))
                .unwrap()
                .tls_enabled
        };
        assert!(!tls(&[]));
        assert!(tls(&[("MARATHON_ORCHESTRATOR_PORT", "443")]));
        assert!(tls(&[("MARATHON_TLS_ENABLED", "true")]));
        assert!(tls(&[("MARATHON_TLS_ENABLED", "1")]));
        for off in ["false", "0", "TRUE", "yes", ""] {
            assert!(!tls(&[("MARATHON_TLS_ENABLED", off)]), "{off:?}");
            // An explicit value wins over the port 443 default.
            assert!(
                !tls(&[
                    ("MARATHON_TLS_ENABLED", off),
                    ("MARATHON_ORCHESTRATOR_PORT", "443")
                ]),
                "{off:?}"
            );
        }
    }

    #[test]
    fn node_operator_rejects_bad_numbers() {
        for (var, value) in [
            ("MARATHON_ORCHESTRATOR_PORT", "70000"),
            ("MARATHON_TOTAL_VM_SLOTS", "ten"),
            ("MARATHON_WARM_POOL_TARGET", "-5"),
        ] {
            let err = NodeOperatorConfig::from_lookup(env(&[(var, value)])).unwrap_err();
            match err {
                ConfigError::InvalidValue { var: got, .. } => assert_eq!(got, var),
                other => panic!("{other}"),
            }
        }
    }

    #[test]
    fn node_operator_debug_redacts_key() {
        let c = NodeOperatorConfig::from_lookup(env(&[("MARATHON_NODE_AUTH_KEY", "node-secret")]))
            .unwrap();
        assert!(!format!("{c:?}").contains("node-secret"));
    }

    #[test]
    fn vm_agent_defaults() {
        let c = VmAgentConfig::from_lookup(none).unwrap();
        assert_eq!(c, VmAgentConfig::default());
        assert_eq!(c.vsock_port, 9999);
        assert_eq!(c.claude_code_path, "/usr/local/bin/claude");
        assert_eq!(c.work_dir, "/workspace");
        assert_eq!(c.prompt_template, "{prompt}");
        assert_eq!(c.cleanup_strategy, "full");
    }

    #[test]
    fn vm_agent_every_variable() {
        let c = VmAgentConfig::from_lookup(env(&[
            ("MARATHON_VSOCK_PORT", "5000"),
            ("MARATHON_CLAUDE_CODE_PATH", "/bin/claude"),
            ("MARATHON_WORK_DIR", "/w"),
            ("MARATHON_PROMPT_TEMPLATE", "do {prompt}"),
            ("MARATHON_CLEANUP_STRATEGY", "none"),
        ]))
        .unwrap();
        assert_eq!(c.vsock_port, 5000);
        assert_eq!(c.claude_code_path, "/bin/claude");
        assert_eq!(c.work_dir, "/w");
        assert_eq!(c.prompt_template, "do {prompt}");
        assert_eq!(c.cleanup_strategy, "none");

        let err =
            VmAgentConfig::from_lookup(env(&[("MARATHON_VSOCK_PORT", "4294967296")])).unwrap_err();
        assert!(matches!(
            err,
            ConfigError::InvalidValue {
                var: "MARATHON_VSOCK_PORT",
                ..
            }
        ));
    }

    #[test]
    fn client_defaults() {
        let c = ClientConfig::from_sources(none, None).unwrap();
        assert_eq!(c, ClientConfig::default());
        assert_eq!(c.orchestrator_address, "127.0.0.1");
        assert_eq!(c.orchestrator_port, 8080);
        assert_eq!(c.github_token, None);
        assert!(!c.tls_enabled);
        assert_eq!(c.tls_ca_path, None);
    }

    #[test]
    fn client_every_variable_from_env() {
        let c = ClientConfig::from_sources(
            env(&[
                ("MARATHON_ORCHESTRATOR_ADDRESS", "orch.example"),
                ("MARATHON_ORCHESTRATOR_PORT", "9000"),
                ("MARATHON_TLS_ENABLED", "true"),
                ("MARATHON_TLS_CA_PATH", "/ca.pem"),
                ("GITHUB_TOKEN", "ghp_env"),
            ]),
            None,
        )
        .unwrap();
        assert_eq!(c.orchestrator_address, "orch.example");
        assert_eq!(c.orchestrator_port, 9000);
        assert!(c.tls_enabled);
        assert_eq!(c.tls_ca_path.as_deref(), Some("/ca.pem"));
        assert_eq!(c.github_token.as_deref(), Some("ghp_env"));
        assert!(!format!("{c:?}").contains("ghp_env"));
    }

    #[test]
    fn client_every_variable_from_dotenv() {
        let dotenv = DotEnv::parse(
            "MARATHON_ORCHESTRATOR_ADDRESS=dot.example\n\
             MARATHON_ORCHESTRATOR_PORT=7000\n\
             MARATHON_TLS_ENABLED=1\n\
             MARATHON_TLS_CA_PATH=/dot-ca.pem\n\
             GITHUB_TOKEN=ghp_dot\n",
        );
        let c = ClientConfig::from_sources(none, Some(&dotenv)).unwrap();
        assert_eq!(c.orchestrator_address, "dot.example");
        assert_eq!(c.orchestrator_port, 7000);
        assert!(c.tls_enabled);
        assert_eq!(c.tls_ca_path.as_deref(), Some("/dot-ca.pem"));
        assert_eq!(c.github_token.as_deref(), Some("ghp_dot"));
    }

    #[test]
    fn client_env_overrides_dotenv() {
        let dotenv = DotEnv::parse(
            "MARATHON_ORCHESTRATOR_ADDRESS=dot.example\nGITHUB_TOKEN=ghp_dot\nMARATHON_ORCHESTRATOR_PORT=7000\n",
        );
        let c = ClientConfig::from_sources(
            env(&[
                ("MARATHON_ORCHESTRATOR_ADDRESS", "env.example"),
                ("GITHUB_TOKEN", "ghp_env"),
            ]),
            Some(&dotenv),
        )
        .unwrap();
        assert_eq!(c.orchestrator_address, "env.example");
        assert_eq!(c.github_token.as_deref(), Some("ghp_env"));
        assert_eq!(c.orchestrator_port, 7000);
    }

    #[test]
    fn client_tls_rules() {
        let tls = |e: &[(&str, &str)], d: &str| {
            let dotenv = DotEnv::parse(d);
            ClientConfig::from_sources(env(e), Some(&dotenv))
                .unwrap()
                .tls_enabled
        };
        assert!(!tls(&[], ""));
        assert!(tls(&[("MARATHON_ORCHESTRATOR_PORT", "443")], ""));
        assert!(tls(&[], "MARATHON_ORCHESTRATOR_PORT=443"));
        // Explicit false, in either source, disables the 443 default.
        assert!(!tls(
            &[
                ("MARATHON_ORCHESTRATOR_PORT", "443"),
                ("MARATHON_TLS_ENABLED", "false")
            ],
            ""
        ));
        assert!(!tls(
            &[("MARATHON_ORCHESTRATOR_PORT", "443")],
            "MARATHON_TLS_ENABLED=false"
        ));
        // The environment wins over the file.
        assert!(tls(
            &[("MARATHON_TLS_ENABLED", "true")],
            "MARATHON_TLS_ENABLED=false"
        ));
        assert!(!tls(
            &[("MARATHON_TLS_ENABLED", "0")],
            "MARATHON_TLS_ENABLED=1"
        ));
    }

    #[test]
    fn client_rejects_bad_port_from_dotenv() {
        let dotenv = DotEnv::parse("MARATHON_ORCHESTRATOR_PORT=http\n");
        let err = ClientConfig::from_sources(none, Some(&dotenv)).unwrap_err();
        assert!(matches!(
            err,
            ConfigError::InvalidValue {
                var: "MARATHON_ORCHESTRATOR_PORT",
                ..
            }
        ));
    }

    /// Cases checked against Zig 0.15.2 `std.fmt.parseInt(T, s, 10)`.
    #[test]
    fn zig_integer_rules() {
        let ok_u16: &[(&str, u16)] = &[
            ("8080", 8080),
            ("+8080", 8080),
            ("8_080", 8080),
            ("8__0_80", 8080),
            ("007", 7),
            ("0", 0),
            ("-0", 0),
            ("+0", 0),
            ("-0_0", 0),
            ("-000", 0),
            ("65535", 65535),
            ("6_5_5_3_5", 65535),
        ];
        for &(s, want) in ok_u16 {
            assert_eq!(parse_zig_unsigned::<u16>(s), Some(want), "{s:?}");
        }
        let bad_u16 = [
            "", "+", "-", "_8080", "8080_", "+_1", "-_0", "_", "-1", "-01", "-0_1", "65536", " 1",
            "1 ", "\t1", "0x10", "1e3", "1.0", "1,0", "٣", "++1", "+-1",
        ];
        for s in bad_u16 {
            assert_eq!(parse_zig_unsigned::<u16>(s), None, "{s:?}");
        }
        assert_eq!(parse_zig_unsigned::<u32>("4294967295"), Some(u32::MAX));
        assert_eq!(parse_zig_unsigned::<u32>("4294967296"), None);
        assert_eq!(
            parse_zig_unsigned::<u64>("18446744073709551615"),
            Some(u64::MAX)
        );
        assert_eq!(parse_zig_unsigned::<u64>("18446744073709551616"), None);
        assert_eq!(parse_zig_unsigned::<u64>("99999999999999999999999"), None);
    }

    #[test]
    fn loaders_use_zig_integer_rules() {
        let c = OrchestratorConfig::from_lookup(env(&[("MARATHON_LISTEN_PORT", "8_081")])).unwrap();
        assert_eq!(c.listen_port, 8081);
        let c = NodeOperatorConfig::from_lookup(env(&[
            ("MARATHON_WARM_POOL_TARGET", "-0"),
            ("MARATHON_TOTAL_VM_SLOTS", "+1_6"),
            ("MARATHON_ORCHESTRATOR_PORT", "4_43"),
        ]))
        .unwrap();
        assert_eq!(c.warm_pool_target, 0);
        assert_eq!(c.total_vm_slots, 16);
        assert_eq!(c.orchestrator_port, 443);
        assert!(c.tls_enabled);
        let c = VmAgentConfig::from_lookup(env(&[("MARATHON_VSOCK_PORT", "+9_999")])).unwrap();
        assert_eq!(c.vsock_port, 9999);
        let dotenv = DotEnv::parse("MARATHON_ORCHESTRATOR_PORT=4_43\n");
        let c = ClientConfig::from_sources(none, Some(&dotenv)).unwrap();
        assert_eq!(c.orchestrator_port, 443);
        assert!(c.tls_enabled);
    }

    #[test]
    fn dotenv_debug_hides_values() {
        let d = DotEnv::parse("GITHUB_TOKEN=ghp_dotenv_secret\nB=1\n");
        let debug = format!("{d:?}");
        assert!(!debug.contains("ghp_dotenv_secret"), "{debug}");
        assert!(debug.contains("GITHUB_TOKEN"), "{debug}");
    }

    #[test]
    fn dotenv_parsing_rules() {
        let d = DotEnv::parse(
            "# comment\n\
             \n\
             PLAIN=value\n\
             \t SPACED \t=\t spaced value \t\r\n\
             DQ=\"double quoted\"\n\
             SQ='single quoted'\n\
             MIXED=\"mismatch'\n\
             ONE=\"\n\
             EMPTY=\n\
             EQ=a=b=c\n\
             NOEQUALS\n\
             #HIDDEN=1\n\
             DUP=first\n\
             DUP=second\n\
             export EXP=1\n\
             INNER=\"keep \"inner\" quotes\"",
        );
        assert_eq!(d.get("PLAIN"), Some("value"));
        assert_eq!(d.get("SPACED"), Some("spaced value"));
        assert_eq!(d.get("DQ"), Some("double quoted"));
        assert_eq!(d.get("SQ"), Some("single quoted"));
        assert_eq!(d.get("MIXED"), Some("\"mismatch'"));
        assert_eq!(d.get("ONE"), Some("\""));
        assert_eq!(d.get("EMPTY"), Some(""));
        assert_eq!(d.get("EQ"), Some("a=b=c"));
        assert_eq!(d.get("NOEQUALS"), None);
        assert_eq!(d.get("#HIDDEN"), None);
        assert_eq!(d.get("HIDDEN"), None);
        assert_eq!(d.get("DUP"), Some("second"));
        assert_eq!(d.get("export EXP"), Some("1"));
        assert_eq!(d.get("EXP"), None);
        assert_eq!(d.get("INNER"), Some("keep \"inner\" quotes"));
        assert_eq!(d.len(), 11);
    }

    #[test]
    fn dotenv_load_missing_is_none() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(DotEnv::load(dir.path().join(".env")).unwrap(), None);
    }

    #[test]
    fn dotenv_load_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(".env");
        std::fs::write(&path, "GITHUB_TOKEN='ghp_file'\n").unwrap();
        let d = DotEnv::load(&path).unwrap().unwrap();
        assert_eq!(d.get("GITHUB_TOKEN"), Some("ghp_file"));
    }

    #[test]
    fn dotenv_load_rejects_oversized_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(".env");
        std::fs::write(&path, vec![b'#'; DOTENV_MAX_BYTES as usize + 1]).unwrap();
        assert!(matches!(
            DotEnv::load(&path),
            Err(ConfigError::DotEnv { .. })
        ));
        std::fs::write(&path, vec![b'#'; DOTENV_MAX_BYTES as usize]).unwrap();
        assert!(DotEnv::load(&path).unwrap().unwrap().is_empty());
    }

    #[test]
    fn dotenv_load_directory_is_error() {
        let dir = tempfile::tempdir().unwrap();
        assert!(matches!(
            DotEnv::load(dir.path()),
            Err(ConfigError::DotEnv { .. })
        ));
    }
}
