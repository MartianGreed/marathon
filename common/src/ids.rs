//! Fixed-size identifiers.
//!
//! Ids are random bytes. On the wire and in logs they are lowercase hex:
//! a [`TaskId`] is 32 bytes (64 characters), the others 16 bytes
//! (32 characters). Parsing accepts upper- or lowercase, formatting is always
//! lowercase.

use std::fmt;
use std::str::FromStr;

/// Why a hex id string was rejected.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum IdParseError {
    #[error("invalid id length: expected {expected} hex characters, got {actual}")]
    InvalidLength { expected: usize, actual: usize },
    #[error("invalid hex digit at position {position}")]
    InvalidHexDigit { position: usize },
}

const HEX: &[u8; 16] = b"0123456789abcdef";

fn hex_value(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

fn parse_hex<const N: usize>(s: &str) -> Result<[u8; N], IdParseError> {
    let bytes = s.as_bytes();
    if bytes.len() != N * 2 {
        return Err(IdParseError::InvalidLength {
            expected: N * 2,
            actual: bytes.len(),
        });
    }
    let mut out = [0u8; N];
    for (i, byte) in out.iter_mut().enumerate() {
        let hi =
            hex_value(bytes[i * 2]).ok_or(IdParseError::InvalidHexDigit { position: i * 2 })?;
        let lo = hex_value(bytes[i * 2 + 1]).ok_or(IdParseError::InvalidHexDigit {
            position: i * 2 + 1,
        })?;
        *byte = (hi << 4) | lo;
    }
    Ok(out)
}

fn write_hex(bytes: &[u8], f: &mut fmt::Formatter<'_>) -> fmt::Result {
    let mut buf = [0u8; 64];
    for (i, b) in bytes.iter().enumerate() {
        buf[i * 2] = HEX[usize::from(b >> 4)];
        buf[i * 2 + 1] = HEX[usize::from(b & 0x0f)];
    }
    // Only ASCII hex digits were written.
    f.write_str(std::str::from_utf8(&buf[..bytes.len() * 2]).map_err(|_| fmt::Error)?)
}

macro_rules! define_id {
    ($(#[$doc:meta])* $name:ident, $len:expr) => {
        $(#[$doc])*
        #[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Default)]
        pub struct $name(pub [u8; $len]);

        impl $name {
            /// Length in bytes.
            pub const LEN: usize = $len;

            /// A new random id.
            pub fn random() -> Self {
                Self(rand::random())
            }

            pub const fn from_bytes(bytes: [u8; $len]) -> Self {
                Self(bytes)
            }

            pub const fn as_bytes(&self) -> &[u8; $len] {
                &self.0
            }

            /// Parse the hex wire form. Accepts either case.
            pub fn parse(s: &str) -> Result<Self, IdParseError> {
                parse_hex::<$len>(s).map(Self)
            }

            /// The lowercase hex wire form.
            pub fn to_hex(&self) -> String {
                self.to_string()
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                write_hex(&self.0, f)
            }
        }

        impl fmt::Debug for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(f, "{}(", stringify!($name))?;
                write_hex(&self.0, f)?;
                f.write_str(")")
            }
        }

        impl FromStr for $name {
            type Err = IdParseError;

            fn from_str(s: &str) -> Result<Self, Self::Err> {
                Self::parse(s)
            }
        }

        impl From<[u8; $len]> for $name {
            fn from(bytes: [u8; $len]) -> Self {
                Self(bytes)
            }
        }
    };
}

define_id!(
    /// Task id, 32 bytes.
    TaskId,
    32
);
define_id!(
    /// Node id, 16 bytes.
    NodeId,
    16
);
define_id!(
    /// Firecracker VM id, 16 bytes.
    VmId,
    16
);
define_id!(
    /// Client id (the owner of tasks and usage), 16 bytes.
    ClientId,
    16
);
define_id!(
    /// User account id, 16 bytes.
    UserId,
    16
);

#[cfg(test)]
mod tests {
    use super::*;

    // Port of types.zig "id formatting".
    #[test]
    fn formats_lowercase_hex() {
        let mut bytes = [0u8; 16];
        bytes[..4].copy_from_slice(&[0xde, 0xad, 0xbe, 0xef]);
        let id = NodeId(bytes);
        assert_eq!(id.to_string(), "deadbeef000000000000000000000000");
        assert_eq!(
            format!("{id:?}"),
            "NodeId(deadbeef000000000000000000000000)"
        );
    }

    #[test]
    fn round_trips_every_byte_value() {
        let mut bytes = [0u8; 32];
        for (i, b) in bytes.iter_mut().enumerate() {
            *b = (i as u8).wrapping_mul(37).wrapping_add(0x0f);
        }
        let id = TaskId(bytes);
        let text = id.to_hex();
        assert_eq!(text.len(), 64);
        assert_eq!(text, text.to_lowercase());
        assert_eq!(TaskId::parse(&text), Ok(id));

        for v in 0..=255u8 {
            let id = ClientId([v; 16]);
            assert_eq!(id.to_string().parse::<ClientId>(), Ok(id));
        }
    }

    #[test]
    fn parse_accepts_uppercase() {
        let lower = "00112233445566778899aabbccddeeff";
        let upper = lower.to_uppercase();
        assert_eq!(NodeId::parse(&upper), NodeId::parse(lower));
        assert_eq!(NodeId::parse(&upper).unwrap().to_string(), lower);
    }

    #[test]
    fn parse_rejects_wrong_length() {
        assert_eq!(
            NodeId::parse("abcd"),
            Err(IdParseError::InvalidLength {
                expected: 32,
                actual: 4
            })
        );
        let node_hex = NodeId::random().to_hex();
        assert_eq!(
            TaskId::parse(&node_hex),
            Err(IdParseError::InvalidLength {
                expected: 64,
                actual: 32
            })
        );
        assert!(matches!(
            TaskId::parse(""),
            Err(IdParseError::InvalidLength { .. })
        ));
    }

    #[test]
    fn parse_rejects_non_hex() {
        let mut s = "0".repeat(32);
        s.replace_range(7..8, "g");
        assert_eq!(
            NodeId::parse(&s),
            Err(IdParseError::InvalidHexDigit { position: 7 })
        );
        let mut s = "0".repeat(32);
        s.replace_range(30..31, " ");
        assert_eq!(
            VmId::parse(&s),
            Err(IdParseError::InvalidHexDigit { position: 30 })
        );
        // Multi-byte UTF-8 with the right byte length is still rejected.
        let s = format!("{}é", "0".repeat(30));
        assert_eq!(s.len(), 32);
        assert!(matches!(
            UserId::parse(&s),
            Err(IdParseError::InvalidHexDigit { .. })
        ));
    }

    #[test]
    fn random_ids_differ() {
        assert_ne!(TaskId::random(), TaskId::random());
        assert_ne!(NodeId::random(), NodeId::random());
    }
}
