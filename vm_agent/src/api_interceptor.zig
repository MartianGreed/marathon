const std = @import("std");
const common = @import("common");
const types = common.types;

pub const ApiInterceptor = struct {
    allocator: std.mem.Allocator,
    metrics: types.UsageMetrics,
    mutex: std.Thread.Mutex,
    requests: std.ArrayListUnmanaged(RequestRecord),

    pub fn init(allocator: std.mem.Allocator) ApiInterceptor {
        return .{
            .allocator = allocator,
            .metrics = .{},
            .mutex = .{},
            .requests = .empty,
        };
    }

    pub fn deinit(self: *ApiInterceptor) void {
        self.requests.deinit(self.allocator);
    }

    pub fn recordRequest(self: *ApiInterceptor, response: ApiResponse) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.metrics.input_tokens += response.input_tokens;
        self.metrics.output_tokens += response.output_tokens;
        self.metrics.cache_read_tokens += response.cache_read_tokens;
        self.metrics.cache_write_tokens += response.cache_write_tokens;

        if (response.tool_use) {
            self.metrics.tool_calls += 1;
        }

        try self.requests.append(self.allocator, .{
            .timestamp = std.time.milliTimestamp(),
            .input_tokens = response.input_tokens,
            .output_tokens = response.output_tokens,
            .cache_read_tokens = response.cache_read_tokens,
            .cache_write_tokens = response.cache_write_tokens,
            .tool_use = response.tool_use,
            .model = response.model,
        });
    }

    pub fn getMetrics(self: *ApiInterceptor) types.UsageMetrics {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.metrics;
    }

    pub fn resetMetrics(self: *ApiInterceptor) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.metrics = .{};
        self.requests.clearRetainingCapacity();
    }

    pub fn getTotalRequests(self: *ApiInterceptor) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.requests.items.len;
    }

    pub fn parseResponse(self: *ApiInterceptor, response_body: []const u8) ApiResponse {
        _ = self;

        var result = ApiResponse{};

        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, response_body, .{}) catch return result;
        defer parsed.deinit();

        if (parsed.value.object.get("usage")) |usage| {
            if (usage.object.get("input_tokens")) |v| {
                result.input_tokens = v.integer;
            }
            if (usage.object.get("output_tokens")) |v| {
                result.output_tokens = v.integer;
            }
            if (usage.object.get("cache_creation_input_tokens")) |v| {
                result.cache_write_tokens = v.integer;
            }
            if (usage.object.get("cache_read_input_tokens")) |v| {
                result.cache_read_tokens = v.integer;
            }
        }

        if (parsed.value.object.get("content")) |content| {
            for (content.array.items) |item| {
                if (item.object.get("type")) |t| {
                    if (std.mem.eql(u8, t.string, "tool_use")) {
                        result.tool_use = true;
                        break;
                    }
                }
            }
        }

        if (parsed.value.object.get("model")) |model| {
            result.model = model.string;
        }

        return result;
    }

    pub fn parseStreamChunk(self: *ApiInterceptor, chunk: []const u8) ?StreamEvent {
        _ = self;

        if (!std.mem.startsWith(u8, chunk, "data: ")) {
            return null;
        }

        const json_data = chunk[6..];
        if (std.mem.eql(u8, json_data, "[DONE]")) {
            return .done;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json_data, .{}) catch return null;
        defer parsed.deinit();

        if (parsed.value.object.get("type")) |t| {
            const event_type = t.string;

            if (std.mem.eql(u8, event_type, "message_start")) {
                return .message_start;
            } else if (std.mem.eql(u8, event_type, "content_block_start")) {
                if (parsed.value.object.get("content_block")) |block| {
                    if (block.object.get("type")) |block_type| {
                        if (std.mem.eql(u8, block_type.string, "tool_use")) {
                            return .tool_use_start;
                        }
                    }
                }
                return .content_start;
            } else if (std.mem.eql(u8, event_type, "content_block_delta")) {
                return .content_delta;
            } else if (std.mem.eql(u8, event_type, "message_delta")) {
                var event = StreamEvent{ .message_delta = .{} };
                if (parsed.value.object.get("usage")) |usage| {
                    if (usage.object.get("output_tokens")) |v| {
                        event.message_delta.output_tokens = v.integer;
                    }
                }
                return event;
            } else if (std.mem.eql(u8, event_type, "message_stop")) {
                return .message_stop;
            }
        }

        return null;
    }
};

pub const ApiResponse = struct {
    input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    cache_read_tokens: i64 = 0,
    cache_write_tokens: i64 = 0,
    tool_use: bool = false,
    model: ?[]const u8 = null,
};

pub const RequestRecord = struct {
    timestamp: i64,
    input_tokens: i64,
    output_tokens: i64,
    cache_read_tokens: i64,
    cache_write_tokens: i64,
    tool_use: bool,
    model: ?[]const u8,
};

pub const StreamEvent = union(enum) {
    message_start: void,
    content_start: void,
    content_delta: void,
    tool_use_start: void,
    message_delta: struct {
        output_tokens: i64 = 0,
    },
    message_stop: void,
    done: void,
};

test "api interceptor metrics" {
    const allocator = std.testing.allocator;
    var interceptor = ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    try interceptor.recordRequest(.{
        .input_tokens = 100,
        .output_tokens = 50,
        .cache_read_tokens = 10,
        .cache_write_tokens = 5,
        .tool_use = true,
    });

    const metrics = interceptor.getMetrics();
    try std.testing.expectEqual(@as(i64, 100), metrics.input_tokens);
    try std.testing.expectEqual(@as(i64, 50), metrics.output_tokens);
    try std.testing.expectEqual(@as(i64, 1), metrics.tool_calls);
}

test "resetMetrics clears all data" {
    const allocator = std.testing.allocator;
    var interceptor = ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    try interceptor.recordRequest(.{
        .input_tokens = 100,
        .output_tokens = 50,
        .cache_read_tokens = 10,
        .cache_write_tokens = 5,
        .tool_use = true,
    });

    try std.testing.expectEqual(@as(usize, 1), interceptor.getTotalRequests());

    interceptor.resetMetrics();

    const metrics = interceptor.getMetrics();
    try std.testing.expectEqual(@as(i64, 0), metrics.input_tokens);
    try std.testing.expectEqual(@as(i64, 0), metrics.output_tokens);
    try std.testing.expectEqual(@as(i64, 0), metrics.cache_read_tokens);
    try std.testing.expectEqual(@as(i64, 0), metrics.cache_write_tokens);
    try std.testing.expectEqual(@as(i64, 0), metrics.tool_calls);
    try std.testing.expectEqual(@as(usize, 0), interceptor.getTotalRequests());
}

test "getTotalRequests returns count" {
    const allocator = std.testing.allocator;
    var interceptor = ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    try std.testing.expectEqual(@as(usize, 0), interceptor.getTotalRequests());

    try interceptor.recordRequest(.{ .input_tokens = 10, .output_tokens = 5 });
    try std.testing.expectEqual(@as(usize, 1), interceptor.getTotalRequests());

    try interceptor.recordRequest(.{ .input_tokens = 20, .output_tokens = 10 });
    try std.testing.expectEqual(@as(usize, 2), interceptor.getTotalRequests());

    try interceptor.recordRequest(.{ .input_tokens = 30, .output_tokens = 15 });
    try std.testing.expectEqual(@as(usize, 3), interceptor.getTotalRequests());
}

test "parseResponse extracts usage from valid JSON" {
    const allocator = std.testing.allocator;
    var interceptor = ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    const response =
        \\{"usage": {"input_tokens": 100, "output_tokens": 50, "cache_read_input_tokens": 10, "cache_creation_input_tokens": 5}, "model": "claude-3"}
    ;

    const result = interceptor.parseResponse(response);
    try std.testing.expectEqual(@as(i64, 100), result.input_tokens);
    try std.testing.expectEqual(@as(i64, 50), result.output_tokens);
    try std.testing.expectEqual(@as(i64, 10), result.cache_read_tokens);
    try std.testing.expectEqual(@as(i64, 5), result.cache_write_tokens);
}

test "parseResponse handles missing usage field" {
    const allocator = std.testing.allocator;
    var interceptor = ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    const response =
        \\{"model": "claude-3", "content": [{"type": "text", "text": "Hello"}]}
    ;

    const result = interceptor.parseResponse(response);
    try std.testing.expectEqual(@as(i64, 0), result.input_tokens);
    try std.testing.expectEqual(@as(i64, 0), result.output_tokens);
    try std.testing.expectEqual(@as(i64, 0), result.cache_read_tokens);
    try std.testing.expectEqual(@as(i64, 0), result.cache_write_tokens);
}

test "parseResponse handles invalid JSON" {
    const allocator = std.testing.allocator;
    var interceptor = ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    const result = interceptor.parseResponse("not valid json {{{");
    try std.testing.expectEqual(@as(i64, 0), result.input_tokens);
    try std.testing.expectEqual(@as(i64, 0), result.output_tokens);
    try std.testing.expectEqual(false, result.tool_use);
}

test "parseResponse detects tool_use in content" {
    const allocator = std.testing.allocator;
    var interceptor = ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    const response =
        \\{"usage": {"input_tokens": 100, "output_tokens": 50}, "content": [{"type": "tool_use", "name": "read_file"}]}
    ;

    const result = interceptor.parseResponse(response);
    try std.testing.expectEqual(true, result.tool_use);
}

test "parseResponse returns false for non-tool content" {
    const allocator = std.testing.allocator;
    var interceptor = ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    const response =
        \\{"usage": {"input_tokens": 100, "output_tokens": 50}, "content": [{"type": "text", "text": "Hello"}]}
    ;

    const result = interceptor.parseResponse(response);
    try std.testing.expectEqual(false, result.tool_use);
}

test "parseStreamChunk handles message_start" {
    const allocator = std.testing.allocator;
    var interceptor = ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    const chunk = "data: {\"type\": \"message_start\"}";
    const event = interceptor.parseStreamChunk(chunk);

    try std.testing.expect(event != null);
    try std.testing.expectEqual(StreamEvent.message_start, event.?);
}

test "parseStreamChunk handles content_delta" {
    const allocator = std.testing.allocator;
    var interceptor = ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    const chunk = "data: {\"type\": \"content_block_delta\"}";
    const event = interceptor.parseStreamChunk(chunk);

    try std.testing.expect(event != null);
    try std.testing.expectEqual(StreamEvent.content_delta, event.?);
}

test "parseStreamChunk handles message_delta with tokens" {
    const allocator = std.testing.allocator;
    var interceptor = ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    const chunk = "data: {\"type\": \"message_delta\", \"usage\": {\"output_tokens\": 25}}";
    const event = interceptor.parseStreamChunk(chunk);

    try std.testing.expect(event != null);
    switch (event.?) {
        .message_delta => |delta| {
            try std.testing.expectEqual(@as(i64, 25), delta.output_tokens);
        },
        else => try std.testing.expect(false),
    }
}

test "parseStreamChunk handles DONE marker" {
    const allocator = std.testing.allocator;
    var interceptor = ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    const chunk = "data: [DONE]";
    const event = interceptor.parseStreamChunk(chunk);

    try std.testing.expect(event != null);
    try std.testing.expectEqual(StreamEvent.done, event.?);
}

test "parseStreamChunk handles non-data prefix" {
    const allocator = std.testing.allocator;
    var interceptor = ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    const chunk = "event: ping";
    const event = interceptor.parseStreamChunk(chunk);

    try std.testing.expect(event == null);
}

test "parseStreamChunk handles message_stop" {
    const allocator = std.testing.allocator;
    var interceptor = ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    const chunk = "data: {\"type\": \"message_stop\"}";
    const event = interceptor.parseStreamChunk(chunk);

    try std.testing.expect(event != null);
    try std.testing.expectEqual(StreamEvent.message_stop, event.?);
}

test "parseStreamChunk handles content_block_start with tool_use" {
    const allocator = std.testing.allocator;
    var interceptor = ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    const chunk = "data: {\"type\": \"content_block_start\", \"content_block\": {\"type\": \"tool_use\"}}";
    const event = interceptor.parseStreamChunk(chunk);

    try std.testing.expect(event != null);
    try std.testing.expectEqual(StreamEvent.tool_use_start, event.?);
}

test "parseStreamChunk handles content_block_start without tool_use" {
    const allocator = std.testing.allocator;
    var interceptor = ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    const chunk = "data: {\"type\": \"content_block_start\", \"content_block\": {\"type\": \"text\"}}";
    const event = interceptor.parseStreamChunk(chunk);

    try std.testing.expect(event != null);
    try std.testing.expectEqual(StreamEvent.content_start, event.?);
}

test "parseStreamChunk handles invalid JSON" {
    const allocator = std.testing.allocator;
    var interceptor = ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    const chunk = "data: {invalid json";
    const event = interceptor.parseStreamChunk(chunk);

    try std.testing.expect(event == null);
}

test "metrics accumulate across multiple requests" {
    const allocator = std.testing.allocator;
    var interceptor = ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    try interceptor.recordRequest(.{
        .input_tokens = 100,
        .output_tokens = 50,
        .cache_read_tokens = 10,
        .cache_write_tokens = 5,
        .tool_use = true,
    });

    try interceptor.recordRequest(.{
        .input_tokens = 200,
        .output_tokens = 100,
        .cache_read_tokens = 20,
        .cache_write_tokens = 10,
        .tool_use = false,
    });

    try interceptor.recordRequest(.{
        .input_tokens = 50,
        .output_tokens = 25,
        .tool_use = true,
    });

    const metrics = interceptor.getMetrics();
    try std.testing.expectEqual(@as(i64, 350), metrics.input_tokens);
    try std.testing.expectEqual(@as(i64, 175), metrics.output_tokens);
    try std.testing.expectEqual(@as(i64, 30), metrics.cache_read_tokens);
    try std.testing.expectEqual(@as(i64, 15), metrics.cache_write_tokens);
    try std.testing.expectEqual(@as(i64, 2), metrics.tool_calls);
}
