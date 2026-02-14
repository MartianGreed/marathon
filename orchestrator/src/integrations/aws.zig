const std = @import("std");
const http = std.http;
const json = std.json;
const crypto = std.crypto;
const mod = @import("mod.zig");
const IntegrationStatus = mod.IntegrationStatus;

pub const AwsClient = struct {
    allocator: std.mem.Allocator,
    access_key_id: ?[]const u8,
    secret_access_key: ?[]const u8,
    region: []const u8,
    session_token: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) AwsClient {
        return .{
            .allocator = allocator,
            .access_key_id = null,
            .secret_access_key = null,
            .region = "us-east-1",
            .session_token = null,
        };
    }

    pub fn deinit(self: *AwsClient) void {
        if (self.access_key_id) |key| self.allocator.free(key);
        if (self.secret_access_key) |secret| self.allocator.free(secret);
        self.allocator.free(self.region);
        if (self.session_token) |token| self.allocator.free(token);
    }

    pub fn setCredentials(self: *AwsClient, access_key_id: []const u8, secret_access_key: []const u8, region: []const u8) !void {
        if (self.access_key_id) |key| self.allocator.free(key);
        if (self.secret_access_key) |secret| self.allocator.free(secret);
        self.allocator.free(self.region);

        self.access_key_id = try self.allocator.dupe(u8, access_key_id);
        self.secret_access_key = try self.allocator.dupe(u8, secret_access_key);
        self.region = try self.allocator.dupe(u8, region);
    }

    /// S3 Operations
    pub const S3Bucket = struct {
        name: []const u8,
        creation_date: []const u8,
        
        pub fn deinit(self: *S3Bucket, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.creation_date);
        }
    };

    pub const S3Object = struct {
        key: []const u8,
        size: u64,
        last_modified: []const u8,
        etag: []const u8,
        
        pub fn deinit(self: *S3Object, allocator: std.mem.Allocator) void {
            allocator.free(self.key);
            allocator.free(self.last_modified);
            allocator.free(self.etag);
        }
    };

    pub fn testS3Connection(self: *AwsClient) IntegrationStatus {
        if (self.access_key_id == null or self.secret_access_key == null) return .disconnected;
        
        // Test by listing buckets
        const response = self.makeS3Request(.GET, "", "", null) catch return .error;
        defer self.allocator.free(response.body);
        
        return if (response.status_code == 200) .connected else .error;
    }

    pub fn listS3Buckets(self: *AwsClient) ![]S3Bucket {
        const response = try self.makeS3Request(.GET, "", "", null);
        defer self.allocator.free(response.body);
        
        if (response.status_code != 200) return error.ListBucketsFailed;

        var parser = json.Parser.init(self.allocator, .alloc_always);
        defer parser.deinit();
        
        // AWS returns XML, but for simplicity we'll assume JSON conversion
        // In real implementation, would parse XML
        var buckets = std.ArrayList(S3Bucket).init(self.allocator);
        return buckets.toOwnedSlice();
    }

    pub fn createS3Bucket(self: *AwsClient, bucket_name: []const u8) !void {
        const response = try self.makeS3Request(.PUT, bucket_name, "", null);
        defer self.allocator.free(response.body);
        
        if (response.status_code != 200 and response.status_code != 201) {
            return error.CreateBucketFailed;
        }
    }

    pub fn uploadToS3(self: *AwsClient, bucket_name: []const u8, key: []const u8, data: []const u8, content_type: ?[]const u8) !void {
        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ bucket_name, key });
        defer self.allocator.free(endpoint);

        var headers = std.StringHashMap([]const u8).init(self.allocator);
        defer headers.deinit();
        
        if (content_type) |ct| {
            try headers.put("Content-Type", ct);
        }

        const response = try self.makeS3RequestWithHeaders(.PUT, endpoint, "", data, headers);
        defer self.allocator.free(response.body);
        
        if (response.status_code != 200 and response.status_code != 201) {
            return error.UploadFailed;
        }
    }

    pub fn listS3Objects(self: *AwsClient, bucket_name: []const u8, prefix: ?[]const u8) ![]S3Object {
        var endpoint = std.ArrayList(u8).init(self.allocator);
        defer endpoint.deinit();
        
        try endpoint.writer().print("{s}?list-type=2", .{bucket_name});
        if (prefix) |p| {
            try endpoint.writer().print("&prefix={s}", .{p});
        }

        const response = try self.makeS3Request(.GET, endpoint.items, "", null);
        defer self.allocator.free(response.body);
        
        if (response.status_code != 200) return error.ListObjectsFailed;

        // Parse XML response (simplified)
        var objects = std.ArrayList(S3Object).init(self.allocator);
        return objects.toOwnedSlice();
    }

    /// ECR Operations
    pub const EcrRepository = struct {
        repository_name: []const u8,
        repository_uri: []const u8,
        created_at: i64,
        
        pub fn deinit(self: *EcrRepository, allocator: std.mem.Allocator) void {
            allocator.free(self.repository_name);
            allocator.free(self.repository_uri);
        }
    };

    pub const EcrImage = struct {
        image_digest: []const u8,
        image_tags: []const []const u8,
        image_size_bytes: u64,
        pushed_at: i64,
        
        pub fn deinit(self: *EcrImage, allocator: std.mem.Allocator) void {
            allocator.free(self.image_digest);
            for (self.image_tags) |tag| allocator.free(tag);
            allocator.free(self.image_tags);
        }
    };

    pub fn testEcrConnection(self: *AwsClient) IntegrationStatus {
        if (self.access_key_id == null or self.secret_access_key == null) return .disconnected;
        
        // Test by describing repositories
        const response = self.makeEcrRequest("DescribeRepositories", "{}") catch return .error;
        defer self.allocator.free(response.body);
        
        return if (response.status_code == 200) .connected else .error;
    }

    pub fn listEcrRepositories(self: *AwsClient) ![]EcrRepository {
        const response = try self.makeEcrRequest("DescribeRepositories", "{}");
        defer self.allocator.free(response.body);
        
        if (response.status_code != 200) return error.ListRepositoriesFailed;

        var parser = json.Parser.init(self.allocator, .alloc_always);
        defer parser.deinit();
        
        var tree = try parser.parse(response.body);
        defer tree.deinit();

        var repositories = std.ArrayList(EcrRepository).init(self.allocator);
        if (tree.root.object.get("repositories")) |repos_array| {
            for (repos_array.array.items) |repo_item| {
                const repo_obj = repo_item.object;
                const repository = EcrRepository{
                    .repository_name = try self.allocator.dupe(u8, repo_obj.get("repositoryName").?.string),
                    .repository_uri = try self.allocator.dupe(u8, repo_obj.get("repositoryUri").?.string),
                    .created_at = @intCast(repo_obj.get("createdAt").?.integer),
                };
                try repositories.append(repository);
            }
        }

        return repositories.toOwnedSlice();
    }

    pub fn createEcrRepository(self: *AwsClient, repository_name: []const u8) !EcrRepository {
        const payload = try std.fmt.allocPrint(self.allocator,
            "{{\"repositoryName\":\"{s}\"}}",
            .{repository_name}
        );
        defer self.allocator.free(payload);

        const response = try self.makeEcrRequest("CreateRepository", payload);
        defer self.allocator.free(response.body);
        
        if (response.status_code != 200) return error.CreateRepositoryFailed;

        var parser = json.Parser.init(self.allocator, .alloc_always);
        defer parser.deinit();
        
        var tree = try parser.parse(response.body);
        defer tree.deinit();

        const repo_obj = tree.root.object.get("repository").?.object;
        return EcrRepository{
            .repository_name = try self.allocator.dupe(u8, repo_obj.get("repositoryName").?.string),
            .repository_uri = try self.allocator.dupe(u8, repo_obj.get("repositoryUri").?.string),
            .created_at = @intCast(repo_obj.get("createdAt").?.integer),
        };
    }

    pub fn getEcrLoginToken(self: *AwsClient) ![]const u8 {
        const response = try self.makeEcrRequest("GetAuthorizationToken", "{}");
        defer self.allocator.free(response.body);
        
        if (response.status_code != 200) return error.GetTokenFailed;

        var parser = json.Parser.init(self.allocator, .alloc_always);
        defer parser.deinit();
        
        var tree = try parser.parse(response.body);
        defer tree.deinit();

        const auth_data = tree.root.object.get("authorizationData").?.array.items[0].object;
        return try self.allocator.dupe(u8, auth_data.get("authorizationToken").?.string);
    }

    /// Lambda Operations
    pub const LambdaFunction = struct {
        function_name: []const u8,
        function_arn: []const u8,
        runtime: []const u8,
        handler: []const u8,
        last_modified: []const u8,
        
        pub fn deinit(self: *LambdaFunction, allocator: std.mem.Allocator) void {
            allocator.free(self.function_name);
            allocator.free(self.function_arn);
            allocator.free(self.runtime);
            allocator.free(self.handler);
            allocator.free(self.last_modified);
        }
    };

    pub fn testLambdaConnection(self: *AwsClient) IntegrationStatus {
        if (self.access_key_id == null or self.secret_access_key == null) return .disconnected;
        
        // Test by listing functions
        const response = self.makeLambdaRequest(.GET, "/2015-03-31/functions", null) catch return .error;
        defer self.allocator.free(response.body);
        
        return if (response.status_code == 200) .connected else .error;
    }

    pub fn listLambdaFunctions(self: *AwsClient) ![]LambdaFunction {
        const response = try self.makeLambdaRequest(.GET, "/2015-03-31/functions", null);
        defer self.allocator.free(response.body);
        
        if (response.status_code != 200) return error.ListFunctionsFailed;

        var parser = json.Parser.init(self.allocator, .alloc_always);
        defer parser.deinit();
        
        var tree = try parser.parse(response.body);
        defer tree.deinit();

        var functions = std.ArrayList(LambdaFunction).init(self.allocator);
        if (tree.root.object.get("Functions")) |functions_array| {
            for (functions_array.array.items) |function_item| {
                const func_obj = function_item.object;
                const function = LambdaFunction{
                    .function_name = try self.allocator.dupe(u8, func_obj.get("FunctionName").?.string),
                    .function_arn = try self.allocator.dupe(u8, func_obj.get("FunctionArn").?.string),
                    .runtime = try self.allocator.dupe(u8, func_obj.get("Runtime").?.string),
                    .handler = try self.allocator.dupe(u8, func_obj.get("Handler").?.string),
                    .last_modified = try self.allocator.dupe(u8, func_obj.get("LastModified").?.string),
                };
                try functions.append(function);
            }
        }

        return functions.toOwnedSlice();
    }

    pub const LambdaCreateRequest = struct {
        function_name: []const u8,
        runtime: []const u8,
        role: []const u8,
        handler: []const u8,
        zip_file: []const u8,
        environment: ?std.StringHashMap([]const u8) = null,
        timeout: ?u32 = null,
        memory_size: ?u32 = null,
    };

    pub fn createLambdaFunction(self: *AwsClient, request: LambdaCreateRequest) !LambdaFunction {
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();

        try payload.writer().print("{{\"FunctionName\":\"{s}\",\"Runtime\":\"{s}\",\"Role\":\"{s}\",\"Handler\":\"{s}\"", 
            .{ request.function_name, request.runtime, request.role, request.handler });

        // Add base64 encoded zip file
        const encoded_zip = try self.base64Encode(request.zip_file);
        defer self.allocator.free(encoded_zip);
        try payload.writer().print(",\"Code\":{{\"ZipFile\":\"{s}\"}}", .{encoded_zip});

        if (request.timeout) |timeout| {
            try payload.writer().print(",\"Timeout\":{d}", .{timeout});
        }
        if (request.memory_size) |memory| {
            try payload.writer().print(",\"MemorySize\":{d}", .{memory});
        }

        if (request.environment) |env| {
            try payload.writer().print(",\"Environment\":{{\"Variables\":{{");
            var iter = env.iterator();
            var first = true;
            while (iter.next()) |entry| {
                if (!first) try payload.append(',');
                first = false;
                try payload.writer().print("\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
            try payload.writer().print("}}}}");
        }

        try payload.append('}');

        const response = try self.makeLambdaRequest(.POST, "/2015-03-31/functions", payload.items);
        defer self.allocator.free(response.body);
        
        if (response.status_code != 201) return error.CreateFunctionFailed;

        var parser = json.Parser.init(self.allocator, .alloc_always);
        defer parser.deinit();
        
        var tree = try parser.parse(response.body);
        defer tree.deinit();

        const func_obj = tree.root.object;
        return LambdaFunction{
            .function_name = try self.allocator.dupe(u8, func_obj.get("FunctionName").?.string),
            .function_arn = try self.allocator.dupe(u8, func_obj.get("FunctionArn").?.string),
            .runtime = try self.allocator.dupe(u8, func_obj.get("Runtime").?.string),
            .handler = try self.allocator.dupe(u8, func_obj.get("Handler").?.string),
            .last_modified = try self.allocator.dupe(u8, func_obj.get("LastModified").?.string),
        };
    }

    pub fn invokeLambdaFunction(self: *AwsClient, function_name: []const u8, payload: []const u8) ![]const u8 {
        const endpoint = try std.fmt.allocPrint(self.allocator, "/2015-03-31/functions/{s}/invocations", .{function_name});
        defer self.allocator.free(endpoint);

        const response = try self.makeLambdaRequest(.POST, endpoint, payload);
        defer self.allocator.free(response.body);
        
        if (response.status_code != 200) return error.InvokeFailed;
        
        return try self.allocator.dupe(u8, response.body);
    }

    /// EC2 Operations  
    pub const Ec2Instance = struct {
        instance_id: []const u8,
        instance_type: []const u8,
        state: []const u8,
        public_ip: ?[]const u8,
        private_ip: []const u8,
        launch_time: []const u8,
        
        pub fn deinit(self: *Ec2Instance, allocator: std.mem.Allocator) void {
            allocator.free(self.instance_id);
            allocator.free(self.instance_type);
            allocator.free(self.state);
            if (self.public_ip) |ip| allocator.free(ip);
            allocator.free(self.private_ip);
            allocator.free(self.launch_time);
        }
    };

    pub fn testEc2Connection(self: *AwsClient) IntegrationStatus {
        if (self.access_key_id == null or self.secret_access_key == null) return .disconnected;
        
        // Test by describing instances
        const response = self.makeEc2Request("DescribeInstances", "") catch return .error;
        defer self.allocator.free(response.body);
        
        return if (response.status_code == 200) .connected else .error;
    }

    pub fn listEc2Instances(self: *AwsClient) ![]Ec2Instance {
        const response = try self.makeEc2Request("DescribeInstances", "");
        defer self.allocator.free(response.body);
        
        if (response.status_code != 200) return error.ListInstancesFailed;

        // Parse EC2 XML response (simplified)
        var instances = std.ArrayList(Ec2Instance).init(self.allocator);
        return instances.toOwnedSlice();
    }

    /// CloudWatch Operations
    pub const CloudWatchMetric = struct {
        metric_name: []const u8,
        namespace: []const u8,
        dimensions: []const Dimension,
        
        pub const Dimension = struct {
            name: []const u8,
            value: []const u8,
        };
        
        pub fn deinit(self: *CloudWatchMetric, allocator: std.mem.Allocator) void {
            allocator.free(self.metric_name);
            allocator.free(self.namespace);
            for (self.dimensions) |dim| {
                allocator.free(dim.name);
                allocator.free(dim.value);
            }
            allocator.free(self.dimensions);
        }
    };

    pub fn testCloudwatchConnection(self: *AwsClient) IntegrationStatus {
        if (self.access_key_id == null or self.secret_access_key == null) return .disconnected;
        
        // Test by listing metrics
        const response = self.makeCloudWatchRequest("ListMetrics", "") catch return .error;
        defer self.allocator.free(response.body);
        
        return if (response.status_code == 200) .connected else .error;
    }

    pub fn publishCloudWatchMetric(self: *AwsClient, namespace: []const u8, metric_name: []const u8, value: f64, unit: []const u8, dimensions: []const CloudWatchMetric.Dimension) !void {
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();

        try payload.writer().print("Action=PutMetricData&Namespace={s}&MetricData.member.1.MetricName={s}&MetricData.member.1.Value={d}&MetricData.member.1.Unit={s}", 
            .{ namespace, metric_name, value, unit });

        for (dimensions, 0..) |dim, i| {
            try payload.writer().print("&MetricData.member.1.Dimensions.member.{d}.Name={s}&MetricData.member.1.Dimensions.member.{d}.Value={s}", 
                .{ i + 1, dim.name, i + 1, dim.value });
        }

        const response = try self.makeCloudWatchRequest("PutMetricData", payload.items);
        defer self.allocator.free(response.body);
        
        if (response.status_code != 200) return error.PublishMetricFailed;
    }

    /// Helper functions for AWS API requests
    const AwsResponse = struct {
        status_code: u16,
        body: []const u8,
    };

    fn makeS3Request(self: *AwsClient, method: http.Method, endpoint: []const u8, query: []const u8, body: ?[]const u8) !AwsResponse {
        const empty_headers = std.StringHashMap([]const u8).init(self.allocator);
        return self.makeS3RequestWithHeaders(method, endpoint, query, body, empty_headers);
    }

    fn makeS3RequestWithHeaders(self: *AwsClient, method: http.Method, endpoint: []const u8, query: []const u8, body: ?[]const u8, extra_headers: std.StringHashMap([]const u8)) !AwsResponse {
        const host = try std.fmt.allocPrint(self.allocator, "s3.{s}.amazonaws.com", .{self.region});
        defer self.allocator.free(host);

        const url = if (query.len > 0)
            try std.fmt.allocPrint(self.allocator, "https://{s}/{s}?{s}", .{ host, endpoint, query })
        else
            try std.fmt.allocPrint(self.allocator, "https://{s}/{s}", .{ host, endpoint });
        defer self.allocator.free(url);

        return self.makeAwsRequest(method, url, "s3", body, extra_headers);
    }

    fn makeEcrRequest(self: *AwsClient, action: []const u8, payload: []const u8) !AwsResponse {
        const host = try std.fmt.allocPrint(self.allocator, "ecr.{s}.amazonaws.com", .{self.region});
        defer self.allocator.free(host);

        const url = try std.fmt.allocPrint(self.allocator, "https://{s}/", .{host});
        defer self.allocator.free(url);

        var headers = std.StringHashMap([]const u8).init(self.allocator);
        defer headers.deinit();
        
        try headers.put("X-Amz-Target", try std.fmt.allocPrint(self.allocator, "AmazonEC2ContainerRegistry_V20150921.{s}", .{action}));
        try headers.put("Content-Type", "application/x-amz-json-1.1");

        return self.makeAwsRequest(.POST, url, "ecr", payload, headers);
    }

    fn makeLambdaRequest(self: *AwsClient, method: http.Method, endpoint: []const u8, body: ?[]const u8) !AwsResponse {
        const host = try std.fmt.allocPrint(self.allocator, "lambda.{s}.amazonaws.com", .{self.region});
        defer self.allocator.free(host);

        const url = try std.fmt.allocPrint(self.allocator, "https://{s}{s}", .{ host, endpoint });
        defer self.allocator.free(url);

        const empty_headers = std.StringHashMap([]const u8).init(self.allocator);
        return self.makeAwsRequest(method, url, "lambda", body, empty_headers);
    }

    fn makeEc2Request(self: *AwsClient, action: []const u8, parameters: []const u8) !AwsResponse {
        const host = try std.fmt.allocPrint(self.allocator, "ec2.{s}.amazonaws.com", .{self.region});
        defer self.allocator.free(host);

        const url = try std.fmt.allocPrint(self.allocator, "https://{s}/", .{host});
        defer self.allocator.free(url);

        const body = try std.fmt.allocPrint(self.allocator, "Action={s}&Version=2016-11-15{s}", .{ action, parameters });
        defer self.allocator.free(body);

        const empty_headers = std.StringHashMap([]const u8).init(self.allocator);
        return self.makeAwsRequest(.POST, url, "ec2", body, empty_headers);
    }

    fn makeCloudWatchRequest(self: *AwsClient, action: []const u8, parameters: []const u8) !AwsResponse {
        const host = try std.fmt.allocPrint(self.allocator, "monitoring.{s}.amazonaws.com", .{self.region});
        defer self.allocator.free(host);

        const url = try std.fmt.allocPrint(self.allocator, "https://{s}/", .{host});
        defer self.allocator.free(url);

        const body = try std.fmt.allocPrint(self.allocator, "Action={s}&Version=2010-08-01{s}", .{ action, parameters });
        defer self.allocator.free(body);

        const empty_headers = std.StringHashMap([]const u8).init(self.allocator);
        return self.makeAwsRequest(.POST, url, "monitoring", body, empty_headers);
    }

    fn makeAwsRequest(self: *AwsClient, method: http.Method, url: []const u8, service: []const u8, body: ?[]const u8, extra_headers: std.StringHashMap([]const u8)) !AwsResponse {
        // Simplified AWS signature version 4 implementation
        // In production, would implement full AWS Signature Version 4 algorithm
        _ = service;
        
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        var headers = http.Headers.init(self.allocator);
        defer headers.deinit();

        // Add extra headers
        var iter = extra_headers.iterator();
        while (iter.next()) |entry| {
            try headers.append(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Add AWS authentication headers (simplified)
        if (self.access_key_id) |access_key| {
            const auth_header = try std.fmt.allocPrint(self.allocator, "AWS4-HMAC-SHA256 Credential={s}/...", .{access_key});
            defer self.allocator.free(auth_header);
            try headers.append("Authorization", auth_header);
        }

        var request = try client.open(method, try std.Uri.parse(url), headers);
        defer request.deinit();

        if (body) |request_body| {
            request.transfer_encoding = .{ .content_length = request_body.len };
        } else {
            request.transfer_encoding = .{ .content_length = 0 };
        }

        try request.send();

        if (body) |request_body| {
            try request.writeAll(request_body);
        }

        try request.finish();
        try request.wait();

        const response_body = try request.reader().readAllAlloc(self.allocator, 1024 * 1024);
        return AwsResponse{
            .status_code = request.response.status.phrase(),
            .body = response_body,
        };
    }

    fn base64Encode(self: *AwsClient, data: []const u8) ![]u8 {
        const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
        const encoded = try self.allocator.alloc(u8, encoded_len);
        return std.base64.standard.Encoder.encode(encoded, data);
    }
};

test "aws client initialization" {
    const testing = std.testing;
    
    var client = AwsClient.init(testing.allocator);
    defer client.deinit();

    try testing.expect(client.access_key_id == null);
    try testing.expect(client.secret_access_key == null);
    try testing.expectEqualStrings("us-east-1", client.region);
}