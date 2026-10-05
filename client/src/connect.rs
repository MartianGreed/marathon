//! Orchestrator connection: endpoint, optional TLS with a custom CA, and the
//! per-request metadata (client credential and W3C trace context).

use std::time::Duration;

use common::client_auth::ClientCredential;
use common::config::ClientConfig;
use common::pb::marathon_service_client::MarathonServiceClient;
use tonic::metadata::MetadataValue;
use tonic::transport::{Certificate, Channel, ClientTlsConfig, Endpoint};

/// How long to wait for the TCP and TLS handshake.
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// Metadata key of the W3C trace context.
pub const TRACEPARENT: &str = "traceparent";

pub type Client = MarathonServiceClient<Channel>;

#[derive(Debug, thiserror::Error)]
pub enum ConnectError {
    #[error("cannot read CA certificate {path}: {source}")]
    CaFile {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("invalid orchestrator address {uri}: {source}")]
    InvalidUri {
        uri: String,
        #[source]
        source: tonic::transport::Error,
    },
    #[error("TLS configuration: {0}")]
    Tls(#[source] tonic::transport::Error),
    #[error("{}", error_chain(.0))]
    Transport(#[source] tonic::transport::Error),
}

/// `err` followed by each of its sources, separated by `: `.
pub fn error_chain(err: &dyn std::error::Error) -> String {
    let mut out = err.to_string();
    let mut source = err.source();
    while let Some(e) = source {
        let s = e.to_string();
        if !out.contains(&s) {
            out.push_str(": ");
            out.push_str(&s);
        }
        source = e.source();
    }
    out
}

/// `http://host:port` or `https://host:port`, with IPv6 hosts bracketed.
pub fn endpoint_uri(config: &ClientConfig) -> String {
    let scheme = if config.tls_enabled { "https" } else { "http" };
    let host = &config.orchestrator_address;
    if host.contains(':') && !host.starts_with('[') {
        format!("{scheme}://[{host}]:{}", config.orchestrator_port)
    } else {
        format!("{scheme}://{host}:{}", config.orchestrator_port)
    }
}

/// Build the endpoint, with TLS when enabled: the CA from
/// `MARATHON_TLS_CA_PATH` when set, the system roots otherwise.
pub fn endpoint(config: &ClientConfig) -> Result<Endpoint, ConnectError> {
    let uri = endpoint_uri(config);
    let mut endpoint = Endpoint::from_shared(uri.clone())
        .map_err(|source| ConnectError::InvalidUri { uri, source })?
        .connect_timeout(CONNECT_TIMEOUT);
    if config.tls_enabled {
        let host = config
            .orchestrator_address
            .trim_start_matches('[')
            .trim_end_matches(']');
        let mut tls = ClientTlsConfig::new().domain_name(host);
        tls = match &config.tls_ca_path {
            Some(path) => {
                let pem = std::fs::read(path).map_err(|source| ConnectError::CaFile {
                    path: path.clone(),
                    source,
                })?;
                tls.ca_certificate(Certificate::from_pem(pem))
            }
            None => tls.with_native_roots(),
        };
        endpoint = endpoint.tls_config(tls).map_err(ConnectError::Tls)?;
    }
    Ok(endpoint)
}

/// Connect to the orchestrator.
pub async fn connect(config: &ClientConfig) -> Result<Client, ConnectError> {
    let started = std::time::Instant::now();
    let endpoint = endpoint(config)?;
    tracing::debug!(
        operation = "connect",
        address = %config.orchestrator_address,
        port = config.orchestrator_port,
        tls = config.tls_enabled,
        "connecting to orchestrator"
    );
    match endpoint.connect().await {
        Ok(channel) => {
            tracing::debug!(
                operation = "connect",
                duration_ms = started.elapsed().as_millis() as u64,
                "connected"
            );
            Ok(MarathonServiceClient::new(channel))
        }
        Err(e) => {
            let err = ConnectError::Transport(e);
            tracing::error!(
                operation = "connect",
                address = %config.orchestrator_address,
                port = config.orchestrator_port,
                tls = config.tls_enabled,
                duration_ms = started.elapsed().as_millis() as u64,
                error = %err,
                "connection to orchestrator failed"
            );
            Err(err)
        }
    }
}

/// W3C trace context for one CLI command. Every request of the command
/// shares the trace id and gets its own parent span id.
#[derive(Debug, Clone, Copy)]
pub struct TraceContext {
    trace_id: [u8; 16],
}

impl TraceContext {
    pub fn new() -> Self {
        let mut trace_id: [u8; 16] = rand::random();
        // An all-zero trace id is invalid.
        if trace_id == [0; 16] {
            trace_id[15] = 1;
        }
        Self { trace_id }
    }

    pub fn trace_id(&self) -> String {
        hex(&self.trace_id)
    }

    /// `00-<trace id>-<new span id>-01`.
    pub fn traceparent(&self) -> String {
        let mut span_id: [u8; 8] = rand::random();
        if span_id == [0; 8] {
            span_id[7] = 1;
        }
        format!("00-{}-{}-01", self.trace_id(), hex(&span_id))
    }
}

impl Default for TraceContext {
    fn default() -> Self {
        Self::new()
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// A request carrying the trace context and, when given, the credential.
pub fn request<T>(
    message: T,
    trace: &TraceContext,
    credential: Option<&ClientCredential>,
) -> Result<tonic::Request<T>, common::client_auth::CredentialError> {
    let mut request = tonic::Request::new(message);
    let traceparent = trace.traceparent();
    tracing::debug!(traceparent = %traceparent, "request trace context");
    if let Ok(value) = MetadataValue::try_from(traceparent) {
        request.metadata_mut().insert(TRACEPARENT, value);
    }
    if let Some(credential) = credential {
        credential.apply(request.metadata_mut())?;
    }
    Ok(request)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(address: &str, port: u16, tls: bool) -> ClientConfig {
        ClientConfig {
            orchestrator_address: address.into(),
            orchestrator_port: port,
            tls_enabled: tls,
            ..ClientConfig::default()
        }
    }

    #[test]
    fn uri_scheme_and_host() {
        assert_eq!(
            endpoint_uri(&config("127.0.0.1", 8080, false)),
            "http://127.0.0.1:8080"
        );
        assert_eq!(
            endpoint_uri(&config("orch.example", 443, true)),
            "https://orch.example:443"
        );
        assert_eq!(
            endpoint_uri(&config("::1", 9000, false)),
            "http://[::1]:9000"
        );
        assert_eq!(
            endpoint_uri(&config("[::1]", 9000, false)),
            "http://[::1]:9000"
        );
    }

    #[test]
    fn missing_ca_file_is_reported() {
        let mut c = config("orch.example", 443, true);
        c.tls_ca_path = Some("/nonexistent/ca.pem".into());
        let err = endpoint(&c).unwrap_err();
        assert!(matches!(err, ConnectError::CaFile { .. }), "{err}");
        assert!(err.to_string().contains("/nonexistent/ca.pem"));
    }

    #[test]
    fn invalid_address_is_reported() {
        let err = endpoint(&config("bad host", 80, false)).unwrap_err();
        assert!(matches!(err, ConnectError::InvalidUri { .. }), "{err}");
    }

    #[test]
    fn traceparent_format() {
        let trace = TraceContext::new();
        let a = trace.traceparent();
        let b = trace.traceparent();
        let parts: Vec<&str> = a.split('-').collect();
        assert_eq!(parts.len(), 4);
        assert_eq!(parts[0], "00");
        assert_eq!(parts[1], trace.trace_id());
        assert_eq!(parts[1].len(), 32);
        assert_eq!(parts[2].len(), 16);
        assert_eq!(parts[3], "01");
        assert!(a[3..].chars().all(|c| c == '-' || c.is_ascii_hexdigit()));
        // Same trace, new span per request.
        assert_eq!(&a[..35], &b[..35]);
        assert_ne!(a, b);
    }

    #[test]
    fn request_metadata() {
        let trace = TraceContext::new();
        let cred = ClientCredential::ApiKey("mk_secret".into());
        let req = request((), &trace, Some(&cred)).unwrap();
        assert_eq!(req.metadata().get("x-api-key").unwrap(), "mk_secret");
        assert!(
            req.metadata()
                .get(TRACEPARENT)
                .unwrap()
                .to_str()
                .unwrap()
                .contains(&trace.trace_id())
        );
        let req = request((), &trace, None).unwrap();
        assert!(req.metadata().get("x-api-key").is_none());
        assert!(req.metadata().get("authorization").is_none());
    }
}
