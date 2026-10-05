//! Single-pass prompt substitution; replacement text is never re-expanded.

/// Single-pass task prompt template.
pub struct PromptWrapper {
    /// Template containing prompt, branch, and repo placeholders.
    pub template: String,
}

impl PromptWrapper {
    /// Create a wrapper from the configured template.
    pub fn new(template: impl Into<String>) -> Self {
        Self {
            template: template.into(),
        }
    }

    /// Substitute placeholders without expanding replacement text.
    pub fn wrap(&self, prompt: &str, repo: &str, branch: &str) -> String {
        let mut result = String::new();
        let mut rest = self.template.as_str();
        while !rest.is_empty() {
            let replacement = [("{prompt}", prompt), ("{branch}", branch), ("{repo}", repo)]
                .into_iter()
                .find(|(tag, _)| rest.starts_with(tag));
            if let Some((tag, value)) = replacement {
                result.push_str(value);
                rest = &rest[tag.len()..];
            } else if let Some(c) = rest.chars().next() {
                result.push(c);
                rest = &rest[c.len_utf8()..];
            }
        }
        result
    }
}

/// Strip GitHub URL prefixes and a trailing .git suffix.
pub fn extract_repo_name(url: &str) -> &str {
    let spec = url
        .strip_prefix("https://github.com/")
        .or_else(|| url.strip_prefix("git@github.com:"))
        .unwrap_or(url);
    spec.strip_suffix(".git").unwrap_or(spec)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrap_returns_prompt_unchanged_with_default_template() {
        assert_eq!(
            PromptWrapper::new("{prompt}").wrap("Fix the bug", "owner/repo", "main"),
            "Fix the bug"
        );
    }

    #[test]
    fn wrap_substitutes_all_placeholders() {
        assert_eq!(
            PromptWrapper::new("Working on {repo} branch {branch}. Task: {prompt}").wrap(
                "Fix the bug",
                "owner/repo",
                "main"
            ),
            "Working on owner/repo branch main. Task: Fix the bug"
        );
    }

    #[test]
    fn wrap_handles_multiple_prompt_placeholders() {
        assert_eq!(
            PromptWrapper::new("{prompt} - Remember: {prompt}").wrap("Do X", "owner/repo", "main"),
            "Do X - Remember: Do X"
        );
    }

    #[test]
    fn wrap_handles_template_without_placeholders() {
        assert_eq!(
            PromptWrapper::new("Static template with no placeholders").wrap(
                "Fix bug",
                "owner/repo",
                "main"
            ),
            "Static template with no placeholders"
        );
    }

    #[test]
    fn wrap_handles_empty_prompt() {
        assert_eq!(
            PromptWrapper::new("Task: {prompt}").wrap("", "owner/repo", "main"),
            "Task: "
        );
    }

    #[test]
    fn wrap_does_not_expand_replacements() {
        assert_eq!(
            PromptWrapper::new("{prompt} {repo}").wrap("{repo}", "é", "main"),
            "{repo} é"
        );
    }
}
