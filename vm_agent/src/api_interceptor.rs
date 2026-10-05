//! Thread-safe API metering library. Claude JSON usage meters the live run path.

use crate::claude_wrapper::{metrics_from_usage, parse_json_metrics};
use common::types::{UsageMetrics, now_ms};
use std::sync::Mutex;

/// Owned usage and tool information from one API response.
#[derive(Debug, Default, Clone)]
pub struct ApiResponse {
    /// Input tokens reported by the API.
    pub input_tokens: i64,
    /// Output tokens reported by the API.
    pub output_tokens: i64,
    /// Tokens read from the prompt cache.
    pub cache_read_tokens: i64,
    /// Tokens written to the prompt cache.
    pub cache_write_tokens: i64,
    /// Whether the response contains a tool-use block.
    pub tool_use: bool,
    /// Model name reported by the API, if present.
    pub model: Option<String>,
}

/// Timestamped response retained for request accounting.
#[derive(Debug, Clone)]
pub struct RequestRecord {
    /// Unix timestamp in milliseconds.
    pub timestamp: i64,
    /// Owned response information for this request.
    pub response: ApiResponse,
}

#[derive(Default)]
struct State {
    metrics: UsageMetrics,
    requests: Vec<RequestRecord>,
}

/// Thread-safe cumulative API usage and request records.
#[derive(Default)]
pub struct ApiInterceptor {
    state: Mutex<State>,
}

/// Recognized events from an API server-sent event chunk.
#[derive(Debug, PartialEq, Eq)]
pub enum StreamEvent {
    /// The API started a message.
    MessageStart,
    /// The API started a non-tool content block.
    ContentStart,
    /// The API emitted a content delta.
    ContentDelta,
    /// The API started a tool-use block.
    ToolUseStart,
    /// The API reported incremental output usage.
    MessageDelta {
        /// Output tokens reported by this delta.
        output_tokens: i64,
    },
    /// The API finished a message.
    MessageStop,
    /// The stream emitted the DONE marker.
    Done,
}

impl ApiInterceptor {
    /// Create an interceptor with no recorded requests.
    pub fn new() -> Self {
        Self::default()
    }

    /// Add response usage and retain a timestamped request record.
    pub fn record_request(&self, response: ApiResponse) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.metrics.add(&UsageMetrics {
            input_tokens: response.input_tokens,
            output_tokens: response.output_tokens,
            cache_read_tokens: response.cache_read_tokens,
            cache_write_tokens: response.cache_write_tokens,
            tool_calls: i64::from(response.tool_use),
            ..Default::default()
        });
        state.requests.push(RequestRecord {
            timestamp: now_ms(),
            response,
        });
    }

    /// Return a snapshot of cumulative usage.
    pub fn get_metrics(&self) -> UsageMetrics {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).metrics
    }

    /// Clear accumulated usage and request records.
    pub fn reset_metrics(&self) {
        *self.state.lock().unwrap_or_else(|e| e.into_inner()) = State::default();
    }

    /// Return the number of requests recorded since the last reset.
    pub fn total_requests(&self) -> usize {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .requests
            .len()
    }

    /// Parse response usage and tool blocks; malformed fields use defaults.
    pub fn parse_response(&self, body: &[u8]) -> ApiResponse {
        let value: serde_json::Value = serde_json::from_slice(body).unwrap_or_default();
        let metrics = parse_json_metrics(body);
        ApiResponse {
            input_tokens: metrics.input_tokens,
            output_tokens: metrics.output_tokens,
            cache_read_tokens: metrics.cache_read_tokens,
            cache_write_tokens: metrics.cache_write_tokens,
            tool_use: value["content"].as_array().is_some_and(|items| {
                items
                    .iter()
                    .any(|item| item["type"].as_str() == Some("tool_use"))
            }),
            model: value["model"].as_str().map(str::to_owned),
        }
    }

    /// Parse one data-prefixed SSE chunk or the DONE marker.
    pub fn parse_stream_chunk(&self, chunk: &str) -> Option<StreamEvent> {
        let data = chunk.strip_prefix("data: ")?;
        if data == "[DONE]" {
            return Some(StreamEvent::Done);
        }
        let value: serde_json::Value = serde_json::from_str(data).ok()?;
        Some(match value["type"].as_str()? {
            "message_start" => StreamEvent::MessageStart,
            "content_block_start"
                if value["content_block"]["type"].as_str() == Some("tool_use") =>
            {
                StreamEvent::ToolUseStart
            }
            "content_block_start" => StreamEvent::ContentStart,
            "content_block_delta" => StreamEvent::ContentDelta,
            "message_delta" => StreamEvent::MessageDelta {
                output_tokens: metrics_from_usage(&value["usage"]).output_tokens,
            },
            "message_stop" => StreamEvent::MessageStop,
            _ => return None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn response(input: i64, output: i64, read: i64, write: i64, tool: bool) -> ApiResponse {
        ApiResponse {
            input_tokens: input,
            output_tokens: output,
            cache_read_tokens: read,
            cache_write_tokens: write,
            tool_use: tool,
            ..Default::default()
        }
    }

    fn expected(input: i64, output: i64, read: i64, write: i64, tools: i64) -> UsageMetrics {
        UsageMetrics {
            input_tokens: input,
            output_tokens: output,
            cache_read_tokens: read,
            cache_write_tokens: write,
            tool_calls: tools,
            ..Default::default()
        }
    }

    #[test]
    fn api_interceptor_metrics() {
        let i = ApiInterceptor::new();
        i.record_request(response(100, 50, 10, 5, true));
        assert_eq!(i.get_metrics(), expected(100, 50, 10, 5, 1));
    }

    #[test]
    fn reset_metrics_clears_all_data() {
        let i = ApiInterceptor::new();
        i.record_request(response(100, 50, 10, 5, true));
        assert_eq!(i.total_requests(), 1);
        i.reset_metrics();
        assert_eq!(i.get_metrics(), UsageMetrics::default());
        assert_eq!(i.total_requests(), 0);
    }

    #[test]
    fn get_total_requests_returns_count() {
        let i = ApiInterceptor::new();
        assert_eq!(i.total_requests(), 0);
        for n in 1..=3 {
            i.record_request(response(n * 10, n * 5, 0, 0, false));
            assert_eq!(i.total_requests(), n as usize);
        }
    }

    #[test]
    fn parse_response_extracts_usage_from_valid_json() {
        let i = ApiInterceptor::new();
        let r = i.parse_response(br#"{"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":10,"cache_creation_input_tokens":5},"model":"claude-3"}"#);
        assert_eq!(
            (
                r.input_tokens,
                r.output_tokens,
                r.cache_read_tokens,
                r.cache_write_tokens
            ),
            (100, 50, 10, 5)
        );
        assert_eq!(r.model.as_deref(), Some("claude-3"));
    }

    #[test]
    fn parse_response_handles_missing_usage_field() {
        let r = ApiInterceptor::new()
            .parse_response(br#"{"model":"claude-3","content":[{"type":"text","text":"Hello"}]}"#);
        assert_eq!(
            (
                r.input_tokens,
                r.output_tokens,
                r.cache_read_tokens,
                r.cache_write_tokens
            ),
            (0, 0, 0, 0)
        );
    }

    #[test]
    fn parse_response_handles_invalid_json() {
        let r = ApiInterceptor::new().parse_response(b"not valid json {{{");
        assert_eq!((r.input_tokens, r.output_tokens, r.tool_use), (0, 0, false));
    }

    #[test]
    fn parse_response_detects_tool_use_in_content() {
        assert!(ApiInterceptor::new().parse_response(br#"{"usage":{"input_tokens":100,"output_tokens":50},"content":[{"type":"tool_use","name":"read_file"}]}"#).tool_use);
    }

    #[test]
    fn parse_response_returns_false_for_non_tool_content() {
        assert!(
            !ApiInterceptor::new()
                .parse_response(br#"{"content":[{"type":"text"}]}"#)
                .tool_use
        );
    }

    #[test]
    fn parse_stream_chunk_handles_message_start() {
        assert_eq!(
            ApiInterceptor::new().parse_stream_chunk(r#"data: {"type":"message_start"}"#),
            Some(StreamEvent::MessageStart)
        );
    }

    #[test]
    fn parse_stream_chunk_handles_content_delta() {
        assert_eq!(
            ApiInterceptor::new().parse_stream_chunk(r#"data: {"type":"content_block_delta"}"#),
            Some(StreamEvent::ContentDelta)
        );
    }

    #[test]
    fn parse_stream_chunk_handles_message_delta_with_tokens() {
        assert_eq!(
            ApiInterceptor::new().parse_stream_chunk(
                r#"data: {"type":"message_delta","usage":{"output_tokens":25}}"#
            ),
            Some(StreamEvent::MessageDelta { output_tokens: 25 })
        );
    }

    #[test]
    fn parse_stream_chunk_handles_done_marker() {
        assert_eq!(
            ApiInterceptor::new().parse_stream_chunk("data: [DONE]"),
            Some(StreamEvent::Done)
        );
    }

    #[test]
    fn parse_stream_chunk_handles_non_data_prefix() {
        assert_eq!(
            ApiInterceptor::new().parse_stream_chunk("event: ping"),
            None
        );
    }

    #[test]
    fn parse_stream_chunk_handles_message_stop() {
        assert_eq!(
            ApiInterceptor::new().parse_stream_chunk(r#"data: {"type":"message_stop"}"#),
            Some(StreamEvent::MessageStop)
        );
    }

    #[test]
    fn parse_stream_chunk_handles_content_block_start_with_tool_use() {
        assert_eq!(
            ApiInterceptor::new().parse_stream_chunk(
                r#"data: {"type":"content_block_start","content_block":{"type":"tool_use"}}"#
            ),
            Some(StreamEvent::ToolUseStart)
        );
    }

    #[test]
    fn parse_stream_chunk_handles_content_block_start_without_tool_use() {
        assert_eq!(
            ApiInterceptor::new().parse_stream_chunk(
                r#"data: {"type":"content_block_start","content_block":{"type":"text"}}"#
            ),
            Some(StreamEvent::ContentStart)
        );
    }

    #[test]
    fn parse_stream_chunk_handles_invalid_json() {
        assert_eq!(
            ApiInterceptor::new().parse_stream_chunk("data: {invalid json"),
            None
        );
    }

    #[test]
    fn metrics_accumulate_across_multiple_requests() {
        let i = ApiInterceptor::new();
        i.record_request(response(100, 50, 10, 5, true));
        i.record_request(response(200, 100, 20, 10, false));
        i.record_request(response(50, 25, 0, 0, true));
        assert_eq!(i.get_metrics(), expected(350, 175, 30, 15, 2));
    }

    #[test]
    fn concurrent_requests_and_malformed_values() {
        let i = std::sync::Arc::new(ApiInterceptor::new());
        let handles: Vec<_> = (0..4)
            .map(|_| {
                let i = i.clone();
                std::thread::spawn(move || {
                    for _ in 0..100 {
                        i.record_request(response(1, 2, 3, 4, true));
                    }
                })
            })
            .collect();
        for h in handles {
            h.join().unwrap();
        }
        assert_eq!(i.total_requests(), 400);
        assert_eq!(i.get_metrics(), expected(400, 800, 1200, 1600, 400));
        let r = i.parse_response(br#"{"usage":false,"model":[],"content":[null,3]}"#);
        assert!(!r.tool_use);
        assert_eq!(r.input_tokens, 0);
    }
}
