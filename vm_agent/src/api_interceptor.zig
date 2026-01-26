const std = @import("std");
const common = @import("common");
const types = common.types;

pub const ApiInterceptor = struct {
    allocator: std.mem.Allocator,
    metrics: types.UsageMetrics,
    mutex: std.Thread.Mutex,
    requests: std.ArrayList(RequestRecord),

    pub fn init(allocator: std.mem.Allocator) ApiInterceptor {
        return .{
            .allocator = allocator,
            .metrics = .{},
            .mutex = .{},
            .requests = std.ArrayList(RequestRecord).init(allocator),
        };
    }

    pub fn deinit(self: *ApiInterceptor) void {
        self.requests.deinit();
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

        try self.requests.append(.{
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

    pub fn parseResponse(self: *ApiInterceptor, response_body: []const u8) !ApiResponse {
        _ = self;

        var result = ApiResponse{};

        var parser = std.json.Parser.init(std.heap.page_allocator, .{});
        defer parser.deinit();

        const parsed = parser.parse(response_body) catch return result;
        defer parsed.deinit();

        if (parsed.root.object.get("usage")) |usage| {
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

        if (parsed.root.object.get("content")) |content| {
            for (content.array.items) |item| {
                if (item.object.get("type")) |t| {
                    if (std.mem.eql(u8, t.string, "tool_use")) {
                        result.tool_use = true;
                        break;
                    }
                }
            }
        }

        if (parsed.root.object.get("model")) |model| {
            result.model = model.string;
        }

        return result;
    }

    pub fn parseStreamChunk(self: *ApiInterceptor, chunk: []const u8) !?StreamEvent {
        _ = self;

        if (!std.mem.startsWith(u8, chunk, "data: ")) {
            return null;
        }

        const json_data = chunk[6..];
        if (std.mem.eql(u8, json_data, "[DONE]")) {
            return .done;
        }

        var parser = std.json.Parser.init(std.heap.page_allocator, .{});
        defer parser.deinit();

        const parsed = parser.parse(json_data) catch return null;
        defer parsed.deinit();

        if (parsed.root.object.get("type")) |t| {
            const event_type = t.string;

            if (std.mem.eql(u8, event_type, "message_start")) {
                return .message_start;
            } else if (std.mem.eql(u8, event_type, "content_block_start")) {
                if (parsed.root.object.get("content_block")) |block| {
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
                if (parsed.root.object.get("usage")) |usage| {
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
