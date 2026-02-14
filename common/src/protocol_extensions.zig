const std = @import("std");
const types = @import("types.zig");
const protocol = @import("protocol.zig");

// Integration protocol messages
pub const IntegrationType = enum(u8) {
    github = 1,
    docker_hub = 2,
    github_container_registry = 3,
    aws_ecr = 4,
    aws_s3 = 5,
    aws_lambda = 6,
    aws_ec2 = 7,
    aws_cloudwatch = 8,
};

pub const IntegrationStatus = enum(u8) {
    disconnected = 0,
    connecting = 1,
    connected = 2,
    error = 3,
    rate_limited = 4,
};

pub const IntegrationListRequest = struct {};

pub const IntegrationInfo = struct {
    id: []const u8,
    integration_type: IntegrationType,
    name: []const u8,
    status: IntegrationStatus,
    enabled: bool,
    last_error: ?[]const u8,
    created_at: i64,
    updated_at: i64,
};

pub const IntegrationListResponse = struct {
    integrations: []const IntegrationInfo,
};

pub const IntegrationConnectRequest = struct {
    integration_type: IntegrationType,
    name: []const u8,
    credentials: []const types.EnvVar, // Key-value pairs for credentials
    settings: []const types.EnvVar, // Additional settings
};

pub const IntegrationConnectResponse = struct {
    success: bool,
    integration_id: ?[]const u8,
    message: []const u8,
};

pub const IntegrationStatusRequest = struct {
    integration_id: []const u8,
};

pub const IntegrationStatusResponse = struct {
    integration_id: []const u8,
    status: IntegrationStatus,
    last_error: ?[]const u8,
    rate_limit_remaining: ?u32,
    rate_limit_reset_at: ?i64,
};

pub const IntegrationDisconnectRequest = struct {
    integration_id: []const u8,
};

pub const IntegrationDisconnectResponse = struct {
    success: bool,
    message: []const u8,
};

pub const IntegrationTestRequest = struct {
    integration_id: []const u8,
};

pub const IntegrationTestResponse = struct {
    success: bool,
    status: IntegrationStatus,
    message: []const u8,
};

// GitHub Integration Messages
pub const GitHubCloneRequest = struct {
    integration_id: []const u8,
    repo_url: []const u8,
    branch: []const u8,
    destination: []const u8,
};

pub const GitHubCloneResponse = struct {
    success: bool,
    message: []const u8,
};

pub const GitHubCreatePRRequest = struct {
    integration_id: []const u8,
    owner: []const u8,
    repo: []const u8,
    title: []const u8,
    body: ?[]const u8,
    head_branch: []const u8,
    base_branch: []const u8,
};

pub const GitHubPullRequest = struct {
    number: u32,
    title: []const u8,
    body: ?[]const u8,
    state: []const u8,
    html_url: []const u8,
    head_branch: []const u8,
    base_branch: []const u8,
};

pub const GitHubCreatePRResponse = struct {
    success: bool,
    pull_request: ?GitHubPullRequest,
    message: []const u8,
};

pub const GitHubListReposRequest = struct {
    integration_id: []const u8,
    org: ?[]const u8,
};

pub const GitHubRepository = struct {
    id: u64,
    name: []const u8,
    full_name: []const u8,
    private: bool,
    clone_url: []const u8,
    default_branch: []const u8,
    description: ?[]const u8,
};

pub const GitHubListReposResponse = struct {
    success: bool,
    repositories: []const GitHubRepository,
    message: []const u8,
};

pub const GitHubWebhookRequest = struct {
    integration_id: []const u8,
    owner: []const u8,
    repo: []const u8,
    webhook_url: []const u8,
    events: []const []const u8,
    secret: []const u8,
};

pub const GitHubWebhookResponse = struct {
    success: bool,
    webhook_id: ?u64,
    message: []const u8,
};

// Docker Integration Messages
pub const DockerBuildRequest = struct {
    integration_id: []const u8,
    dockerfile_path: []const u8,
    context_path: []const u8,
    image_name: []const u8,
    tags: []const []const u8,
    build_args: []const types.EnvVar,
    multi_stage: bool,
};

pub const DockerBuildResponse = struct {
    success: bool,
    image_id: ?[]const u8,
    message: []const u8,
};

pub const DockerPushRequest = struct {
    integration_id: []const u8,
    image_name: []const u8,
    tag: []const u8,
    registry: []const u8,
};

pub const DockerPushResponse = struct {
    success: bool,
    message: []const u8,
};

pub const DockerRunRequest = struct {
    integration_id: []const u8,
    image: []const u8,
    name: ?[]const u8,
    ports: []const []const u8,
    environment: []const []const u8,
    volumes: []const []const u8,
    network: ?[]const u8,
    restart_policy: []const u8,
    healthcheck_cmd: ?[]const u8,
};

pub const DockerRunResponse = struct {
    success: bool,
    container_id: ?[]const u8,
    message: []const u8,
};

pub const DockerListImagesRequest = struct {
    integration_id: []const u8,
    repository_filter: ?[]const u8,
};

pub const DockerImage = struct {
    id: []const u8,
    repository: []const u8,
    tag: []const u8,
    created: i64,
    size: u64,
};

pub const DockerListImagesResponse = struct {
    success: bool,
    images: []const DockerImage,
    message: []const u8,
};

// AWS Integration Messages
pub const AwsDeployRequest = struct {
    integration_id: []const u8,
    service_type: []const u8, // "lambda", "ec2", "ecs", etc.
    deployment_config: []const types.EnvVar,
};

pub const AwsDeployResponse = struct {
    success: bool,
    deployment_id: ?[]const u8,
    endpoint: ?[]const u8,
    message: []const u8,
};

pub const AwsS3UploadRequest = struct {
    integration_id: []const u8,
    bucket_name: []const u8,
    key: []const u8,
    data: []const u8,
    content_type: ?[]const u8,
};

pub const AwsS3UploadResponse = struct {
    success: bool,
    url: ?[]const u8,
    message: []const u8,
};

pub const AwsLambdaInvokeRequest = struct {
    integration_id: []const u8,
    function_name: []const u8,
    payload: []const u8,
};

pub const AwsLambdaInvokeResponse = struct {
    success: bool,
    response: ?[]const u8,
    message: []const u8,
};

pub const AwsCloudWatchMetricRequest = struct {
    integration_id: []const u8,
    namespace: []const u8,
    metric_name: []const u8,
    value: f64,
    unit: []const u8,
    dimensions: []const types.EnvVar,
};

pub const AwsCloudWatchMetricResponse = struct {
    success: bool,
    message: []const u8,
};

// Extended message types for integrations
pub const ExtendedMessageType = enum(u8) {
    // Integration messages
    integration_list = 0x50,
    integration_list_response = 0x51,
    integration_connect = 0x52,
    integration_connect_response = 0x53,
    integration_status = 0x54,
    integration_status_response = 0x55,
    integration_disconnect = 0x56,
    integration_disconnect_response = 0x57,
    integration_test = 0x58,
    integration_test_response = 0x59,
    
    // GitHub integration
    github_clone = 0x60,
    github_clone_response = 0x61,
    github_create_pr = 0x62,
    github_create_pr_response = 0x63,
    github_list_repos = 0x64,
    github_list_repos_response = 0x65,
    github_webhook = 0x66,
    github_webhook_response = 0x67,
    
    // Docker integration
    docker_build = 0x70,
    docker_build_response = 0x71,
    docker_push = 0x72,
    docker_push_response = 0x73,
    docker_run = 0x74,
    docker_run_response = 0x75,
    docker_list_images = 0x76,
    docker_list_images_response = 0x77,
    
    // AWS integration
    aws_deploy = 0x80,
    aws_deploy_response = 0x81,
    aws_s3_upload = 0x82,
    aws_s3_upload_response = 0x83,
    aws_lambda_invoke = 0x84,
    aws_lambda_invoke_response = 0x85,
    aws_cloudwatch_metric = 0x86,
    aws_cloudwatch_metric_response = 0x87,
};