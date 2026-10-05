//! Client credentials in gRPC metadata.
//!
//! `MarathonService` calls other than Register and Login carry one of:
//!
//! ```text
//! authorization: Bearer <jwt>
//! x-api-key: <api key>
//! ```
//!
//! When both are present the Bearer token wins. The orchestrator derives the
//! caller's identity from the credential; requests carry no client id.

use tonic::metadata::{MetadataMap, MetadataValue};

/// Metadata key for the JWT.
pub const AUTHORIZATION: &str = "authorization";
/// Metadata key for the API key.
pub const API_KEY: &str = "x-api-key";
/// Scheme prefix of the `authorization` value.
pub const BEARER_PREFIX: &str = "Bearer ";

/// A credential carried by a client request.
#[derive(Clone, PartialEq, Eq)]
pub enum ClientCredential {
    /// HS256 JWT from Register or Login.
    Bearer(String),
    /// API key from Register or Login.
    ApiKey(String),
}

impl std::fmt::Debug for ClientCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Bearer(_) => f.write_str("Bearer(<redacted>)"),
            Self::ApiKey(_) => f.write_str("ApiKey(<redacted>)"),
        }
    }
}

/// Why credential metadata was rejected.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CredentialError {
    #[error("authorization metadata is not a Bearer token")]
    NotBearer,
    #[error("credential metadata is empty or not visible ASCII")]
    Malformed,
}

impl ClientCredential {
    /// Add this credential to outgoing request metadata, replacing any
    /// existing value for the same key.
    /// The value is marked sensitive, so `Debug` of the metadata or of the
    /// `tonic::Request` does not print it.
    pub fn apply(&self, metadata: &mut MetadataMap) -> Result<(), CredentialError> {
        match self {
            Self::Bearer(token) => {
                let mut value = MetadataValue::try_from(format!("{BEARER_PREFIX}{token}"))
                    .map_err(|_| CredentialError::Malformed)?;
                value.set_sensitive(true);
                metadata.insert(AUTHORIZATION, value);
            }
            Self::ApiKey(key) => {
                let mut value = MetadataValue::try_from(key.as_str())
                    .map_err(|_| CredentialError::Malformed)?;
                value.set_sensitive(true);
                metadata.insert(API_KEY, value);
            }
        }
        Ok(())
    }

    /// Read the credential from incoming request metadata. `Ok(None)` when
    /// neither key is present. The Bearer token is preferred.
    pub fn from_metadata(metadata: &MetadataMap) -> Result<Option<Self>, CredentialError> {
        if let Some(value) = metadata.get(AUTHORIZATION) {
            let value = value.to_str().map_err(|_| CredentialError::Malformed)?;
            let token = value
                .strip_prefix(BEARER_PREFIX)
                .ok_or(CredentialError::NotBearer)?
                .trim();
            if token.is_empty() {
                return Err(CredentialError::Malformed);
            }
            return Ok(Some(Self::Bearer(token.to_owned())));
        }
        if let Some(value) = metadata.get(API_KEY) {
            let key = value
                .to_str()
                .map_err(|_| CredentialError::Malformed)?
                .trim();
            if key.is_empty() {
                return Err(CredentialError::Malformed);
            }
            return Ok(Some(Self::ApiKey(key.to_owned())));
        }
        Ok(None)
    }
}

/// Mark every `authorization` and `x-api-key` value in `metadata` sensitive
/// so that `Debug` of the metadata or its request hides them. Servers call
/// this on incoming requests (for example in an interceptor) before anything
/// can log them.
pub fn mark_credentials_sensitive(metadata: &mut MetadataMap) {
    for key in [AUTHORIZATION, API_KEY] {
        if let tonic::metadata::Entry::Occupied(mut entry) = metadata
            .entry(key)
            .expect("credential keys are valid ASCII metadata keys")
        {
            for value in entry.iter_mut() {
                value.set_sensitive(true);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn outgoing_credentials_hidden_in_request_debug() {
        for cred in [
            ClientCredential::Bearer("jwt-SECRET".into()),
            ClientCredential::ApiKey("key-SECRET".into()),
        ] {
            let mut request = tonic::Request::new(());
            cred.apply(request.metadata_mut()).unwrap();
            let debug = format!("{request:?}");
            assert!(!debug.contains("SECRET"), "{debug}");
            assert!(!format!("{:?}", request.metadata()).contains("SECRET"));
            // Still readable by the server side.
            assert_eq!(
                ClientCredential::from_metadata(request.metadata()),
                Ok(Some(cred))
            );
        }
    }

    #[test]
    fn incoming_credentials_can_be_hidden() {
        let mut md = MetadataMap::new();
        md.insert("authorization", "Bearer jwt-SECRET".parse().unwrap());
        md.insert("x-api-key", "key-SECRET".parse().unwrap());
        md.append("x-api-key", "key2-SECRET".parse().unwrap());
        md.insert("x-request-id", "visible-id".parse().unwrap());
        assert!(format!("{md:?}").contains("SECRET"));
        mark_credentials_sensitive(&mut md);
        let debug = format!("{md:?}");
        assert!(!debug.contains("SECRET"), "{debug}");
        assert!(debug.contains("visible-id"), "{debug}");
        assert_eq!(
            ClientCredential::from_metadata(&md),
            Ok(Some(ClientCredential::Bearer("jwt-SECRET".into())))
        );
        // No credentials: nothing to do.
        let mut empty = MetadataMap::new();
        mark_credentials_sensitive(&mut empty);
        assert!(empty.is_empty());
    }

    #[test]
    fn bearer_round_trip() {
        let mut md = MetadataMap::new();
        let cred = ClientCredential::Bearer("a.b.c".into());
        cred.apply(&mut md).unwrap();
        assert_eq!(md.get("authorization").unwrap(), "Bearer a.b.c");
        assert_eq!(ClientCredential::from_metadata(&md), Ok(Some(cred)));
    }

    #[test]
    fn api_key_round_trip() {
        let mut md = MetadataMap::new();
        let cred = ClientCredential::ApiKey("mk_123".into());
        cred.apply(&mut md).unwrap();
        assert_eq!(md.get("x-api-key").unwrap(), "mk_123");
        assert_eq!(ClientCredential::from_metadata(&md), Ok(Some(cred)));
    }

    #[test]
    fn bearer_preferred_over_api_key() {
        let mut md = MetadataMap::new();
        ClientCredential::ApiKey("key".into())
            .apply(&mut md)
            .unwrap();
        ClientCredential::Bearer("jwt".into())
            .apply(&mut md)
            .unwrap();
        assert_eq!(
            ClientCredential::from_metadata(&md),
            Ok(Some(ClientCredential::Bearer("jwt".into())))
        );
    }

    #[test]
    fn missing_and_malformed() {
        let md = MetadataMap::new();
        assert_eq!(ClientCredential::from_metadata(&md), Ok(None));

        let mut md = MetadataMap::new();
        md.insert("authorization", "Basic dXNlcg==".parse().unwrap());
        assert_eq!(
            ClientCredential::from_metadata(&md),
            Err(CredentialError::NotBearer)
        );

        let mut md = MetadataMap::new();
        md.insert("authorization", "Bearer ".parse().unwrap());
        assert_eq!(
            ClientCredential::from_metadata(&md),
            Err(CredentialError::Malformed)
        );

        let mut md = MetadataMap::new();
        md.insert("x-api-key", "".parse().unwrap());
        assert_eq!(
            ClientCredential::from_metadata(&md),
            Err(CredentialError::Malformed)
        );

        let mut md = MetadataMap::new();
        assert_eq!(
            ClientCredential::Bearer("bad\nvalue".into()).apply(&mut md),
            Err(CredentialError::Malformed)
        );
    }

    #[test]
    fn debug_redacts() {
        let debug = format!("{:?}", ClientCredential::Bearer("secret-jwt".into()));
        assert!(!debug.contains("secret"));
    }
}
