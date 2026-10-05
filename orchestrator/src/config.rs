//! Orchestrator-only settings omitted from the shared environment loader.

/// TLS paths and optional Prometheus listener configuration.
#[derive(Clone, Default)]
pub struct LocalConfig {
    /// Optional PEM certificate path; must be paired with tls_key_path.
    pub tls_cert_path: Option<String>,
    /// Optional PEM private-key path; must be paired with tls_cert_path.
    pub tls_key_path: Option<String>,
    /// Prometheus listener port, or None to disable the listener.
    pub metrics_port: Option<u16>,
}

impl LocalConfig {
    /// Load settings from the process environment.
    pub fn from_env() -> anyhow::Result<Self> {
        Self::from_lookup(|k| std::env::var(k).ok())
    }

    /// Load and validate settings through an injectable variable lookup.
    pub fn from_lookup(get: impl Fn(&str) -> Option<String>) -> anyhow::Result<Self> {
        let value = Self {
            tls_cert_path: get("MARATHON_TLS_CERT_PATH"),
            tls_key_path: get("MARATHON_TLS_KEY_PATH"),
            metrics_port: get("MARATHON_METRICS_PORT")
                .map(|s| s.parse())
                .transpose()?,
        };
        anyhow::ensure!(
            value.tls_cert_path.is_some() == value.tls_key_path.is_some(),
            "both TLS certificate and key paths must be set"
        );
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tls_and_metrics_lookup() {
        assert!(LocalConfig::from_lookup(|_| None).is_ok());
        assert!(
            LocalConfig::from_lookup(|key| (key == "MARATHON_TLS_CERT_PATH").then(|| "cert".into()))
                .is_err()
        );
        assert!(
            LocalConfig::from_lookup(|key| (key == "MARATHON_TLS_KEY_PATH").then(|| "key".into()))
                .is_err()
        );
        let c = LocalConfig::from_lookup(|key| match key {
            "MARATHON_TLS_CERT_PATH" => Some("cert".into()),
            "MARATHON_TLS_KEY_PATH" => Some("key".into()),
            "MARATHON_METRICS_PORT" => Some("9000".into()),
            _ => None,
        })
        .unwrap();
        assert_eq!(c.metrics_port, Some(9000));
        assert!(
            LocalConfig::from_lookup(|key| (key == "MARATHON_METRICS_PORT").then(|| "bad".into()))
                .is_err()
        );
    }
}
