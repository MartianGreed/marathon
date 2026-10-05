//! Node operator <-> VM agent framing over vsock.
//!
//! A frame is a 4-byte unsigned big-endian length followed by that many bytes
//! of a protobuf [`VsockMessage`](crate::pb::VsockMessage). Frames longer than
//! [`MAX_FRAME_LEN`] are rejected before their body is read.
//!
//! On the host, Firecracker exposes the guest's vsock as a Unix socket. The
//! node operator connects to it, writes `CONNECT <port>\n` and must read a
//! line starting with `OK ` before framing starts
//! ([`firecracker_handshake`], [`connect_firecracker`]).
//!
//! The helpers work on any `AsyncRead`/`AsyncWrite`, so the same code runs on
//! a vsock stream inside the guest, the Firecracker Unix socket on the host,
//! and in-memory streams in tests.

use std::io;

use prost::Message;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::pb::{VsockMessage, vsock_message};

/// Default vsock port the agent listens on.
pub const DEFAULT_PORT: u32 = 9999;
/// Any context id (bind address for listeners).
pub const CID_ANY: u32 = 0xFFFF_FFFF;
pub const CID_HYPERVISOR: u32 = 0;
pub const CID_LOCAL: u32 = 1;
/// The host, as seen from a guest.
pub const CID_HOST: u32 = 2;

/// Size of the length prefix.
pub const LENGTH_PREFIX_LEN: usize = 4;
/// Largest accepted message body: 16 MiB.
pub const MAX_FRAME_LEN: usize = 16 * 1024 * 1024;

/// A frame could not be written or read.
#[derive(Debug, thiserror::Error)]
pub enum FrameError {
    /// The peer closed the stream cleanly before a new frame started.
    #[error("vsock stream closed")]
    Closed,
    /// The stream ended in the middle of a frame.
    #[error("vsock frame truncated: expected {expected} bytes, got {received}")]
    Truncated { expected: usize, received: usize },
    /// The frame length exceeds the limit.
    #[error("vsock frame of {len} bytes exceeds the {max} byte limit")]
    TooLarge { len: usize, max: usize },
    /// The body is not a valid `VsockMessage`.
    #[error("invalid vsock message: {0}")]
    Decode(#[from] prost::DecodeError),
    /// The message has no payload variant set.
    #[error("vsock message has no payload")]
    Empty,
    #[error("vsock i/o error: {0}")]
    Io(#[from] io::Error),
}

/// Encode `msg` as one frame (length prefix + body).
pub fn encode_frame(msg: &VsockMessage) -> Result<Vec<u8>, FrameError> {
    if msg.payload.is_none() {
        return Err(FrameError::Empty);
    }
    let len = msg.encoded_len();
    if len > MAX_FRAME_LEN {
        return Err(FrameError::TooLarge {
            len,
            max: MAX_FRAME_LEN,
        });
    }
    let mut buf = Vec::with_capacity(LENGTH_PREFIX_LEN + len);
    // len <= MAX_FRAME_LEN < u32::MAX
    buf.extend_from_slice(&(len as u32).to_be_bytes());
    msg.encode(&mut buf)
        .map_err(|e| io::Error::other(e.to_string()))?;
    Ok(buf)
}

/// Decode one message body (without its length prefix).
pub fn decode_body(body: &[u8]) -> Result<VsockMessage, FrameError> {
    let msg = VsockMessage::decode(body)?;
    if msg.payload.is_none() {
        return Err(FrameError::Empty);
    }
    Ok(msg)
}

/// Write one frame and flush.
pub async fn write_message<W>(writer: &mut W, msg: &VsockMessage) -> Result<(), FrameError>
where
    W: AsyncWrite + Unpin + ?Sized,
{
    let frame = encode_frame(msg)?;
    writer.write_all(&frame).await?;
    writer.flush().await?;
    tracing::trace!(
        frame_len = frame.len(),
        kind = kind(msg),
        "vsock frame written"
    );
    Ok(())
}

/// Read one frame of at most [`MAX_FRAME_LEN`] bytes.
pub async fn read_message<R>(reader: &mut R) -> Result<VsockMessage, FrameError>
where
    R: AsyncRead + Unpin + ?Sized,
{
    read_message_with_limit(reader, MAX_FRAME_LEN).await
}

/// Read one frame of at most `max_len` body bytes.
pub async fn read_message_with_limit<R>(
    reader: &mut R,
    max_len: usize,
) -> Result<VsockMessage, FrameError>
where
    R: AsyncRead + Unpin + ?Sized,
{
    let mut prefix = [0u8; LENGTH_PREFIX_LEN];
    let got = read_full(reader, &mut prefix).await?;
    if got == 0 {
        return Err(FrameError::Closed);
    }
    if got < LENGTH_PREFIX_LEN {
        return Err(FrameError::Truncated {
            expected: LENGTH_PREFIX_LEN,
            received: got,
        });
    }
    let len = u32::from_be_bytes(prefix) as usize;
    if len > max_len {
        return Err(FrameError::TooLarge { len, max: max_len });
    }
    let mut body = vec![0u8; len];
    let got = read_full(reader, &mut body).await?;
    if got < len {
        return Err(FrameError::Truncated {
            expected: len,
            received: got,
        });
    }
    let msg = decode_body(&body)?;
    tracing::trace!(frame_len = len, kind = kind(&msg), "vsock frame read");
    Ok(msg)
}

/// Fill `buf` unless the stream ends first; returns the bytes read.
async fn read_full<R>(reader: &mut R, buf: &mut [u8]) -> io::Result<usize>
where
    R: AsyncRead + Unpin + ?Sized,
{
    let mut filled = 0;
    while filled < buf.len() {
        let n = reader.read(&mut buf[filled..]).await?;
        if n == 0 {
            break;
        }
        filled += n;
    }
    Ok(filled)
}

/// Short name of the payload variant, for logs.
pub fn kind(msg: &VsockMessage) -> &'static str {
    match &msg.payload {
        None => "empty",
        Some(vsock_message::Payload::Ready(_)) => "ready",
        Some(vsock_message::Payload::Start(_)) => "start",
        Some(vsock_message::Payload::Cancel(_)) => "cancel",
        Some(vsock_message::Payload::Output(_)) => "output",
        Some(vsock_message::Payload::Metrics(_)) => "metrics",
        Some(vsock_message::Payload::Progress(_)) => "progress",
        Some(vsock_message::Payload::Complete(_)) => "complete",
        Some(vsock_message::Payload::Error(_)) => "error",
    }
}

impl From<vsock_message::Payload> for VsockMessage {
    fn from(payload: vsock_message::Payload) -> Self {
        Self {
            payload: Some(payload),
        }
    }
}

/// Longest accepted handshake reply line, newline included.
pub const HANDSHAKE_MAX_LINE: usize = 64;

/// The Firecracker `CONNECT` handshake failed.
#[derive(Debug, thiserror::Error)]
pub enum HandshakeError {
    #[error("vsock handshake i/o error: {0}")]
    Io(#[from] io::Error),
    #[error("vsock socket closed during handshake")]
    Closed,
    #[error("vsock handshake rejected: {0:?}")]
    Rejected(String),
    #[error("vsock handshake reply longer than {HANDSHAKE_MAX_LINE} bytes")]
    LineTooLong,
}

/// Send `CONNECT <port>\n` and wait for a line starting with `OK `.
///
/// The reply is read one byte at a time up to the newline so that any guest
/// bytes following it stay in the stream. Returns the reply line without its
/// newline. Callers wrap this in a timeout.
pub async fn firecracker_handshake<S>(stream: &mut S, port: u32) -> Result<String, HandshakeError>
where
    S: AsyncRead + AsyncWrite + Unpin + ?Sized,
{
    stream
        .write_all(format!("CONNECT {port}\n").as_bytes())
        .await?;
    stream.flush().await?;

    let mut line = Vec::with_capacity(HANDSHAKE_MAX_LINE);
    loop {
        let mut byte = [0u8; 1];
        if stream.read(&mut byte).await? == 0 {
            return Err(HandshakeError::Closed);
        }
        if byte[0] == b'\n' {
            break;
        }
        if line.len() + 1 >= HANDSHAKE_MAX_LINE {
            return Err(HandshakeError::LineTooLong);
        }
        line.push(byte[0]);
    }
    let line = String::from_utf8_lossy(&line).into_owned();
    if !line.starts_with("OK ") {
        tracing::warn!(port, reply = %line, operation = "vsock_handshake", "vsock handshake rejected");
        return Err(HandshakeError::Rejected(line));
    }
    tracing::debug!(port, reply = %line, operation = "vsock_handshake", "vsock handshake complete");
    Ok(line)
}

/// Connect to a Firecracker vsock Unix socket and complete the handshake for
/// guest `port`.
#[cfg(unix)]
pub async fn connect_firecracker(
    uds_path: impl AsRef<std::path::Path>,
    port: u32,
) -> Result<tokio::net::UnixStream, HandshakeError> {
    let path = uds_path.as_ref();
    let mut stream = tokio::net::UnixStream::connect(path).await.map_err(|e| {
        tracing::warn!(path = %path.display(), port, error = %e, operation = "vsock_connect", "vsock unix socket connect failed");
        e
    })?;
    firecracker_handshake(&mut stream, port).await?;
    Ok(stream)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pb::{
        EnvVar, OutputType, VsockCancel, VsockComplete, VsockError, VsockMetrics, VsockOutput,
        VsockProgress, VsockReady, VsockStart,
    };
    use tokio::io::duplex;
    use vsock_message::Payload;

    fn metrics() -> VsockMetrics {
        VsockMetrics {
            input_tokens: 1000,
            output_tokens: 500,
            cache_read_tokens: 100,
            cache_write_tokens: 50,
            tool_calls: 5,
        }
    }

    fn start(full: bool) -> VsockStart {
        VsockStart {
            task_id: "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20".into(),
            repo_url: "https://github.com/test/repo".into(),
            branch: "feature-branch".into(),
            prompt: "Implement feature X".into(),
            github_token: "ghp_xxx".into(),
            anthropic_api_key: "sk-ant-xxx".into(),
            create_pr: full,
            pr_title: full.then(|| "Add feature X".into()),
            pr_body: full.then(|| "This PR adds feature X".into()),
            max_iterations: full.then_some(5),
            completion_promise: full.then(|| "TASK_COMPLETE".into()),
            env_vars: if full {
                vec![
                    EnvVar {
                        key: "B".into(),
                        value: "2".into(),
                    },
                    EnvVar {
                        key: "A".into(),
                        value: "1".into(),
                    },
                    EnvVar {
                        key: "B".into(),
                        value: "3".into(),
                    },
                ]
            } else {
                vec![]
            },
        }
    }

    /// Every variant, with optional fields both set and unset.
    fn all_variants() -> Vec<VsockMessage> {
        vec![
            Payload::Ready(VsockReady { vm_id: 3 }).into(),
            Payload::Ready(VsockReady { vm_id: 0 }).into(),
            Payload::Start(start(true)).into(),
            Payload::Start(start(false)).into(),
            Payload::Cancel(VsockCancel {}).into(),
            Payload::Output(VsockOutput {
                r#type: OutputType::Stdout as i32,
                data: b"Running tests...".to_vec(),
            })
            .into(),
            Payload::Output(VsockOutput {
                r#type: OutputType::Claude as i32,
                data: vec![0, 159, 146, 150, 255],
            })
            .into(),
            Payload::Output(VsockOutput {
                r#type: OutputType::Stderr as i32,
                data: vec![],
            })
            .into(),
            Payload::Metrics(VsockMetrics {
                input_tokens: 12345,
                output_tokens: 6789,
                cache_read_tokens: 1000,
                cache_write_tokens: 500,
                tool_calls: 42,
            })
            .into(),
            Payload::Progress(VsockProgress {
                iteration: 2,
                max_iterations: 5,
                status: "Running iteration 2 of 5".into(),
            })
            .into(),
            Payload::Complete(VsockComplete {
                exit_code: 0,
                pr_url: Some("https://github.com/owner/repo/pull/42".into()),
                metrics: Some(metrics()),
                iteration: 3,
                promise_found: true,
            })
            .into(),
            Payload::Complete(VsockComplete {
                exit_code: 1,
                pr_url: None,
                metrics: Some(VsockMetrics {
                    input_tokens: 500,
                    output_tokens: 250,
                    cache_read_tokens: 0,
                    cache_write_tokens: 0,
                    tool_calls: 5,
                }),
                iteration: 1,
                promise_found: false,
            })
            .into(),
            Payload::Complete(VsockComplete {
                exit_code: -9,
                pr_url: Some(String::new()),
                metrics: None,
                iteration: 0,
                promise_found: false,
            })
            .into(),
            Payload::Error(VsockError {
                code: "ERR_TIMEOUT".into(),
                message: "Task execution timed out after 30 minutes".into(),
            })
            .into(),
        ]
    }

    #[test]
    fn every_variant_round_trips_through_encode_frame() {
        let variants = all_variants();
        let kinds: std::collections::BTreeSet<_> = variants.iter().map(kind).collect();
        assert_eq!(
            kinds.into_iter().collect::<Vec<_>>(),
            [
                "cancel", "complete", "error", "metrics", "output", "progress", "ready", "start"
            ]
        );
        for msg in variants {
            let frame = encode_frame(&msg).unwrap();
            let len = u32::from_be_bytes(frame[..4].try_into().unwrap()) as usize;
            assert_eq!(len, frame.len() - LENGTH_PREFIX_LEN, "{msg:?}");
            assert_eq!(decode_body(&frame[4..]).unwrap(), msg);
        }
    }

    // Port of the protocol.zig optional-field tests: unset optionals stay unset.
    #[test]
    fn optional_fields_keep_presence() {
        let decoded =
            decode_body(&encode_frame(&Payload::Start(start(false)).into()).unwrap()[4..]).unwrap();
        let Some(Payload::Start(s)) = decoded.payload else {
            panic!("not start")
        };
        assert_eq!(s.max_iterations, None);
        assert_eq!(s.completion_promise, None);
        assert_eq!(s.pr_title, None);
        assert_eq!(s.pr_body, None);

        // Zero and empty values are present, not absent.
        let mut zero = start(false);
        zero.max_iterations = Some(0);
        zero.completion_promise = Some(String::new());
        let decoded =
            decode_body(&encode_frame(&Payload::Start(zero).into()).unwrap()[4..]).unwrap();
        let Some(Payload::Start(s)) = decoded.payload else {
            panic!("not start")
        };
        assert_eq!(s.max_iterations, Some(0));
        assert_eq!(s.completion_promise.as_deref(), Some(""));
    }

    #[tokio::test]
    async fn every_variant_round_trips_through_a_stream() {
        let (mut a, mut b) = duplex(64);
        let variants = all_variants();
        let expected = variants.clone();
        let writer = tokio::spawn(async move {
            for msg in &variants {
                write_message(&mut a, msg).await.unwrap();
            }
        });
        for msg in expected {
            assert_eq!(read_message(&mut b).await.unwrap(), msg);
        }
        writer.await.unwrap();
        assert!(matches!(
            read_message(&mut b).await,
            Err(FrameError::Closed)
        ));
    }

    #[tokio::test]
    async fn back_to_back_frames_in_one_buffer() {
        let msgs = all_variants();
        let mut bytes = Vec::new();
        for m in &msgs {
            bytes.extend(encode_frame(m).unwrap());
        }
        let mut reader = bytes.as_slice();
        for m in msgs {
            assert_eq!(read_message(&mut reader).await.unwrap(), m);
        }
        assert!(matches!(
            read_message(&mut reader).await,
            Err(FrameError::Closed)
        ));
    }

    #[tokio::test]
    async fn rejects_oversized_frames_before_reading_body() {
        // Header announces MAX + 1; no body follows. TooLarge, not Truncated.
        let header = ((MAX_FRAME_LEN + 1) as u32).to_be_bytes();
        let mut reader = header.as_slice();
        match read_message(&mut reader).await {
            Err(FrameError::TooLarge { len, max }) => {
                assert_eq!(len, MAX_FRAME_LEN + 1);
                assert_eq!(max, MAX_FRAME_LEN);
            }
            other => panic!("{other:?}"),
        }

        let header = u32::MAX.to_be_bytes();
        let mut reader = header.as_slice();
        assert!(matches!(
            read_message(&mut reader).await,
            Err(FrameError::TooLarge { .. })
        ));
    }

    #[tokio::test]
    async fn limit_boundary_is_inclusive() {
        let msg: VsockMessage = Payload::Output(VsockOutput {
            r#type: 1,
            data: vec![7; 100],
        })
        .into();
        let frame = encode_frame(&msg).unwrap();
        let len = frame.len() - LENGTH_PREFIX_LEN;
        assert_eq!(
            read_message_with_limit(&mut frame.as_slice(), len)
                .await
                .unwrap(),
            msg
        );
        assert!(matches!(
            read_message_with_limit(&mut frame.as_slice(), len - 1).await,
            Err(FrameError::TooLarge { len: l, max }) if l == len && max == len - 1
        ));
    }

    #[test]
    fn encode_rejects_oversized_message() {
        // Output framing overhead here is 12 bytes: outer tag + 4-byte length,
        // type tag + value, data tag + 4-byte length.
        let overhead = 12;
        let msg: VsockMessage = Payload::Output(VsockOutput {
            r#type: 1,
            data: vec![0; MAX_FRAME_LEN - overhead],
        })
        .into();
        assert_eq!(msg.encoded_len(), MAX_FRAME_LEN);
        assert!(encode_frame(&msg).is_ok());

        let msg: VsockMessage = Payload::Output(VsockOutput {
            r#type: 1,
            data: vec![0; MAX_FRAME_LEN - overhead + 1],
        })
        .into();
        assert_eq!(msg.encoded_len(), MAX_FRAME_LEN + 1);
        assert!(matches!(
            encode_frame(&msg),
            Err(FrameError::TooLarge { len, max: MAX_FRAME_LEN }) if len == MAX_FRAME_LEN + 1
        ));

        let msg: VsockMessage = Payload::Output(VsockOutput {
            r#type: 1,
            data: vec![0; MAX_FRAME_LEN],
        })
        .into();
        assert!(matches!(
            encode_frame(&msg),
            Err(FrameError::TooLarge {
                max: MAX_FRAME_LEN,
                ..
            })
        ));
    }

    #[tokio::test]
    async fn default_limit_accepts_exactly_max_frame() {
        let msg: VsockMessage = Payload::Output(VsockOutput {
            r#type: 1,
            data: vec![9; MAX_FRAME_LEN - 12],
        })
        .into();
        let frame = encode_frame(&msg).unwrap();
        assert_eq!(frame.len(), LENGTH_PREFIX_LEN + MAX_FRAME_LEN);
        assert_eq!(read_message(&mut frame.as_slice()).await.unwrap(), msg);
    }

    #[tokio::test]
    async fn write_rejects_oversized_message_without_writing() {
        let msg: VsockMessage = Payload::Output(VsockOutput {
            r#type: 1,
            data: vec![0; MAX_FRAME_LEN + 1],
        })
        .into();
        let mut out = Vec::new();
        assert!(matches!(
            write_message(&mut out, &msg).await,
            Err(FrameError::TooLarge { .. })
        ));
        assert!(out.is_empty());
    }

    #[tokio::test]
    async fn rejects_truncated_prefix() {
        for n in 1..LENGTH_PREFIX_LEN {
            let bytes = vec![0u8; n];
            match read_message(&mut bytes.as_slice()).await {
                Err(FrameError::Truncated { expected, received }) => {
                    assert_eq!(expected, LENGTH_PREFIX_LEN);
                    assert_eq!(received, n);
                }
                other => panic!("{n}: {other:?}"),
            }
        }
    }

    #[tokio::test]
    async fn rejects_truncated_body() {
        let frame = encode_frame(&Payload::Start(start(true)).into()).unwrap();
        let body_len = frame.len() - LENGTH_PREFIX_LEN;
        for cut in [LENGTH_PREFIX_LEN, LENGTH_PREFIX_LEN + 1, frame.len() - 1] {
            match read_message(&mut &frame[..cut]).await {
                Err(FrameError::Truncated { expected, received }) => {
                    assert_eq!(expected, body_len);
                    assert_eq!(received, cut - LENGTH_PREFIX_LEN);
                }
                other => panic!("{cut}: {other:?}"),
            }
        }
    }

    // Port of integration_test.zig "connection closed during read".
    #[tokio::test]
    async fn closed_stream_is_closed() {
        let (a, mut b) = duplex(16);
        drop(a);
        assert!(matches!(
            read_message(&mut b).await,
            Err(FrameError::Closed)
        ));
    }

    // Replaces integration_test.zig "invalid magic": garbage is a decode error.
    #[tokio::test]
    async fn rejects_garbage_body() {
        let mut bytes = 4u32.to_be_bytes().to_vec();
        bytes.extend_from_slice(&[0xff, 0xff, 0xff, 0xff]);
        assert!(matches!(
            read_message(&mut bytes.as_slice()).await,
            Err(FrameError::Decode(_))
        ));
    }

    #[tokio::test]
    async fn rejects_empty_message() {
        let bytes = 0u32.to_be_bytes();
        assert!(matches!(
            read_message(&mut bytes.as_slice()).await,
            Err(FrameError::Empty)
        ));
        assert!(matches!(
            encode_frame(&VsockMessage { payload: None }),
            Err(FrameError::Empty)
        ));
    }

    /// VM agent side of the conversation (port of integration_test.zig).
    async fn agent_side<S: AsyncRead + AsyncWrite + Unpin>(mut s: S) {
        write_message(&mut s, &Payload::Ready(VsockReady { vm_id: 3 }).into())
            .await
            .unwrap();

        let msg = read_message(&mut s).await.unwrap();
        let Some(Payload::Start(start)) = msg.payload else {
            panic!("expected start, got {msg:?}")
        };
        assert_eq!(start.repo_url, "https://github.com/test/repo");
        assert_eq!(start.branch, "main");
        assert_eq!(start.prompt, "Fix the bug");
        assert!(start.create_pr);
        assert_eq!(start.max_iterations, Some(3));
        assert_eq!(start.completion_promise.as_deref(), Some("TASK_COMPLETE"));
        assert_eq!(start.env_vars.len(), 1);

        for payload in [
            Payload::Output(VsockOutput {
                r#type: OutputType::Stdout as i32,
                data: b"Running tests...".to_vec(),
            }),
            Payload::Metrics(metrics()),
            Payload::Progress(VsockProgress {
                iteration: 1,
                max_iterations: 3,
                status: "Running iteration 1 of 3".into(),
            }),
            Payload::Complete(VsockComplete {
                exit_code: 0,
                pr_url: Some("https://github.com/test/repo/pull/123".into()),
                metrics: Some(metrics()),
                iteration: 3,
                promise_found: true,
            }),
        ] {
            write_message(&mut s, &payload.into()).await.unwrap();
        }
    }

    /// Node operator side of the conversation.
    async fn node_side<S: AsyncRead + AsyncWrite + Unpin>(mut s: S) {
        let msg = read_message(&mut s).await.unwrap();
        assert!(matches!(
            msg.payload,
            Some(Payload::Ready(VsockReady { vm_id: 3 }))
        ));

        let start = VsockStart {
            task_id: "01".repeat(32),
            repo_url: "https://github.com/test/repo".into(),
            branch: "main".into(),
            prompt: "Fix the bug".into(),
            github_token: "ghp_test123".into(),
            anthropic_api_key: "sk-ant-test123".into(),
            create_pr: true,
            pr_title: Some("Bug fix PR".into()),
            pr_body: Some("This fixes the bug".into()),
            max_iterations: Some(3),
            completion_promise: Some("TASK_COMPLETE".into()),
            env_vars: vec![EnvVar {
                key: "DATABASE_URL".into(),
                value: "postgres://x".into(),
            }],
        };
        write_message(&mut s, &Payload::Start(start).into())
            .await
            .unwrap();

        let msg = read_message(&mut s).await.unwrap();
        let Some(Payload::Output(out)) = msg.payload else {
            panic!("{msg:?}")
        };
        assert_eq!(out.r#type, OutputType::Stdout as i32);
        assert_eq!(out.data, b"Running tests...");

        let msg = read_message(&mut s).await.unwrap();
        assert_eq!(msg.payload, Some(Payload::Metrics(metrics())));

        let msg = read_message(&mut s).await.unwrap();
        let Some(Payload::Progress(p)) = msg.payload else {
            panic!("{msg:?}")
        };
        assert_eq!((p.iteration, p.max_iterations), (1, 3));
        assert_eq!(p.status, "Running iteration 1 of 3");

        let msg = read_message(&mut s).await.unwrap();
        let Some(Payload::Complete(c)) = msg.payload else {
            panic!("{msg:?}")
        };
        assert_eq!(c.exit_code, 0);
        assert_eq!(
            c.pr_url.as_deref(),
            Some("https://github.com/test/repo/pull/123")
        );
        assert_eq!(c.iteration, 3);
        assert!(c.promise_found);
        assert_eq!(c.metrics, Some(metrics()));

        assert!(matches!(
            read_message(&mut s).await,
            Err(FrameError::Closed)
        ));
    }

    // Port of integration_test.zig "vsock protocol integration test over UDS".
    #[cfg(unix)]
    #[tokio::test]
    async fn conversation_over_unix_socket_pair() {
        let (agent, node) = tokio::net::UnixStream::pair().unwrap();
        let agent = tokio::spawn(agent_side(agent));
        let node = tokio::spawn(node_side(node));
        agent.await.unwrap();
        node.await.unwrap();
    }

    #[tokio::test]
    async fn conversation_over_duplex() {
        let (agent, node) = duplex(32);
        let agent = tokio::spawn(agent_side(agent));
        node_side(node).await;
        agent.await.unwrap();
    }

    #[tokio::test]
    async fn handshake_ok_leaves_following_bytes() {
        let (mut host, mut fc) = duplex(256);
        let ready: VsockMessage = Payload::Ready(VsockReady { vm_id: 7 }).into();
        let ready_frame = encode_frame(&ready).unwrap();
        let firecracker = tokio::spawn(async move {
            let mut req = [0u8; 13];
            fc.read_exact(&mut req).await.unwrap();
            assert_eq!(&req, b"CONNECT 9999\n");
            // Reply and the guest's first frame arrive in one write.
            let mut reply = b"OK 1073741824\n".to_vec();
            reply.extend_from_slice(&ready_frame);
            fc.write_all(&reply).await.unwrap();
            fc
        });
        let line = firecracker_handshake(&mut host, DEFAULT_PORT)
            .await
            .unwrap();
        assert_eq!(line, "OK 1073741824");
        assert_eq!(read_message(&mut host).await.unwrap(), ready);
        drop(firecracker.await.unwrap());
    }

    async fn handshake_with_reply(reply: &'static [u8]) -> Result<String, HandshakeError> {
        let (mut host, mut fc) = duplex(256);
        tokio::spawn(async move {
            let mut req = [0u8; 11];
            fc.read_exact(&mut req).await.unwrap();
            assert_eq!(&req, b"CONNECT 52\n");
            fc.write_all(reply).await.unwrap();
        });
        firecracker_handshake(&mut host, 52).await
    }

    #[tokio::test]
    async fn handshake_rejected() {
        for reply in [&b"FAILURE\n"[..], b"OK\n", b"ok 5\n", b"\n", b"KO 5\n"] {
            match handshake_with_reply(reply).await {
                Err(HandshakeError::Rejected(line)) => {
                    assert_eq!(line.as_bytes(), &reply[..reply.len() - 1]);
                }
                other => panic!("{reply:?}: {other:?}"),
            }
        }
    }

    #[tokio::test]
    async fn handshake_closed() {
        assert!(matches!(
            handshake_with_reply(b"").await,
            Err(HandshakeError::Closed)
        ));
        assert!(matches!(
            handshake_with_reply(b"OK 12").await,
            Err(HandshakeError::Closed)
        ));
    }

    #[tokio::test]
    async fn handshake_line_too_long() {
        static LONG: [u8; 200] = [b'O'; 200];
        assert!(matches!(
            handshake_with_reply(&LONG).await,
            Err(HandshakeError::LineTooLong)
        ));
        // 63 bytes + newline is the longest accepted line.
        static MAX: [u8; 64] = {
            let mut b = [b'x'; 64];
            b[0] = b'O';
            b[1] = b'K';
            b[2] = b' ';
            b[63] = b'\n';
            b
        };
        assert_eq!(handshake_with_reply(&MAX).await.unwrap().len(), 63);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn connect_firecracker_over_unix_socket() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v.sock");
        let listener = tokio::net::UnixListener::bind(&path).unwrap();
        let server = tokio::spawn(async move {
            let (mut s, _) = listener.accept().await.unwrap();
            let mut req = [0u8; 13];
            s.read_exact(&mut req).await.unwrap();
            assert_eq!(&req, b"CONNECT 9999\n");
            s.write_all(b"OK 42\n").await.unwrap();
            let msg = read_message(&mut s).await.unwrap();
            assert!(matches!(msg.payload, Some(Payload::Cancel(_))));
        });
        let mut stream = connect_firecracker(&path, DEFAULT_PORT).await.unwrap();
        write_message(&mut stream, &Payload::Cancel(VsockCancel {}).into())
            .await
            .unwrap();
        server.await.unwrap();

        let missing = dir.path().join("missing.sock");
        assert!(matches!(
            connect_firecracker(&missing, DEFAULT_PORT).await,
            Err(HandshakeError::Io(_))
        ));
    }
}
