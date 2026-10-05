//! `marathon` entry point.

use std::io::{BufRead, IsTerminal};
use std::path::PathBuf;

use common::config::ClientConfig;
use common::telemetry::LOG_FORMAT_VAR;
use marathon_client::{Context, run};
use tracing_subscriber::EnvFilter;

/// Logs are for diagnosis; the CLI's own messages are its output. Set
/// `RUST_LOG` (for example `RUST_LOG=debug`) to see them.
const DEFAULT_FILTER: &str = "off";

fn init_tracing() {
    let filter =
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(DEFAULT_FILTER));
    let json = std::env::var(LOG_FORMAT_VAR).is_ok_and(|v| v.eq_ignore_ascii_case("json"));
    let builder = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .with_target(true);
    let _ = if json {
        builder.json().flatten_event(true).try_init()
    } else {
        builder.try_init()
    };
}

/// No echo on a terminal; a line from stdin otherwise.
fn read_password(prompt: &str) -> std::io::Result<String> {
    if std::io::stdin().is_terminal() {
        return rpassword::prompt_password(prompt);
    }
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line)?;
    Ok(line.trim_end_matches(['\n', '\r']).to_owned())
}

fn main() -> std::process::ExitCode {
    init_tracing();
    let args: Vec<String> = std::env::args().collect();
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("Error: cannot start the async runtime: {e}");
            return std::process::ExitCode::FAILURE;
        }
    };
    let mut stdout = std::io::stdout();
    let mut stderr = std::io::stderr();
    let mut password = read_password;
    let mut ctx = Context {
        config: ClientConfig::from_env(),
        home: std::env::var_os("HOME").map(PathBuf::from),
        out: &mut stdout,
        err: &mut stderr,
        password: &mut password,
    };
    let code = runtime.block_on(run(&args, &mut ctx));
    std::process::ExitCode::from(code)
}
