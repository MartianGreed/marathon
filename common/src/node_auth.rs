//! Node authentication token.
//!
//! A node proves it holds the shared `MARATHON_NODE_AUTH_KEY` by sending
//!
//! ```text
//! token = HMAC-SHA256(key, node_id (16 raw bytes) || timestamp_ms (i64 little-endian))
//! ```
//!
//! in the `NodeAuth` of every `NodeService` message. The orchestrator accepts
//! a timestamp within [`MAX_CLOCK_SKEW_MS`] of its own clock in either
//! direction and compares tokens in constant time.
//!
//! The token does not cover the rest of the message, so it can be replayed
//! for the length of the skew window; TLS on the node connection is the
//! mitigation. This is the same construction the Zig implementation used.

use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;
use subtle::ConstantTimeEq;

use crate::ids::{IdParseError, NodeId};
use crate::pb;

/// Token length in bytes.
pub const TOKEN_LEN: usize = 32;

/// Largest accepted difference between the node's timestamp and the
/// orchestrator's clock: 5 minutes.
pub const MAX_CLOCK_SKEW_MS: i64 = 5 * 60 * 1000;

/// Why a node token was rejected.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum NodeAuthError {
    #[error("node auth is missing")]
    Missing,
    #[error("invalid node id: {0}")]
    InvalidNodeId(#[from] IdParseError),
    #[error("node auth token must be {TOKEN_LEN} bytes, got {0}")]
    InvalidTokenLength(usize),
    #[error("node timestamp is {skew_ms} ms away from the orchestrator clock")]
    ClockSkew { skew_ms: i64 },
    #[error("node auth token does not match")]
    BadToken,
}

fn mac(key: &[u8], node_id: &NodeId, timestamp_ms: i64) -> Hmac<Sha256> {
    // HMAC accepts keys of any length; this cannot fail.
    let mut mac =
        <Hmac<Sha256> as KeyInit>::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(node_id.as_bytes());
    mac.update(&timestamp_ms.to_le_bytes());
    mac
}

/// The token for `node_id` at `timestamp_ms`.
pub fn sign(key: &[u8], node_id: &NodeId, timestamp_ms: i64) -> [u8; TOKEN_LEN] {
    mac(key, node_id, timestamp_ms)
        .finalize()
        .into_bytes()
        .into()
}

/// Check a token against `key` and the orchestrator clock `now_ms`.
///
/// The length and clock checks run before the constant-time comparison.
pub fn verify(
    key: &[u8],
    node_id: &NodeId,
    timestamp_ms: i64,
    token: &[u8],
    now_ms: i64,
) -> Result<(), NodeAuthError> {
    if token.len() != TOKEN_LEN {
        return Err(NodeAuthError::InvalidTokenLength(token.len()));
    }
    let skew_ms = now_ms.saturating_sub(timestamp_ms).saturating_abs();
    if skew_ms > MAX_CLOCK_SKEW_MS {
        return Err(NodeAuthError::ClockSkew { skew_ms });
    }
    let expected = sign(key, node_id, timestamp_ms);
    if bool::from(expected.as_slice().ct_eq(token)) {
        Ok(())
    } else {
        Err(NodeAuthError::BadToken)
    }
}

/// A `NodeAuth` for `node_id` at `timestamp_ms`. Without a key the token is
/// empty.
pub fn node_auth(key: Option<&[u8]>, node_id: &NodeId, timestamp_ms: i64) -> pb::NodeAuth {
    pb::NodeAuth {
        node_id: node_id.to_hex(),
        timestamp_ms,
        token: key
            .map(|k| sign(k, node_id, timestamp_ms).to_vec())
            .unwrap_or_default(),
    }
}

/// Parse and verify a received `NodeAuth`, returning the node id.
pub fn verify_node_auth(
    key: &[u8],
    auth: Option<&pb::NodeAuth>,
    now_ms: i64,
) -> Result<NodeId, NodeAuthError> {
    let auth = auth.ok_or(NodeAuthError::Missing)?;
    let node_id = NodeId::parse(&auth.node_id)?;
    verify(key, &node_id, auth.timestamp_ms, &auth.token, now_ms)?;
    Ok(node_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &[u8] = b"shared-node-key";

    fn node() -> NodeId {
        NodeId::parse("000102030405060708090a0b0c0d0e0f").unwrap()
    }

    #[test]
    fn known_answer() {
        // Independent reference: Python
        //   hmac.new(b"shared-node-key",
        //            bytes(range(16)) + (1700000000000).to_bytes(8, "little", signed=True),
        //            hashlib.sha256).hexdigest()
        let token = sign(KEY, &node(), 1_700_000_000_000);
        let hex: String = token.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, KNOWN_TOKEN_HEX);
    }

    const KNOWN_TOKEN_HEX: &str =
        "65931a9fcea57f2c5e145d7b5b099b36893bf5a370576a3e5432adb63eae895d";

    /// The window is a security property: pin it with literals, not the
    /// constant under test.
    #[test]
    fn skew_window_is_exactly_300000_ms() {
        assert_eq!(MAX_CLOCK_SKEW_MS, 300_000);
        let ts = 1_700_000_000_000_i64;
        let token = sign(KEY, &node(), ts);
        assert_eq!(verify(KEY, &node(), ts, &token, ts + 300_000), Ok(()));
        assert_eq!(verify(KEY, &node(), ts, &token, ts - 300_000), Ok(()));
        assert_eq!(
            verify(KEY, &node(), ts, &token, ts + 300_001),
            Err(NodeAuthError::ClockSkew { skew_ms: 300_001 })
        );
        assert_eq!(
            verify(KEY, &node(), ts, &token, ts - 300_001),
            Err(NodeAuthError::ClockSkew { skew_ms: 300_001 })
        );
    }

    #[test]
    fn sign_then_verify() {
        let now = 1_700_000_000_000;
        let token = sign(KEY, &node(), now);
        assert_eq!(verify(KEY, &node(), now, &token, now), Ok(()));
    }

    #[test]
    fn clock_skew_window_is_inclusive_five_minutes() {
        let ts = 1_700_000_000_000;
        let token = sign(KEY, &node(), ts);
        for now in [ts + MAX_CLOCK_SKEW_MS, ts - MAX_CLOCK_SKEW_MS] {
            assert_eq!(verify(KEY, &node(), ts, &token, now), Ok(()));
        }
        for now in [ts + MAX_CLOCK_SKEW_MS + 1, ts - MAX_CLOCK_SKEW_MS - 1] {
            assert_eq!(
                verify(KEY, &node(), ts, &token, now),
                Err(NodeAuthError::ClockSkew {
                    skew_ms: MAX_CLOCK_SKEW_MS + 1
                })
            );
        }
        // Extreme values do not overflow.
        assert!(matches!(
            verify(KEY, &node(), i64::MIN, &[0; TOKEN_LEN], i64::MAX),
            Err(NodeAuthError::ClockSkew { .. })
        ));
    }

    #[test]
    fn rejects_wrong_key_node_timestamp_or_token() {
        let ts = 1_700_000_000_000;
        let token = sign(KEY, &node(), ts);
        assert_eq!(
            verify(b"other-key", &node(), ts, &token, ts),
            Err(NodeAuthError::BadToken)
        );
        assert_eq!(
            verify(KEY, &NodeId::random(), ts, &token, ts),
            Err(NodeAuthError::BadToken)
        );
        assert_eq!(
            verify(KEY, &node(), ts + 1, &token, ts),
            Err(NodeAuthError::BadToken)
        );
        for i in 0..TOKEN_LEN {
            let mut bad = token;
            bad[i] ^= 0x01;
            assert_eq!(
                verify(KEY, &node(), ts, &bad, ts),
                Err(NodeAuthError::BadToken),
                "byte {i}"
            );
        }
    }

    #[test]
    fn rejects_wrong_token_length() {
        let ts = 1_700_000_000_000;
        let token = sign(KEY, &node(), ts);
        assert_eq!(
            verify(KEY, &node(), ts, &[], ts),
            Err(NodeAuthError::InvalidTokenLength(0))
        );
        assert_eq!(
            verify(KEY, &node(), ts, &token[..31], ts),
            Err(NodeAuthError::InvalidTokenLength(31))
        );
        let mut long = token.to_vec();
        long.push(0);
        assert_eq!(
            verify(KEY, &node(), ts, &long, ts),
            Err(NodeAuthError::InvalidTokenLength(33))
        );
    }

    #[test]
    fn timestamp_is_little_endian() {
        // Big-endian encoding of the same timestamp gives a different token.
        let ts: i64 = 1_700_000_000_000;
        let mut be = <Hmac<Sha256> as KeyInit>::new_from_slice(KEY).unwrap();
        be.update(node().as_bytes());
        be.update(&ts.to_be_bytes());
        let be: [u8; TOKEN_LEN] = be.finalize().into_bytes().into();
        assert_ne!(be, sign(KEY, &node(), ts));
    }

    #[test]
    fn node_auth_message_round_trip() {
        let now = 1_700_000_000_000;
        let auth = node_auth(Some(KEY), &node(), now);
        assert_eq!(auth.node_id, "000102030405060708090a0b0c0d0e0f");
        assert_eq!(auth.token.len(), TOKEN_LEN);
        assert_eq!(verify_node_auth(KEY, Some(&auth), now + 1000), Ok(node()));

        let unsigned = node_auth(None, &node(), now);
        assert!(unsigned.token.is_empty());
        assert_eq!(
            verify_node_auth(KEY, Some(&unsigned), now),
            Err(NodeAuthError::InvalidTokenLength(0))
        );
        assert_eq!(
            verify_node_auth(KEY, None, now),
            Err(NodeAuthError::Missing)
        );

        let mut bad_id = auth.clone();
        bad_id.node_id = "not-hex".into();
        assert!(matches!(
            verify_node_auth(KEY, Some(&bad_id), now),
            Err(NodeAuthError::InvalidNodeId(_))
        ));

        // Uppercase node ids verify against the same bytes.
        let mut upper = auth.clone();
        upper.node_id = upper.node_id.to_uppercase();
        assert_eq!(verify_node_auth(KEY, Some(&upper), now), Ok(node()));
    }
}
