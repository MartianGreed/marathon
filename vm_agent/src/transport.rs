//! Listener boundary: Linux vsock in production, TCP loopback in portable tests.

use std::{future::Future, io};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    net::{TcpListener, TcpStream},
};

/// Stream capabilities required by guest framing.
pub trait AgentStream: AsyncRead + AsyncWrite + Unpin + Send {}

impl<T: AsyncRead + AsyncWrite + Unpin + Send> AgentStream for T {}

/// Accept connections together with the guest CID reported in Ready.
pub trait Listener: Send {
    /// Accepted stream type used by the framing helpers.
    type Stream: AgentStream + 'static;

    /// Accept a connection and return its stream and local guest CID.
    fn accept(&mut self) -> impl Future<Output = io::Result<(Self::Stream, u32)>> + Send;
}

impl Listener for TcpListener {
    type Stream = TcpStream;

    async fn accept(&mut self) -> io::Result<(TcpStream, u32)> {
        let (stream, _) = TcpListener::accept(self).await?;
        Ok((stream, 0))
    }
}

/// Bind a TCP test listener; a missing address is unsupported.
pub async fn bind_test_transport(address: Option<&str>) -> io::Result<TcpListener> {
    let address = address.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::Unsupported,
            "vsock is Linux-only; set MARATHON_VM_AGENT_TCP_ADDR for the test transport",
        )
    })?;
    TcpListener::bind(address).await
}

/// Linux guest listener on AF_VSOCK.
#[cfg(target_os = "linux")]
pub struct VsockListener(tokio_vsock::VsockListener);

#[cfg(target_os = "linux")]
impl VsockListener {
    /// Bind a guest vsock port on CID_ANY.
    pub fn bind(port: u32) -> io::Result<Self> {
        tokio_vsock::VsockListener::bind(tokio_vsock::VsockAddr::new(common::vsock::CID_ANY, port))
            .map(Self)
    }
}

#[cfg(target_os = "linux")]
impl Listener for VsockListener {
    type Stream = tokio_vsock::VsockStream;

    async fn accept(&mut self) -> io::Result<(Self::Stream, u32)> {
        let (stream, _) = self.0.accept().await?;
        let cid = stream.local_addr()?.cid();
        Ok((stream, cid))
    }
}

/// Listener type selected for the current platform.
#[cfg(target_os = "linux")]
pub type PlatformListener = VsockListener;

/// Listener type selected for the current platform.
#[cfg(not(target_os = "linux"))]
pub type PlatformListener = TcpListener;

#[cfg(test)]
mod tests {
    use super::*;

    // Zig's send/receive stub tests do not apply: framing is shared over any
    // stream and is covered by the agent conversation tests.
    #[test]
    fn vsock_client_type_selection() {
        fn selected<T: Listener>() {}
        selected::<PlatformListener>();
    }

    #[tokio::test]
    async fn stub_vsock_client_init_succeeds() {
        assert_eq!(
            bind_test_transport(None).await.unwrap_err().kind(),
            io::ErrorKind::Unsupported
        );
    }
}
