//! Firecracker HTTP API over its Unix socket.
//!
//! Request bodies are byte-for-byte what the Zig implementation formatted
//! (same keys, order, no whitespace), with JSON string escaping added. Each
//! call opens a new connection, sends one HTTP/1.1 request with
//! `Connection: close`, and succeeds on a `2xx` status line.

use std::path::Path;
use std::time::{Duration, Instant};

use serde::Serialize;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

use crate::metrics;

/// Kernel command line; the VM index is appended.
pub const BOOT_ARGS_PREFIX: &str = "console=ttyS0 reboot=k panic=1 pci=off marathon.vm_index=";
/// Body of `PUT /actions` that boots the VM.
pub const INSTANCE_START_BODY: &str = r#"{"action_type":"InstanceStart"}"#;
/// Largest request the client sends (the Zig request buffer size).
pub const MAX_REQUEST_LEN: usize = 8192;
/// Largest response header block accepted.
pub const MAX_RESPONSE_HEADER_LEN: usize = 16 * 1024;
/// Longest error body kept for the log.
pub const MAX_LOGGED_ERROR_BODY: usize = 511;
/// Default time limit for one API call.
pub const DEFAULT_CALL_TIMEOUT: Duration = Duration::from_secs(10);

/// A Firecracker API call failed.
#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    #[error("failed to connect to Firecracker socket {path}: {source}")]
    Connect {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("Firecracker request of {0} bytes is too large")]
    RequestTooLarge(usize),
    #[error("failed to send request to Firecracker: {0}")]
    Request(#[source] std::io::Error),
    #[error("failed to read response from Firecracker: {0}")]
    Response(#[source] std::io::Error),
    #[error("Firecracker closed the connection without a response")]
    EmptyResponse,
    #[error("Firecracker response headers are malformed or too large")]
    MalformedResponse,
    #[error("Firecracker API call timed out")]
    Timeout,
    #[error("Firecracker API {method} {endpoint} failed: {status}: {body}")]
    Failed {
        method: String,
        endpoint: String,
        status: String,
        body: String,
    },
}

fn json<T: Serialize>(value: &T) -> String {
    // Plain structs of strings, integers and booleans always serialize.
    serde_json::to_string(value).expect("Firecracker request bodies serialize")
}

#[derive(Serialize)]
struct BootSource<'a> {
    kernel_image_path: &'a str,
    boot_args: String,
}

/// `PUT /boot-source`.
pub fn boot_source_body(kernel_path: &str, vm_index: u32) -> String {
    json(&BootSource {
        kernel_image_path: kernel_path,
        boot_args: format!("{BOOT_ARGS_PREFIX}{vm_index}"),
    })
}

#[derive(Serialize)]
struct Drive<'a> {
    drive_id: &'a str,
    path_on_host: &'a str,
    is_root_device: bool,
    is_read_only: bool,
}

/// `PUT /drives/rootfs`: the VM's own writable rootfs copy.
pub fn rootfs_drive_body(path_on_host: &str) -> String {
    json(&Drive {
        drive_id: "rootfs",
        path_on_host,
        is_root_device: true,
        is_read_only: false,
    })
}

#[derive(Serialize)]
struct Vsock<'a> {
    vsock_id: &'a str,
    guest_cid: u32,
    uds_path: &'a str,
}

/// `PUT /vsock`.
pub fn vsock_body(guest_cid: u32, uds_path: &str) -> String {
    json(&Vsock {
        vsock_id: "vsock0",
        guest_cid,
        uds_path,
    })
}

#[derive(Serialize)]
struct NetworkInterface<'a> {
    iface_id: &'a str,
    guest_mac: &'a str,
    host_dev_name: &'a str,
}

/// `PUT /network-interfaces/eth0`.
pub fn network_interface_body(guest_mac: &str, host_dev_name: &str) -> String {
    json(&NetworkInterface {
        iface_id: "eth0",
        guest_mac,
        host_dev_name,
    })
}

#[derive(Serialize)]
struct MachineConfig {
    vcpu_count: u32,
    mem_size_mib: u32,
}

/// `PUT /machine-config`.
pub fn machine_config_body(vcpu_count: u32, mem_size_mib: u32) -> String {
    json(&MachineConfig {
        vcpu_count,
        mem_size_mib,
    })
}

#[derive(Serialize)]
struct SnapshotLoad<'a> {
    snapshot_path: &'a str,
    mem_file_path: &'a str,
    resume_vm: bool,
}

/// `PUT /snapshot/load` for the snapshot directory `dir` (files `snapshot`
/// and `mem`).
pub fn snapshot_load_body(dir: &str) -> String {
    json(&SnapshotLoad {
        snapshot_path: &format!("{dir}/snapshot"),
        mem_file_path: &format!("{dir}/mem"),
        resume_vm: true,
    })
}

/// The raw HTTP request, formatted as the Zig client did.
pub fn build_request(method: &str, endpoint: &str, body: &str) -> String {
    format!(
        "{method} {endpoint} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}

/// Send one request to the Firecracker API at `socket_path`.
pub async fn call(
    socket_path: &Path,
    method: &str,
    endpoint: &str,
    body: &str,
) -> Result<(), ApiError> {
    call_with_timeout(socket_path, method, endpoint, body, DEFAULT_CALL_TIMEOUT).await
}

/// [`call`] with an explicit time limit.
pub async fn call_with_timeout(
    socket_path: &Path,
    method: &str,
    endpoint: &str,
    body: &str,
    timeout: Duration,
) -> Result<(), ApiError> {
    let m = metrics::global();
    m.firecracker_api_calls.inc();
    let started = Instant::now();
    let result = match tokio::time::timeout(
        timeout,
        call_inner(socket_path, method, endpoint, body),
    )
    .await
    {
        Ok(r) => r,
        Err(_) => Err(ApiError::Timeout),
    };
    let elapsed = started.elapsed();
    m.firecracker_api_ms.observe(elapsed);
    let duration_ms = u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX);
    m.firecracker_api.inc(endpoint, api_status(&result));
    match &result {
        Ok(()) => tracing::debug!(
            operation = "firecracker_api",
                node_id = %crate::identity::label(),
            method,
            endpoint,
            duration_ms,
            "Firecracker API call succeeded"
        ),
        Err(e) => {
            m.firecracker_api_errors.inc();
            tracing::error!(
                operation = "firecracker_api",
                node_id = %crate::identity::label(),
                method,
                endpoint,
                socket = %socket_path.display(),
                duration_ms,
                error = %e,
                "Firecracker API call failed"
            );
        }
    }
    result
}

/// Metric label for an API call outcome.
fn api_status(result: &Result<(), ApiError>) -> &'static str {
    match result {
        Ok(()) => "ok",
        Err(ApiError::Connect { .. }) => "connect_error",
        Err(ApiError::RequestTooLarge(_)) => "request_too_large",
        Err(ApiError::Request(_) | ApiError::Response(_)) => "io_error",
        Err(ApiError::EmptyResponse | ApiError::MalformedResponse) => "bad_response",
        Err(ApiError::Timeout) => "timeout",
        Err(ApiError::Failed { .. }) => "rejected",
    }
}

async fn call_inner(
    socket_path: &Path,
    method: &str,
    endpoint: &str,
    body: &str,
) -> Result<(), ApiError> {
    let request = build_request(method, endpoint, body);
    if request.len() > MAX_REQUEST_LEN {
        return Err(ApiError::RequestTooLarge(request.len()));
    }
    let mut stream =
        UnixStream::connect(socket_path)
            .await
            .map_err(|source| ApiError::Connect {
                path: socket_path.display().to_string(),
                source,
            })?;
    stream
        .write_all(request.as_bytes())
        .await
        .map_err(ApiError::Request)?;
    stream.flush().await.map_err(ApiError::Request)?;

    // Read up to the end of the headers.
    let mut buf = Vec::with_capacity(1024);
    let header_end = loop {
        if let Some(pos) = find(&buf, b"\r\n\r\n") {
            break Some(pos);
        }
        if buf.len() > MAX_RESPONSE_HEADER_LEN {
            return Err(ApiError::MalformedResponse);
        }
        let mut chunk = [0u8; 1024];
        let n = stream.read(&mut chunk).await.map_err(ApiError::Response)?;
        if n == 0 {
            break None;
        }
        buf.extend_from_slice(&chunk[..n]);
    };
    if buf.is_empty() {
        return Err(ApiError::EmptyResponse);
    }
    let status_line = buf
        .split(|&b| b == b'\r' || b == b'\n')
        .next()
        .map(|l| String::from_utf8_lossy(l).into_owned())
        .unwrap_or_default();
    if status_line.starts_with("HTTP/1.1 2") || status_line.starts_with("HTTP/1.0 2") {
        return Ok(());
    }

    // Error: collect the body (Firecracker's `fault_message`) for the log.
    let mut body_bytes = match header_end {
        Some(pos) => buf[pos + 4..].to_vec(),
        None => Vec::new(),
    };
    if header_end.is_some() {
        let want = content_length(&buf[..header_end.unwrap_or(0)]).unwrap_or(0);
        let want = want.min(MAX_LOGGED_ERROR_BODY);
        while body_bytes.len() < want {
            let mut chunk = [0u8; 512];
            match stream.read(&mut chunk).await {
                Ok(0) | Err(_) => break,
                Ok(n) => body_bytes.extend_from_slice(&chunk[..n]),
            }
        }
    }
    body_bytes.truncate(MAX_LOGGED_ERROR_BODY);
    Err(ApiError::Failed {
        method: method.to_string(),
        endpoint: endpoint.to_string(),
        status: status_line,
        body: String::from_utf8_lossy(&body_bytes).into_owned(),
    })
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn content_length(headers: &[u8]) -> Option<usize> {
    String::from_utf8_lossy(headers).lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        if name.trim().eq_ignore_ascii_case("content-length") {
            value.trim().parse().ok()
        } else {
            None
        }
    })
}

#[cfg(test)]
pub(crate) mod fake {
    //! A fake Firecracker API server on a Unix socket that records requests.

    use std::path::Path;
    use std::sync::{Arc, Mutex};

    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::UnixListener;

    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct Recorded {
        pub method: String,
        pub path: String,
        pub headers: Vec<(String, String)>,
        pub body: String,
        pub raw: String,
    }

    pub struct FakeApi {
        pub requests: Arc<Mutex<Vec<Recorded>>>,
        task: tokio::task::JoinHandle<()>,
    }

    impl Drop for FakeApi {
        fn drop(&mut self) {
            self.task.abort();
        }
    }

    impl FakeApi {
        /// Serve on `socket`; `respond(path)` gives the raw HTTP response.
        pub fn start(
            socket: &Path,
            respond: impl Fn(&str) -> String + Send + Sync + 'static,
        ) -> Self {
            let listener = UnixListener::bind(socket).unwrap();
            let requests = Arc::new(Mutex::new(Vec::new()));
            let recorded = requests.clone();
            let task = tokio::spawn(async move {
                loop {
                    let Ok((mut s, _)) = listener.accept().await else {
                        return;
                    };
                    let mut buf = Vec::new();
                    // Read headers, then Content-Length bytes of body.
                    let (head_end, len) = loop {
                        let mut chunk = [0u8; 4096];
                        let n = s.read(&mut chunk).await.unwrap();
                        if n == 0 {
                            break (buf.len(), 0);
                        }
                        buf.extend_from_slice(&chunk[..n]);
                        if let Some(pos) = super::find(&buf, b"\r\n\r\n") {
                            let len = super::content_length(&buf[..pos]).unwrap_or(0);
                            break (pos + 4, len);
                        }
                    };
                    while buf.len() < head_end + len {
                        let mut chunk = [0u8; 4096];
                        let n = s.read(&mut chunk).await.unwrap();
                        if n == 0 {
                            break;
                        }
                        buf.extend_from_slice(&chunk[..n]);
                    }
                    let raw = String::from_utf8_lossy(&buf).into_owned();
                    let head = &raw[..head_end.saturating_sub(4)];
                    let mut lines = head.split("\r\n");
                    let mut first = lines.next().unwrap_or("").split(' ');
                    let method = first.next().unwrap_or("").to_string();
                    let path = first.next().unwrap_or("").to_string();
                    let headers = lines
                        .filter_map(|l| l.split_once(": "))
                        .map(|(k, v)| (k.to_string(), v.to_string()))
                        .collect();
                    let body = raw[head_end..].to_string();
                    let response = respond(&path);
                    recorded.lock().unwrap().push(Recorded {
                        method,
                        path,
                        headers,
                        body,
                        raw,
                    });
                    let _ = s.write_all(response.as_bytes()).await;
                    let _ = s.shutdown().await;
                }
            });
            Self { requests, task }
        }

        pub fn ok(socket: &Path) -> Self {
            Self::start(socket, |_| "HTTP/1.1 204 No Content\r\n\r\n".to_string())
        }

        pub fn recorded(&self) -> Vec<Recorded> {
            self.requests.lock().unwrap().clone()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fake::FakeApi;
    use super::*;

    // Golden bodies: the exact strings the Zig `bufPrint` formats in
    // `vm/firecracker.zig` produce for these inputs.
    #[test]
    fn golden_boot_source() {
        assert_eq!(
            boot_source_body("/tmp/marathon/kernel/vmlinux", 3),
            r#"{"kernel_image_path":"/tmp/marathon/kernel/vmlinux","boot_args":"console=ttyS0 reboot=k panic=1 pci=off marathon.vm_index=3"}"#
        );
    }

    #[test]
    fn golden_rootfs_drive() {
        assert_eq!(
            rootfs_drive_body("/tmp/marathon/rootfs/rootfs.ext4.0123456789abcdef0123456789abcdef"),
            r#"{"drive_id":"rootfs","path_on_host":"/tmp/marathon/rootfs/rootfs.ext4.0123456789abcdef0123456789abcdef","is_root_device":true,"is_read_only":false}"#
        );
    }

    #[test]
    fn golden_vsock() {
        assert_eq!(
            vsock_body(1234567, "/run/marathon/firecracker-ab-vsock.sock"),
            r#"{"vsock_id":"vsock0","guest_cid":1234567,"uds_path":"/run/marathon/firecracker-ab-vsock.sock"}"#
        );
    }

    #[test]
    fn golden_network_interface() {
        assert_eq!(
            network_interface_body("AA:FC:00:00:00:2A", "tap42"),
            r#"{"iface_id":"eth0","guest_mac":"AA:FC:00:00:00:2A","host_dev_name":"tap42"}"#
        );
    }

    #[test]
    fn golden_machine_config() {
        assert_eq!(
            machine_config_body(2, 512),
            r#"{"vcpu_count":2,"mem_size_mib":512}"#
        );
    }

    #[test]
    fn golden_instance_start() {
        assert_eq!(INSTANCE_START_BODY, r#"{"action_type":"InstanceStart"}"#);
    }

    #[test]
    fn golden_snapshot_load() {
        assert_eq!(
            snapshot_load_body("/tmp/marathon/snapshots/base"),
            r#"{"snapshot_path":"/tmp/marathon/snapshots/base/snapshot","mem_file_path":"/tmp/marathon/snapshots/base/mem","resume_vm":true}"#
        );
    }

    #[test]
    fn golden_request_framing() {
        assert_eq!(
            build_request("PUT", "/actions", INSTANCE_START_BODY),
            "PUT /actions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 31\r\nConnection: close\r\n\r\n{\"action_type\":\"InstanceStart\"}"
        );
    }

    #[test]
    fn bodies_escape_json_strings() {
        // Zig wrote these raw, producing invalid JSON; the port escapes them.
        let body = rootfs_drive_body("/tmp/a\"b\\c");
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(v["path_on_host"], "/tmp/a\"b\\c");
    }

    #[tokio::test]
    async fn call_sends_request_and_accepts_2xx() {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("api.sock");
        let fake = FakeApi::ok(&sock);
        call(
            &sock,
            "PUT",
            "/machine-config",
            &machine_config_body(2, 512),
        )
        .await
        .unwrap();
        let reqs = fake.recorded();
        assert_eq!(reqs.len(), 1);
        assert_eq!(
            reqs[0].raw,
            build_request(
                "PUT",
                "/machine-config",
                r#"{"vcpu_count":2,"mem_size_mib":512}"#
            )
        );
    }

    #[tokio::test]
    async fn calls_are_counted_by_endpoint_and_status() {
        let dir = tempfile::tempdir().unwrap();
        let m = metrics::global();
        let ok_before = m.firecracker_api.get("/test-counted", "ok");
        let err_before = m.firecracker_api.get("/test-counted", "connect_error");
        let _ = call(&dir.path().join("none.sock"), "PUT", "/test-counted", "{}").await;
        let sock = dir.path().join("api.sock");
        let _fake = FakeApi::ok(&sock);
        call(&sock, "PUT", "/test-counted", "{}").await.unwrap();
        assert_eq!(m.firecracker_api.get("/test-counted", "ok"), ok_before + 1);
        assert_eq!(
            m.firecracker_api.get("/test-counted", "connect_error"),
            err_before + 1
        );
    }

    #[tokio::test]
    async fn call_accepts_http_1_0_success() {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("api.sock");
        let _fake = FakeApi::start(&sock, |_| "HTTP/1.0 200 OK\r\n\r\n".into());
        call(&sock, "PUT", "/actions", INSTANCE_START_BODY)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn call_reports_fault_message() {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("api.sock");
        let body = r#"{"fault_message":"bad kernel"}"#;
        let resp = format!(
            "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        );
        let _fake = FakeApi::start(&sock, move |_| resp.clone());
        let err = call(&sock, "PUT", "/boot-source", "{}").await.unwrap_err();
        match err {
            ApiError::Failed {
                status, body: b, ..
            } => {
                assert_eq!(status, "HTTP/1.1 400 Bad Request");
                assert_eq!(b, body);
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[tokio::test]
    async fn call_fails_without_socket() {
        let dir = tempfile::tempdir().unwrap();
        let err = call(&dir.path().join("missing.sock"), "PUT", "/actions", "{}")
            .await
            .unwrap_err();
        assert!(matches!(err, ApiError::Connect { .. }));
    }

    #[tokio::test]
    async fn call_rejects_empty_response() {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("api.sock");
        let _fake = FakeApi::start(&sock, |_| String::new());
        let err = call(&sock, "PUT", "/actions", "{}").await.unwrap_err();
        assert!(matches!(err, ApiError::EmptyResponse), "{err:?}");
    }

    #[tokio::test]
    async fn call_rejects_oversized_request() {
        let dir = tempfile::tempdir().unwrap();
        let body = "x".repeat(MAX_REQUEST_LEN);
        let err = call(&dir.path().join("none.sock"), "PUT", "/x", &body)
            .await
            .unwrap_err();
        assert!(matches!(err, ApiError::RequestTooLarge(_)));
    }

    #[tokio::test]
    async fn call_times_out_on_silent_server() {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("api.sock");
        let listener = tokio::net::UnixListener::bind(&sock).unwrap();
        let _hold = tokio::spawn(async move {
            let (_s, _) = listener.accept().await.unwrap();
            tokio::time::sleep(Duration::from_secs(5)).await;
        });
        let err = call_with_timeout(&sock, "PUT", "/actions", "{}", Duration::from_millis(100))
            .await
            .unwrap_err();
        assert!(matches!(err, ApiError::Timeout));
    }
}
