//! The `marathon` CLI.
//!
//! [`run`] executes one command line with injected configuration, HOME,
//! password prompt and output streams, so tests drive the whole CLI
//! in-process. `main.rs` wires it to the process.

pub mod cli;
pub mod commands;
pub mod connect;
pub mod credentials;

use std::io::Write;
use std::path::PathBuf;

use clap::Parser;
use common::config::{ClientConfig, ConfigError};
use common::telemetry::Operation;
use tracing::Instrument;

/// Exit status of a command.
pub type ExitCode = u8;
pub const EXIT_OK: ExitCode = 0;
pub const EXIT_FAILURE: ExitCode = 1;
pub const EXIT_USAGE: ExitCode = 2;

/// Everything a command reads from or writes to the outside world.
pub struct Context<'a> {
    /// Client configuration, or why it could not be loaded. Only commands
    /// that contact the orchestrator need it.
    pub config: Result<ClientConfig, ConfigError>,
    /// HOME, for the credentials file.
    pub home: Option<PathBuf>,
    /// Command results.
    pub out: &'a mut dyn Write,
    /// Progress and errors.
    pub err: &'a mut dyn Write,
    /// Reads a password when `--password` is not given. The argument is
    /// the prompt.
    pub password: &'a mut dyn FnMut(&str) -> std::io::Result<String>,
}

impl Context<'_> {
    pub fn credentials_path(&self) -> PathBuf {
        credentials::path(self.home.as_deref())
    }
}

/// Write a line to the result stream. Output errors (closed pipe) are
/// ignored, as there is nowhere left to report them.
#[macro_export]
macro_rules! out {
    ($ctx:expr, $($arg:tt)*) => {{
        let _ = writeln!($ctx.out, $($arg)*);
    }};
}

/// Write a line to the progress/error stream.
#[macro_export]
macro_rules! err {
    ($ctx:expr, $($arg:tt)*) => {{
        let _ = writeln!($ctx.err, $($arg)*);
    }};
}

/// Run one command line. `args[0]` is the program name.
pub async fn run(args: &[String], ctx: &mut Context<'_>) -> ExitCode {
    let Some(first) = args.get(1) else {
        let _ = write!(ctx.out, "{}", cli::USAGE);
        return EXIT_OK;
    };
    match cli::parse_command(first) {
        None => {
            err!(ctx, "Unknown command: {first}");
            let _ = write!(ctx.err, "{}", cli::USAGE);
            return EXIT_USAGE;
        }
        Some(cli::Command::Help) => {
            let _ = write!(ctx.out, "{}", cli::USAGE);
            return EXIT_OK;
        }
        Some(_) => {}
    }

    let parsed = match cli::Cli::try_parse_from(args) {
        Ok(parsed) => parsed,
        Err(e) => {
            use clap::error::ErrorKind;
            return match e.kind() {
                ErrorKind::DisplayHelp | ErrorKind::DisplayVersion => {
                    let _ = write!(ctx.out, "{}", e.render());
                    EXIT_OK
                }
                _ => {
                    let _ = write!(ctx.err, "{}", e.render());
                    EXIT_USAGE
                }
            };
        }
    };

    let name = commands::operation_name(&parsed.command);
    let op = Operation::start(name);
    tracing::debug!(operation = name, "command started");
    let code = commands::dispatch(parsed.command, ctx)
        .instrument(op.span().clone())
        .await;
    tracing::debug!(operation = name, exit_code = code, "command finished");
    op.finish();
    code
}
