//! Command-line definition. Commands, flags and help keep the Zig CLI's
//! names and meaning.

use clap::{Args, Parser, Subcommand};
use common::config::parse_zig_unsigned;
use common::pb;

/// Top-level help, the Zig usage text.
pub const USAGE: &str = "\
Marathon CLI - Distributed Claude Code Runner

Usage: marathon <command> [options]

Commands:
  register             Create a new account
  login                Authenticate with your account
  logout               Remove stored credentials
  whoami               Show current authenticated user
  submit               Submit a new task
  status <task-id>     Check task status
  cancel <task-id>     Cancel a running task
  usage                Get usage report
  help                 Show this help

Auth Options (login/register):
  --email <email>      Email address
  --password <pass>    Password (prompted if not provided)

Submit Options:
  --repo <url>       Repository URL (required)
  --branch <name>    Branch name (default: main)
  --prompt <text>    Task prompt (required)
  --pr               Create a PR on completion
  --pr-title <text>  PR title
  --pr-body <text>   PR body
  -e KEY=VALUE       Environment variable for the agent (repeatable)
  --max-iterations N Max ralph loop iterations (default: 50)
  --completion-promise <text>  String that signals task completion
  -f, --follow       Stream task events in real-time until completion

Status Options:
  -f, --follow       Stream the task's events until it finishes

Environment Variables:
  MARATHON_ORCHESTRATOR_ADDRESS  Orchestrator address
  MARATHON_ORCHESTRATOR_PORT     Orchestrator port
  GITHUB_TOKEN                   GitHub token for repo access

Examples:
  marathon register --email user@example.com --password mypassword
  marathon login --email user@example.com --password mypassword
  marathon whoami
  marathon submit --repo https://github.com/user/repo --prompt \"Fix the bug\"
  marathon submit --repo https://github.com/user/repo --prompt \"Build feature\" -e DATABASE_URL=postgres://... -e API_KEY=sk-xxx --max-iterations 10 --completion-promise \"TASK_COMPLETE\"
  marathon status abc123
  marathon status abc123 --follow
  marathon cancel abc123
  marathon usage
";

/// The first argument, as the Zig `parseCommand` matched it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Command {
    Submit,
    Status,
    Cancel,
    Usage,
    Login,
    Register,
    Whoami,
    Logout,
    Help,
}

pub fn parse_command(arg: &str) -> Option<Command> {
    Some(match arg {
        "submit" => Command::Submit,
        "status" => Command::Status,
        "cancel" => Command::Cancel,
        "usage" => Command::Usage,
        "login" => Command::Login,
        "register" => Command::Register,
        "whoami" => Command::Whoami,
        "logout" => Command::Logout,
        "help" | "--help" | "-h" => Command::Help,
        _ => return None,
    })
}

#[derive(Debug, Parser)]
#[command(
    name = "marathon",
    override_help = USAGE,
    disable_help_subcommand = true,
    disable_version_flag = true,
    args_override_self = true
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Cmd,
}

#[derive(Debug, Subcommand)]
pub enum Cmd {
    /// Create a new account
    Register(AuthArgs),
    /// Authenticate with your account
    Login(AuthArgs),
    /// Remove stored credentials
    Logout,
    /// Show current authenticated user
    Whoami,
    /// Submit a new task
    Submit(SubmitArgs),
    /// Check task status
    Status(StatusArgs),
    /// Cancel a running task
    Cancel(TaskArgs),
    /// Get usage report
    Usage,
}

#[derive(Debug, Args)]
pub struct AuthArgs {
    /// Email address
    #[arg(long, value_name = "email")]
    pub email: Option<String>,
    /// Password (prompted if not provided)
    #[arg(long, value_name = "pass", allow_hyphen_values = true)]
    pub password: Option<String>,
}

#[derive(Debug, Args)]
pub struct SubmitArgs {
    /// Repository URL (required)
    #[arg(long, value_name = "url")]
    pub repo: Option<String>,
    /// Branch name
    #[arg(long, value_name = "name", default_value = "main")]
    pub branch: String,
    /// Task prompt (required)
    #[arg(long, value_name = "text", allow_hyphen_values = true)]
    pub prompt: Option<String>,
    /// Create a PR on completion
    #[arg(long)]
    pub pr: bool,
    /// PR title
    #[arg(long, value_name = "text", allow_hyphen_values = true)]
    pub pr_title: Option<String>,
    /// PR body
    #[arg(long, value_name = "text", allow_hyphen_values = true)]
    pub pr_body: Option<String>,
    /// Environment variable for the agent (repeatable)
    #[arg(
        short = 'e',
        long = "env",
        value_name = "KEY=VALUE",
        value_parser = parse_env_var,
        allow_hyphen_values = true
    )]
    pub env: Vec<pb::EnvVar>,
    /// Max ralph loop iterations (default: 50)
    #[arg(long, value_name = "N", value_parser = parse_u32)]
    pub max_iterations: Option<u32>,
    /// String that signals task completion
    #[arg(long, value_name = "text", allow_hyphen_values = true)]
    pub completion_promise: Option<String>,
    /// Stream task events in real-time until completion
    #[arg(short = 'f', long)]
    pub follow: bool,
}

#[derive(Debug, Args)]
pub struct TaskArgs {
    /// Task id
    #[arg(value_name = "task-id")]
    pub task_id: Option<String>,
}

#[derive(Debug, Args)]
pub struct StatusArgs {
    /// Task id
    #[arg(value_name = "task-id")]
    pub task_id: Option<String>,
    /// Stream the task's events until it finishes
    #[arg(short = 'f', long)]
    pub follow: bool,
}

/// `KEY=VALUE`, split at the first `=`, as in Zig.
pub fn parse_env_var(arg: &str) -> Result<pb::EnvVar, String> {
    match arg.split_once('=') {
        Some((key, value)) => Ok(pb::EnvVar {
            key: key.to_owned(),
            value: value.to_owned(),
        }),
        None => Err(format!("-e requires KEY=VALUE format, got: {arg}")),
    }
}

/// An unsigned 32-bit integer with Zig `parseInt` rules.
fn parse_u32(arg: &str) -> Result<u32, String> {
    parse_zig_unsigned(arg).ok_or_else(|| format!("invalid number: {arg}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Port of the Zig `command parsing` test.
    #[test]
    fn command_parsing() {
        assert_eq!(parse_command("submit"), Some(Command::Submit));
        assert_eq!(parse_command("login"), Some(Command::Login));
        assert_eq!(parse_command("register"), Some(Command::Register));
        assert_eq!(parse_command("whoami"), Some(Command::Whoami));
        assert_eq!(parse_command("logout"), Some(Command::Logout));
        assert_eq!(parse_command("help"), Some(Command::Help));
        assert_eq!(parse_command("invalid"), None);
    }

    #[test]
    fn command_parsing_all_names() {
        assert_eq!(parse_command("status"), Some(Command::Status));
        assert_eq!(parse_command("cancel"), Some(Command::Cancel));
        assert_eq!(parse_command("usage"), Some(Command::Usage));
        assert_eq!(parse_command("--help"), Some(Command::Help));
        assert_eq!(parse_command("-h"), Some(Command::Help));
        assert_eq!(parse_command("Submit"), None);
        assert_eq!(parse_command(""), None);
    }

    fn parse(args: &[&str]) -> Result<Cli, clap::Error> {
        Cli::try_parse_from(std::iter::once("marathon").chain(args.iter().copied()))
    }

    #[test]
    fn submit_flags() {
        let cli = parse(&[
            "submit",
            "--repo",
            "https://github.com/u/r",
            "--prompt",
            "-starts with dash",
            "--pr",
            "--pr-title",
            "T",
            "--pr-body",
            "B",
            "-e",
            "A=1",
            "--env",
            "B=x=y",
            "-e",
            "A=2",
            "--max-iterations",
            "1_0",
            "--completion-promise",
            "DONE",
            "-f",
        ])
        .unwrap();
        let Cmd::Submit(s) = cli.command else {
            panic!("not submit")
        };
        assert_eq!(s.repo.as_deref(), Some("https://github.com/u/r"));
        assert_eq!(s.branch, "main");
        assert_eq!(s.prompt.as_deref(), Some("-starts with dash"));
        assert!(s.pr);
        assert_eq!(s.pr_title.as_deref(), Some("T"));
        assert_eq!(s.pr_body.as_deref(), Some("B"));
        let env: Vec<(&str, &str)> = s
            .env
            .iter()
            .map(|e| (e.key.as_str(), e.value.as_str()))
            .collect();
        assert_eq!(env, [("A", "1"), ("B", "x=y"), ("A", "2")]);
        assert_eq!(s.max_iterations, Some(10));
        assert_eq!(s.completion_promise.as_deref(), Some("DONE"));
        assert!(s.follow);
    }

    #[test]
    fn submit_defaults_and_last_value_wins() {
        let Cmd::Submit(s) = parse(&["submit", "--branch", "a", "--branch", "b"])
            .unwrap()
            .command
        else {
            panic!("not submit")
        };
        assert_eq!(s.branch, "b");
        assert_eq!(s.repo, None);
        assert_eq!(s.prompt, None);
        assert!(!s.pr && !s.follow);
        assert!(s.env.is_empty());
        assert_eq!(s.max_iterations, None);

        let Cmd::Submit(s) = parse(&["submit", "--follow"]).unwrap().command else {
            panic!("not submit")
        };
        assert!(s.follow);
    }

    #[test]
    fn submit_rejects_bad_values() {
        let err = parse(&["submit", "-e", "NOEQUALS"]).unwrap_err();
        assert!(err.to_string().contains("KEY=VALUE"), "{err}");
        for bad in ["-1", "ten", "4294967296", "_1"] {
            assert!(
                parse(&["submit", "--max-iterations", bad]).is_err(),
                "{bad}"
            );
        }
        assert!(parse(&["submit", "--max-iterations", "4294967295"]).is_ok());
        assert!(parse(&["submit", "--unknown"]).is_err());
        assert!(parse(&["submit", "--repo"]).is_err());
    }

    #[test]
    fn status_and_cancel() {
        let Cmd::Status(s) = parse(&["status", "abc", "-f"]).unwrap().command else {
            panic!("not status")
        };
        assert_eq!(s.task_id.as_deref(), Some("abc"));
        assert!(s.follow);
        let Cmd::Status(s) = parse(&["status"]).unwrap().command else {
            panic!("not status")
        };
        assert_eq!(s.task_id, None);
        let Cmd::Cancel(c) = parse(&["cancel", "abc"]).unwrap().command else {
            panic!("not cancel")
        };
        assert_eq!(c.task_id.as_deref(), Some("abc"));
    }

    #[test]
    fn auth_flags() {
        let Cmd::Login(a) = parse(&["login", "--email", "e@x", "--password", "-p"])
            .unwrap()
            .command
        else {
            panic!("not login")
        };
        assert_eq!(a.email.as_deref(), Some("e@x"));
        assert_eq!(a.password.as_deref(), Some("-p"));
        let Cmd::Register(a) = parse(&["register"]).unwrap().command else {
            panic!("not register")
        };
        assert_eq!((a.email, a.password), (None, None));
    }

    #[test]
    fn top_level_help_is_zig_usage() {
        let err = parse(&["--help"]).unwrap_err();
        assert_eq!(err.kind(), clap::error::ErrorKind::DisplayHelp);
        assert!(err.to_string().starts_with(USAGE.lines().next().unwrap()));
    }

    #[test]
    fn subcommand_help() {
        let err = parse(&["submit", "--help"]).unwrap_err();
        assert_eq!(err.kind(), clap::error::ErrorKind::DisplayHelp);
        let help = err.to_string();
        for flag in [
            "--repo",
            "--branch",
            "--prompt",
            "--pr",
            "--pr-title",
            "--pr-body",
            "--env",
            "--max-iterations",
            "--completion-promise",
            "--follow",
        ] {
            assert!(help.contains(flag), "{flag} missing from {help}");
        }
    }
}
