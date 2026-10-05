//! `~/.marathon/credentials`, in the format the Zig client wrote:
//!
//! ```text
//! token=<jwt>
//! api_key=<api key>
//! email=<email>
//! ```
//!
//! Reading follows the Zig parser: lines split on `\n`, each key matched by
//! prefix, the last occurrence wins, and all three keys must be present.

use std::fmt;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use common::client_auth::ClientCredential;

/// Largest credentials file read, as in Zig.
pub const MAX_BYTES: u64 = 4096;

/// Directory under HOME, and the fallback root when HOME is unset.
const DIR: &str = ".marathon";
const FILE: &str = "credentials";
const FALLBACK_ROOT: &str = "/tmp";

/// Stored login.
#[derive(Clone, PartialEq, Eq)]
pub struct Credentials {
    pub token: String,
    pub api_key: String,
    pub email: String,
}

impl fmt::Debug for Credentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Credentials")
            .field("token", &"<redacted>")
            .field("api_key", &"<redacted>")
            .field("email", &self.email)
            .finish()
    }
}

#[derive(Debug, thiserror::Error)]
pub enum CredentialsError {
    #[error("credentials file {} is larger than {MAX_BYTES} bytes", path.display())]
    TooLarge { path: PathBuf },
    #[error("credentials file {} is not valid UTF-8", path.display())]
    NotUtf8 { path: PathBuf },
    #[error("credential field {field} contains a line break")]
    LineBreak { field: &'static str },
    #[error("{op} {}: {source}", path.display())]
    Io {
        op: &'static str,
        path: PathBuf,
        #[source]
        source: io::Error,
    },
}

/// `$HOME/.marathon/credentials`, or `/tmp/.marathon/credentials` without a
/// HOME, as in Zig.
///
/// The path is built by string concatenation, as Zig's
/// `"{s}/.marathon/credentials"` did, so an empty HOME gives the absolute
/// `/.marathon/credentials` rather than a path relative to the working
/// directory.
pub fn path(home: Option<&Path>) -> PathBuf {
    let mut path = home
        .unwrap_or(Path::new(FALLBACK_ROOT))
        .as_os_str()
        .to_owned();
    path.push(format!("/{DIR}/{FILE}"));
    PathBuf::from(path)
}

impl Credentials {
    /// Parse the file content with the Zig rules. `None` unless all three
    /// keys are present.
    pub fn parse(content: &str) -> Option<Self> {
        let mut token = None;
        let mut api_key = None;
        let mut email = None;
        for line in content.split('\n') {
            if let Some(v) = line.strip_prefix("token=") {
                token = Some(v);
            } else if let Some(v) = line.strip_prefix("api_key=") {
                api_key = Some(v);
            } else if let Some(v) = line.strip_prefix("email=") {
                email = Some(v);
            }
        }
        Some(Self {
            token: token?.to_owned(),
            api_key: api_key?.to_owned(),
            email: email?.to_owned(),
        })
    }

    /// File content, byte for byte what the Zig client wrote.
    pub fn serialize(&self) -> Result<String, CredentialsError> {
        for (field, value) in [
            ("token", &self.token),
            ("api_key", &self.api_key),
            ("email", &self.email),
        ] {
            if value.contains(['\n', '\r']) {
                return Err(CredentialsError::LineBreak { field });
            }
        }
        Ok(format!(
            "token={}\napi_key={}\nemail={}\n",
            self.token, self.api_key, self.email
        ))
    }

    /// The credential sent to the orchestrator: the API key, which does not
    /// expire, or the JWT when no API key is stored.
    pub fn credential(&self) -> Option<ClientCredential> {
        if !self.api_key.is_empty() {
            Some(ClientCredential::ApiKey(self.api_key.clone()))
        } else if !self.token.is_empty() {
            Some(ClientCredential::Bearer(self.token.clone()))
        } else {
            None
        }
    }

    /// API key for display: first 8 and last 4 characters, as in Zig. Keys
    /// too short to hide anything are masked entirely.
    pub fn masked_api_key(&self) -> String {
        let chars: Vec<char> = self.api_key.chars().collect();
        if chars.len() < 12 {
            return "****".to_owned();
        }
        let head: String = chars[..8].iter().collect();
        let tail: String = chars[chars.len() - 4..].iter().collect();
        format!("{head}...{tail}")
    }
}

fn io_err(op: &'static str, path: &Path) -> impl FnOnce(io::Error) -> CredentialsError + use<> {
    let path = path.to_owned();
    move |source| CredentialsError::Io { op, path, source }
}

/// Read the credentials. `Ok(None)` when the file is missing or incomplete.
pub fn load(path: &Path) -> Result<Option<Credentials>, CredentialsError> {
    let meta = match fs::metadata(path) {
        Ok(m) => m,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(io_err("read", path)(e)),
    };
    if meta.len() > MAX_BYTES {
        return Err(CredentialsError::TooLarge {
            path: path.to_owned(),
        });
    }
    let bytes = fs::read(path).map_err(io_err("read", path))?;
    let content = String::from_utf8(bytes).map_err(|_| CredentialsError::NotUtf8 {
        path: path.to_owned(),
    })?;
    Ok(Credentials::parse(&content))
}

/// Write the credentials with mode 0600, creating the directory (0700) when
/// missing. The content goes to a temporary file in the same directory that
/// is renamed over the target, so an existing file never keeps a looser mode
/// and a failed write never leaves a truncated file.
pub fn save(path: &Path, creds: &Credentials) -> Result<(), CredentialsError> {
    let content = creds.serialize()?;
    let dir = path.parent().unwrap_or(Path::new("."));
    create_private_dir(dir).map_err(io_err("create directory", dir))?;

    let tmp = dir.join(format!(".{FILE}.{}.tmp", std::process::id()));
    let written = write_private(&tmp, content.as_bytes()).and_then(|()| fs::rename(&tmp, path));
    if let Err(e) = written {
        let _ = fs::remove_file(&tmp);
        return Err(io_err("write", path)(e));
    }
    tracing::debug!(path = %path.display(), operation = "save_credentials", "credentials saved");
    Ok(())
}

/// Remove the credentials. A missing file is not an error.
pub fn delete(path: &Path) -> Result<(), CredentialsError> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(io_err("remove", path)(e)),
    }
}

#[cfg(unix)]
fn create_private_dir(dir: &Path) -> io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
}

#[cfg(not(unix))]
fn create_private_dir(dir: &Path) -> io::Result<()> {
    fs::create_dir_all(dir)
}

#[cfg(unix)]
fn write_private(path: &Path, content: &[u8]) -> io::Result<()> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    // The mode passed to open is reduced by the umask; 0600 is the target
    // whatever the umask.
    file.set_permissions(fs::Permissions::from_mode(0o600))?;
    file.write_all(content)?;
    file.sync_all()
}

#[cfg(not(unix))]
fn write_private(path: &Path, content: &[u8]) -> io::Result<()> {
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)?;
    file.write_all(content)?;
    file.sync_all()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn creds() -> Credentials {
        Credentials {
            token: "eyJ.payload.sig".into(),
            api_key: "mk_0123456789abcdef".into(),
            email: "user@example.com".into(),
        }
    }

    #[test]
    fn path_under_home_or_tmp() {
        assert_eq!(
            path(Some(Path::new("/home/u"))),
            PathBuf::from("/home/u/.marathon/credentials")
        );
        assert_eq!(path(None), PathBuf::from("/tmp/.marathon/credentials"));
        // Empty HOME: Zig's concatenation gives an absolute path, never one
        // relative to the working directory.
        assert_eq!(
            path(Some(Path::new(""))),
            PathBuf::from("/.marathon/credentials")
        );
        // A trailing slash is kept as Zig did; the OS resolves `//`.
        assert_eq!(
            path(Some(Path::new("/home/u/"))),
            PathBuf::from("/home/u//.marathon/credentials")
        );
    }

    #[test]
    fn serialize_matches_zig_format() {
        assert_eq!(
            creds().serialize().unwrap(),
            "token=eyJ.payload.sig\napi_key=mk_0123456789abcdef\nemail=user@example.com\n"
        );
    }

    #[test]
    fn parse_zig_rules() {
        // Any order, unknown lines ignored, values keep `=`.
        let c = Credentials::parse("email=a@b\nfoo=bar\napi_key=k=1\ntoken=t\n").unwrap();
        assert_eq!(c.email, "a@b");
        assert_eq!(c.api_key, "k=1");
        assert_eq!(c.token, "t");
        // Last occurrence wins.
        let c = Credentials::parse("token=a\napi_key=k1\nemail=e1\ntoken=b\napi_key=k2\nemail=e2")
            .unwrap();
        assert_eq!(c.token, "b");
        assert_eq!(c.api_key, "k2");
        assert_eq!(c.email, "e2");
        // Empty values count as present.
        let c = Credentials::parse("token=\napi_key=\nemail=\n").unwrap();
        assert_eq!(c.token, "");
        // Any key missing: no credentials.
        assert_eq!(Credentials::parse("token=t\napi_key=k\n"), None);
        assert_eq!(Credentials::parse("token=t\nemail=e\n"), None);
        assert_eq!(Credentials::parse("api_key=k\nemail=e\n"), None);
        assert_eq!(Credentials::parse(""), None);
        // Prefix match is exact: leading spaces are not trimmed.
        assert_eq!(Credentials::parse(" token=t\napi_key=k\nemail=e\n"), None);
        // `\r` is kept, as Zig split on `\n` only.
        let c = Credentials::parse("token=t\r\napi_key=k\r\nemail=e\r\n").unwrap();
        assert_eq!(c.token, "t\r");
    }

    #[test]
    fn serialize_rejects_line_breaks() {
        let mut c = creds();
        c.email = "a@b\ntoken=evil".into();
        assert!(matches!(
            c.serialize(),
            Err(CredentialsError::LineBreak { field: "email" })
        ));
        let mut c = creds();
        c.token = "t\r".into();
        assert!(matches!(
            c.serialize(),
            Err(CredentialsError::LineBreak { field: "token" })
        ));
    }

    #[test]
    fn credential_prefers_api_key() {
        assert_eq!(
            creds().credential(),
            Some(ClientCredential::ApiKey("mk_0123456789abcdef".into()))
        );
        let mut c = creds();
        c.api_key.clear();
        assert_eq!(
            c.credential(),
            Some(ClientCredential::Bearer("eyJ.payload.sig".into()))
        );
        c.token.clear();
        assert_eq!(c.credential(), None);
    }

    #[test]
    fn masked_api_key() {
        assert_eq!(creds().masked_api_key(), "mk_01234...cdef");
        let mut c = creds();
        c.api_key = "123456789012".into();
        assert_eq!(c.masked_api_key(), "12345678...9012");
        c.api_key = "12345678901".into();
        assert_eq!(c.masked_api_key(), "****");
        c.api_key.clear();
        assert_eq!(c.masked_api_key(), "****");
    }

    #[test]
    fn debug_redacts_secrets() {
        let debug = format!("{:?}", creds());
        assert!(!debug.contains("payload"), "{debug}");
        assert!(!debug.contains("0123456789"), "{debug}");
        assert!(debug.contains("user@example.com"));
    }

    #[test]
    fn save_load_delete_round_trip() {
        let home = tempfile::tempdir().unwrap();
        let p = path(Some(home.path()));
        assert_eq!(load(&p).unwrap(), None);
        save(&p, &creds()).unwrap();
        assert_eq!(load(&p).unwrap(), Some(creds()));
        assert_eq!(
            fs::read_to_string(&p).unwrap(),
            creds().serialize().unwrap()
        );
        // No temporary file is left behind.
        let entries: Vec<_> = fs::read_dir(p.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(entries, vec![std::ffi::OsString::from("credentials")]);
        delete(&p).unwrap();
        assert!(!p.exists());
        // Deleting again is fine.
        delete(&p).unwrap();
    }

    #[test]
    fn save_overwrites() {
        let home = tempfile::tempdir().unwrap();
        let p = path(Some(home.path()));
        save(&p, &creds()).unwrap();
        let mut other = creds();
        other.email = "other@example.com".into();
        save(&p, &other).unwrap();
        assert_eq!(load(&p).unwrap(), Some(other));
    }

    /// The new content replaces the file by rename: the old file is never
    /// rewritten in place, so a crash or a failed write cannot leave it
    /// truncated. A hard link to the old file keeps the old bytes.
    #[test]
    fn save_replaces_by_rename() {
        let home = tempfile::tempdir().unwrap();
        let p = path(Some(home.path()));
        save(&p, &creds()).unwrap();
        let witness = home.path().join("witness");
        fs::hard_link(&p, &witness).unwrap();
        let mut other = creds();
        other.email = "other@example.com".into();
        save(&p, &other).unwrap();
        assert_eq!(load(&p).unwrap(), Some(other));
        assert_eq!(
            fs::read_to_string(&witness).unwrap(),
            creds().serialize().unwrap()
        );
    }

    /// A failed write keeps the existing credentials untouched.
    #[cfg(unix)]
    #[test]
    fn failed_save_keeps_existing_file() {
        use std::os::unix::fs::PermissionsExt;
        let home = tempfile::tempdir().unwrap();
        let p = path(Some(home.path()));
        save(&p, &creds()).unwrap();
        let dir = p.parent().unwrap();
        // The temporary file cannot be created in a read-only directory.
        fs::set_permissions(dir, fs::Permissions::from_mode(0o500)).unwrap();
        if fs::write(dir.join("probe"), b"").is_ok() {
            // Running as root: directory permissions are not enforced.
            fs::set_permissions(dir, fs::Permissions::from_mode(0o700)).unwrap();
            return;
        }
        let mut other = creds();
        other.email = "other@example.com".into();
        let result = save(&p, &other);
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(result.is_err());
        assert_eq!(load(&p).unwrap(), Some(creds()));
    }

    #[test]
    fn save_rejects_line_breaks_without_writing() {
        let home = tempfile::tempdir().unwrap();
        let p = path(Some(home.path()));
        let mut c = creds();
        c.api_key = "k\nemail=x".into();
        assert!(save(&p, &c).is_err());
        assert!(!p.exists());
    }

    #[cfg(unix)]
    #[test]
    fn file_mode_0600_and_dir_0700() {
        use std::os::unix::fs::PermissionsExt;
        let home = tempfile::tempdir().unwrap();
        let p = path(Some(home.path()));
        save(&p, &creds()).unwrap();
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&p), 0o600);
        assert_eq!(mode(p.parent().unwrap()), 0o700);

        // An existing world-readable file ends at 0600 after a save.
        fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
        save(&p, &creds()).unwrap();
        assert_eq!(mode(&p), 0o600);
    }

    #[cfg(unix)]
    #[test]
    fn existing_directory_mode_untouched() {
        use std::os::unix::fs::PermissionsExt;
        let home = tempfile::tempdir().unwrap();
        let dir = home.path().join(".marathon");
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
        save(&path(Some(home.path())), &creds()).unwrap();
        assert_eq!(
            fs::metadata(&dir).unwrap().permissions().mode() & 0o777,
            0o755
        );
    }

    #[test]
    fn load_limits() {
        let home = tempfile::tempdir().unwrap();
        let p = path(Some(home.path()));
        fs::create_dir_all(p.parent().unwrap()).unwrap();

        let mut content = creds().serialize().unwrap();
        content.push_str(&"#".repeat(MAX_BYTES as usize - content.len()));
        fs::write(&p, &content).unwrap();
        assert_eq!(load(&p).unwrap(), Some(creds()));

        content.push('#');
        fs::write(&p, &content).unwrap();
        assert!(matches!(load(&p), Err(CredentialsError::TooLarge { .. })));

        fs::write(&p, b"token=\xff\napi_key=k\nemail=e\n").unwrap();
        assert!(matches!(load(&p), Err(CredentialsError::NotUtf8 { .. })));
    }
}
