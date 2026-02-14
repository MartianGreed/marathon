export type IntegrationType = 
  | 'github'
  | 'docker_hub'
  | 'github_container_registry'
  | 'aws_ecr'
  | 'aws_s3'
  | 'aws_lambda'
  | 'aws_ec2'
  | 'aws_cloudwatch';

export type IntegrationStatus = 
  | 'disconnected'
  | 'connecting'
  | 'connected'
  | 'error'
  | 'rate_limited';

export interface Integration {
  id: string;
  integration_type: IntegrationType;
  name: string;
  status: IntegrationStatus;
  enabled: boolean;
  last_error?: string;
  created_at: number;
  updated_at: number;
}

export interface IntegrationStatusDetails {
  integration_id: string;
  status: IntegrationStatus;
  last_error?: string;
  rate_limit_remaining?: number;
  rate_limit_reset_at?: number;
}

export interface ConnectIntegrationRequest {
  integration_type: IntegrationType;
  name: string;
  credentials: Array<{ key: string; value: string }>;
  settings: Array<{ key: string; value: string }>;
}

export interface ConnectIntegrationResponse {
  success: boolean;
  integration_id?: string;
  message: string;
}

export interface TestIntegrationResponse {
  success: boolean;
  status: IntegrationStatus;
  message: string;
}

// Task related types (existing)
export interface Task {
  id: string;
  repo: string;
  branch: string;
  prompt: string;
  status: 'queued' | 'running' | 'completed' | 'failed' | 'cancelled';
  created_at: string;
  completed_at?: string;
  pr_url?: string;
  error?: string;
}

export interface User {
  email: string;
  api_key: string;
}

export interface AuthResponse {
  success: boolean;
  token?: string;
  api_key?: string;
  message: string;
}

// GitHub integration specific types
export interface GitHubRepository {
  id: number;
  name: string;
  full_name: string;
  private: boolean;
  clone_url: string;
  default_branch: string;
  description?: string;
}

export interface GitHubPullRequest {
  number: number;
  title: string;
  body?: string;
  state: string;
  html_url: string;
  head_branch: string;
  base_branch: string;
}

// Docker integration specific types
export interface DockerImage {
  id: string;
  repository: string;
  tag: string;
  created: number;
  size: number;
}

export interface DockerContainer {
  id: string;
  name: string;
  image: string;
  status: string;
  ports: string[];
  created: number;
}

// AWS integration specific types
export interface AwsS3Bucket {
  name: string;
  creation_date: string;
}

export interface AwsLambdaFunction {
  function_name: string;
  function_arn: string;
  runtime: string;
  handler: string;
  last_modified: string;
}

export interface AwsEc2Instance {
  instance_id: string;
  instance_type: string;
  state: string;
  public_ip?: string;
  private_ip: string;
  launch_time: string;
}