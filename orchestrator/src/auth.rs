//! Credential authentication and the Zig-compatible password representation.

use base64::{Engine, engine::general_purpose::STANDARD};
use common::{ClientId, UserId};
use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Header, Validation};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use subtle::ConstantTimeEq;

/// JWT lifetime of seven days, in seconds.
pub const TOKEN_LIFETIME_SECONDS: i64 = 7 * 24 * 60 * 60;

/// Hash a password into Zig-compatible salt:key lowercase hex.
pub fn hash_password(password: &str) -> String {
    let salt: [u8; 16] = rand::random();
    let key = derive(password, &salt);
    format!("{}:{}", hex::encode(salt), hex::encode(key))
}

fn derive(password: &str, salt: &[u8]) -> [u8; 32] {
    pbkdf2::pbkdf2_hmac_array::<Sha256, 32>(password.as_bytes(), salt, 100_000)
}

/// Verify a stored hash in constant time; malformed hashes return false.
pub fn verify_password(password: &str, stored: &str) -> bool {
    let Some((salt, key)) = stored.split_once(':') else {
        return false;
    };
    if salt.len() != 32 || key.len() != 64 {
        return false;
    }
    let (Ok(salt), Ok(key)) = (hex::decode(salt), hex::decode(key)) else {
        return false;
    };
    bool::from(derive(password, &salt).as_slice().ct_eq(&key))
}

/// Generate a padded standard-base64 key from 32 random bytes.
pub fn generate_api_key() -> String {
    STANDARD.encode(rand::random::<[u8; 32]>())
}

/// Check the GitHub token length and the prefixes accepted by Zig.
pub fn validate_github_token(token: &str) -> bool {
    token.len() >= 10
        && ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"]
            .iter()
            .any(|p| token.starts_with(p))
}

/// Check repository URL length and HTTPS or SSH prefixes.
pub fn validate_repo_url(url: &str) -> bool {
    (10..=2048).contains(&url.len()) && (url.starts_with("https://") || url.starts_with("git@"))
}

/// HS256 token claims compatible with Zig-issued credentials.
#[derive(Serialize, Deserialize)]
pub struct Claims {
    /// User identifier encoded as 32 lowercase hex characters.
    pub sub: String,
    /// Account email address.
    pub email: String,
    /// Token issue time in Unix seconds.
    pub iat: i64,
    /// Exclusive token expiry time in Unix seconds.
    pub exp: i64,
}

/// Deliberately has no Debug implementation.
pub struct Jwt {
    secret: Vec<u8>,
}

impl Jwt {
    /// Use the configured JWT secret, or generate a random process-local secret.
    pub fn new(secret: Option<&str>) -> Self {
        Self {
            secret: match secret {
                Some(s) => s.as_bytes().to_vec(),
                None => {
                    tracing::warn!(
                        operation = "jwt_init",
                        "JWT secret absent; credentials expire on restart"
                    );
                    rand::random::<[u8; 32]>().to_vec()
                }
            },
        }
    }

    /// Issue an HS256 JWT for the account with a seven-day lifetime.
    pub fn create(&self, user: UserId, email: &str) -> Result<String, jsonwebtoken::errors::Error> {
        let now = common::types::now_ms() / 1000;
        jsonwebtoken::encode(
            &Header::new(Algorithm::HS256),
            &Claims {
                sub: user.to_hex(),
                email: email.into(),
                iat: now,
                exp: now + TOKEN_LIFETIME_SECONDS,
            },
            &EncodingKey::from_secret(&self.secret),
        )
    }

    /// Validate an HS256 token and decode its 16-byte owner, or return None.
    pub fn validate(&self, token: &str) -> Option<ClientId> {
        let mut validation = Validation::new(Algorithm::HS256);
        validation.leeway = 0;
        let claims = jsonwebtoken::decode::<Claims>(
            token,
            &DecodingKey::from_secret(&self.secret),
            &validation,
        )
        .ok()?
        .claims;
        // RFC 7519 expiry is exclusive. Deliberately reject Zig's final accepted second.
        // jsonwebtoken's clock comparison accepts equality, so check it explicitly.
        if claims.exp <= common::types::now_ms() / 1000 {
            return None;
        }
        ClientId::parse(&claims.sub).ok()
    }
}

/// An operation allowed by the default client permission set.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Permission {
    /// Submit a task for execution.
    SubmitTask,
    /// Cancel an owned task.
    CancelTask,
    /// Read the client usage report.
    ViewUsage,
    /// Perform administrative operations.
    Admin,
}

/// The permission set granted to every registered client.
pub struct ClientPermissions;

impl ClientPermissions {
    /// Return whether the default client permissions allow this operation.
    pub fn permits(permission: Permission) -> bool {
        permission != Permission::Admin
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ZIG_HASH: &str = "b9501776fc89a4fb1f1338b17d84b385:b95ddb619d0b4d5a83a7a9f1c1fc7cd4fd873672bdf0d3fb2d6906f3894da126";

    const ZIG_JWT: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhMGExYTJhM2E0YTVhNmE3YThhOWFhYWJhY2FkYWVhZiIsImVtYWlsIjoiemlnQGV4YW1wbGUuY29tIiwiaWF0IjoxNzkxMTkyMDQ1LCJleHAiOjQ5NDQ3OTIwNDV9.01YIXIuiJ6d8RtcP_DPFYqD27ONSJiProg5KRSUQwGI";

    const ZIG_EXPIRED: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhMGExYTJhM2E0YTVhNmE3YThhOWFhYWJhY2FkYWVhZiIsImVtYWlsIjoiemlnQGV4YW1wbGUuY29tIiwiaWF0IjoxNzkxMTkyMDQ1LCJleHAiOjE3OTExODg0NDV9.rFYWY_h0hanYJb2ySaAb-te5r6YadTjfumf-VR75B60";

    // Port of auth/auth.zig "github token validation"
    #[test]
    fn github_token_validation() {
        for prefix in ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"] {
            assert!(validate_github_token(&format!("{prefix}1234567890")));
        }
        for invalid in ["invalid", "short", "ghp_", "1234567890"] {
            assert!(!validate_github_token(invalid));
        }
    }

    // Port of auth/auth.zig "api key generation"
    #[test]
    fn api_key_generation() {
        let a = generate_api_key();
        assert_eq!(a.len(), 44);
        assert!(a.ends_with('='));
        assert_eq!(STANDARD.decode(&a).unwrap().len(), 32);
        assert_ne!(a, generate_api_key());
    }

    // Port of auth/auth.zig "authenticator generateClientId produces unique ids"
    #[test]
    fn unique_identity() {
        assert_ne!(UserId::random(), UserId::random());
    }

    // Port of auth/auth.zig "client permissions"
    #[test]
    fn client_permissions() {
        for p in [
            Permission::SubmitTask,
            Permission::CancelTask,
            Permission::ViewUsage,
        ] {
            assert!(ClientPermissions::permits(p));
        }
        assert!(!ClientPermissions::permits(Permission::Admin));
    }

    // Port of auth/auth.zig "password hash and verify"
    #[test]
    fn password_hash_and_verify() {
        let h = hash_password("password");
        assert_eq!(h.len(), 97);
        assert_eq!(&h[32..33], ":");
        assert_eq!(h, h.to_lowercase());
        assert!(verify_password("password", &h));
        assert!(!verify_password("wrong", &h));
        assert_ne!(h, hash_password("password"));
    }

    #[test]
    fn zig_password_fixture() {
        assert!(verify_password("zig-compat-password", ZIG_HASH));
        assert!(verify_password(
            "zig-compat-password",
            &ZIG_HASH.to_uppercase()
        ));
        assert!(!verify_password("wrong", ZIG_HASH));
    }

    #[test]
    fn malformed_hashes() {
        for s in [
            "",
            "abc",
            ":",
            "00:00",
            "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz:0000000000000000000000000000000000000000000000000000000000000000",
            &format!("{ZIG_HASH}:"),
        ] {
            assert!(!verify_password("password", s));
        }
    }

    // Port of auth/auth.zig "jwt create and validate"
    #[test]
    fn jwt_create_and_validate() {
        let j = Jwt::new(Some("secret"));
        let id = UserId::random();
        let t = j.create(id, "email").unwrap();
        assert_eq!(j.validate(&t), Some(ClientId(id.0)));
        let claims = jsonwebtoken::decode::<Claims>(
            &t,
            &DecodingKey::from_secret(b"secret"),
            &Validation::new(Algorithm::HS256),
        )
        .unwrap()
        .claims;
        assert_eq!(claims.exp - claims.iat, 604800);
    }

    // Port of auth/auth.zig "jwt rejects wrong secret"
    #[test]
    fn jwt_rejects_wrong_secret() {
        let t = Jwt::new(Some("one"))
            .create(UserId::random(), "email")
            .unwrap();
        assert!(Jwt::new(Some("two")).validate(&t).is_none());
    }

    #[test]
    fn zig_jwt_fixture_and_invalid_tokens() {
        let j = Jwt::new(Some("zig-compat-jwt-secret"));
        assert_eq!(
            j.validate(ZIG_JWT),
            Some(ClientId::parse("a0a1a2a3a4a5a6a7a8a9aaabacadaeaf").unwrap())
        );
        for bad in [
            ZIG_EXPIRED,
            "garbage",
            "eyJhbGciOiJub25lIn0.e30.",
            &ZIG_JWT.replace("eyJzdWI", "eyJzdWJ"),
        ] {
            assert!(j.validate(bad).is_none());
        }
        assert!(Jwt::new(Some("wrong")).validate(ZIG_JWT).is_none());
        let claims = Claims {
            sub: "bad-id".into(),
            email: "a".into(),
            iat: 0,
            exp: 4944792045,
        };
        let t = jsonwebtoken::encode(
            &Header::new(Algorithm::HS256),
            &claims,
            &EncodingKey::from_secret(b"zig-compat-jwt-secret"),
        )
        .unwrap();
        assert!(j.validate(&t).is_none());
    }

    // Port of grpc/server.zig "validateRepoUrl - accepts valid GitHub URLs"
    #[test]
    fn github_urls() {
        for s in [
            "https://github.com/user/repo",
            "https://github.com/org/project.git",
            "git@github.com:user/repo.git",
        ] {
            assert!(validate_repo_url(s));
        }
    }

    // Port of grpc/server.zig "validateRepoUrl - accepts valid GitLab URLs"
    #[test]
    fn gitlab_urls() {
        for s in [
            "https://gitlab.com/user/repo",
            "git@gitlab.com:user/repo.git",
        ] {
            assert!(validate_repo_url(s));
        }
    }

    // Port of grpc/server.zig "validateRepoUrl - accepts valid Bitbucket URLs"
    #[test]
    fn bitbucket_urls() {
        for s in [
            "https://bitbucket.org/user/repo",
            "git@bitbucket.org:user/repo.git",
        ] {
            assert!(validate_repo_url(s));
        }
    }

    // Port of grpc/server.zig "validateRepoUrl - rejects invalid URLs"
    #[test]
    fn invalid_urls() {
        for s in [
            "",
            "short",
            "http://github.com/user/repo",
            "ftp://github.com/user/repo",
            "file:///etc/passwd",
            &format!("https://{}", "a".repeat(2041)),
        ] {
            assert!(!validate_repo_url(s));
        }
        assert!(validate_repo_url(&format!("https://{}", "a".repeat(2040))));
    }

    #[test]
    fn jwt_expiry_is_exclusive() {
        let now = common::types::now_ms() / 1000;
        let claims = Claims {
            sub: UserId::random().to_hex(),
            email: "expiry@example.com".into(),
            iat: now - 1,
            exp: now,
        };
        let token = jsonwebtoken::encode(
            &Header::new(Algorithm::HS256),
            &claims,
            &EncodingKey::from_secret(b"expiry-test-secret"),
        )
        .unwrap();
        assert!(
            Jwt::new(Some("expiry-test-secret"))
                .validate(&token)
                .is_none()
        );
    }
}
