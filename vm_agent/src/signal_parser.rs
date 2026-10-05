//! Structured completion, clarification, and pull request signals.

/// Completion, clarification, and pull request signals in output.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct ClaudeSignals {
    /// Whether the configured completion text was found.
    pub has_completion_promise: bool,
    /// Whether a complete clarification tag was found.
    pub needs_clarification: bool,
    /// Content of the first complete clarification tag.
    pub clarification_question: Option<String>,
    /// Whether a GitHub pull request URL was found.
    pub pr_created: bool,
    /// First GitHub pull request URL in output.
    pub pr_url: Option<String>,
}

/// Return the content of the first complete tag pair.
pub fn extract_tag_content<'a>(output: &'a str, tag: &str) -> Option<&'a str> {
    if tag.len() + 3 > 64 {
        return None;
    }
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let rest = output.get(output.find(&open)? + open.len()..)?;
    rest.get(..rest.find(&close)?)
}

/// Find a GitHub pull request URL, stopping at whitespace or quotes.
pub fn extract_pr_url(output: &str) -> Option<String> {
    extract_url(output, true)
}

/// Find a GitHub pull request URL with optional quote delimiters.
pub(crate) fn extract_url(output: &str, quotes: bool) -> Option<String> {
    let mut rest = output;
    while let Some(start) = rest.find("https://github.com/") {
        rest = &rest[start..];
        let end = rest
            .find(|c| matches!(c, '\n' | ' ' | '\t') || (quotes && matches!(c, '\'' | '"')))
            .unwrap_or(rest.len());
        let url = &rest[..end];
        if url.contains("/pull/") {
            return Some(url.into());
        }
        rest = &rest[end..];
    }
    None
}

/// Parse task signals, including raw completion text for compatibility.
pub fn parse_signals(output: &str, promise: Option<&str>) -> ClaudeSignals {
    let pr_url = extract_pr_url(output);
    let question = extract_tag_content(output, "clarification").map(str::to_owned);
    ClaudeSignals {
        has_completion_promise: promise.is_some_and(|p| {
            extract_tag_content(output, "promise")
                .is_some_and(|c| c.trim_matches([' ', '\t', '\r', '\n']) == p)
                || output.contains(p)
        }),
        needs_clarification: question.is_some(),
        clarification_question: question,
        pr_created: pr_url.is_some(),
        pr_url,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_signals_detects_promise_tag() {
        assert!(
            parse_signals(
                "Working...\n<promise>TASK_COMPLETE</promise>\nDone.",
                Some("TASK_COMPLETE")
            )
            .has_completion_promise
        );
    }

    #[test]
    fn parse_signals_detects_raw_promise_text() {
        assert!(
            parse_signals("All done. TASK_COMPLETE", Some("TASK_COMPLETE")).has_completion_promise
        );
    }

    #[test]
    fn parse_signals_no_false_positive() {
        assert!(!parse_signals("Working on it...", Some("TASK_COMPLETE")).has_completion_promise);
    }

    #[test]
    fn parse_signals_detects_clarification() {
        let s = parse_signals(
            "<clarification>What database should I use?</clarification>",
            None,
        );
        assert!(s.needs_clarification);
        assert_eq!(
            s.clarification_question.as_deref(),
            Some("What database should I use?")
        );
    }

    #[test]
    fn parse_signals_detects_pr_url() {
        let s = parse_signals(
            "Created PR: https://github.com/owner/repo/pull/42\nDone.",
            None,
        );
        assert!(s.pr_created);
        assert_eq!(
            s.pr_url.as_deref(),
            Some("https://github.com/owner/repo/pull/42")
        );
    }

    #[test]
    fn parse_signals_no_pr_for_non_pull_urls() {
        assert!(!parse_signals("See https://github.com/owner/repo/issues/10", None).pr_created);
    }

    #[test]
    fn extract_tag_content_works() {
        assert_eq!(
            extract_tag_content("Before <promise>DONE</promise> after", "promise"),
            Some("DONE")
        );
    }

    #[test]
    fn extract_tag_content_returns_null_for_missing_tag() {
        assert_eq!(extract_tag_content("No tags here", "promise"), None);
    }

    #[test]
    fn signal_edge_cases() {
        assert!(parse_signals("<promise>  DONE\t</promise>", Some("DONE")).has_completion_promise);
        assert_eq!(extract_tag_content("<promise>unclosed", "promise"), None);
        assert_eq!(
            extract_pr_url("https://github.com/o/r/issues/1 https://github.com/o/r/pull/2\""),
            Some("https://github.com/o/r/pull/2".into())
        );
        assert_eq!(
            parse_signals("<clarification></clarification>", None).clarification_question,
            Some(String::new())
        );
    }
}
