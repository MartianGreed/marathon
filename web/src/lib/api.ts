import type { 
  Integration, 
  IntegrationStatusDetails, 
  ConnectIntegrationRequest, 
  ConnectIntegrationResponse, 
  TestIntegrationResponse,
  Task,
  AuthResponse,
  UsageReport
} from './types';

const API_BASE = import.meta.env.VITE_API_URL || 'http://localhost:8081';

function getToken(): string | null {
  return localStorage.getItem('marathon_token');
}

function getHeaders(): Record<string, string> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  const token = getToken();
  if (token) headers['Authorization'] = `Bearer ${token}`;
  return headers;
}

// Auth endpoints
export async function register(email: string, password: string): Promise<AuthResponse> {
  const res = await fetch(`${API_BASE}/auth/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  const data = await res.json();
  if (data.token) {
    localStorage.setItem('marathon_token', data.token);
    localStorage.setItem('marathon_email', email);
    if (data.api_key) localStorage.setItem('marathon_api_key', data.api_key);
  }
  return data;
}

export async function login(email: string, password: string): Promise<AuthResponse> {
  const res = await fetch(`${API_BASE}/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  const data = await res.json();
  if (data.token) {
    localStorage.setItem('marathon_token', data.token);
    localStorage.setItem('marathon_email', email);
    if (data.api_key) localStorage.setItem('marathon_api_key', data.api_key);
  }
  return data;
}

export function logout() {
  localStorage.removeItem('marathon_token');
  localStorage.removeItem('marathon_email');
  localStorage.removeItem('marathon_api_key');
}

export function isAuthenticated(): boolean {
  return !!getToken();
}

export function getEmail(): string | null {
  return localStorage.getItem('marathon_email');
}

// Task endpoints
export async function listTasks(): Promise<Task[]> {
  const res = await fetch(`${API_BASE}/tasks`, { headers: getHeaders() });
  if (!res.ok) throw new Error('Failed to fetch tasks');
  return res.json();
}

export async function getTask(id: string): Promise<Task> {
  const res = await fetch(`${API_BASE}/tasks/${id}`, { headers: getHeaders() });
  if (!res.ok) throw new Error('Failed to fetch task');
  return res.json();
}

export async function getUsage(): Promise<UsageReport> {
  const res = await fetch(`${API_BASE}/usage`, { headers: getHeaders() });
  if (!res.ok) throw new Error('Failed to fetch usage');
  return res.json();
}

// Integration endpoints
export async function getIntegrations(): Promise<Integration[]> {
  const res = await fetch(`${API_BASE}/integrations`, { headers: getHeaders() });
  if (!res.ok) throw new Error('Failed to fetch integrations');
  const data = await res.json();
  return data.integrations || [];
}

export async function connectIntegration(request: ConnectIntegrationRequest): Promise<ConnectIntegrationResponse> {
  const res = await fetch(`${API_BASE}/integrations/connect`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify(request),
  });
  if (!res.ok) throw new Error('Failed to connect integration');
  return res.json();
}

export async function disconnectIntegration(integrationId: string): Promise<{ success: boolean; message: string }> {
  const res = await fetch(`${API_BASE}/integrations/${integrationId}/disconnect`, {
    method: 'DELETE',
    headers: getHeaders(),
  });
  if (!res.ok) throw new Error('Failed to disconnect integration');
  return res.json();
}

export async function testIntegration(integrationId: string): Promise<TestIntegrationResponse> {
  const res = await fetch(`${API_BASE}/integrations/${integrationId}/test`, {
    method: 'POST',
    headers: getHeaders(),
  });
  if (!res.ok) throw new Error('Failed to test integration');
  return res.json();
}

export async function getIntegrationStatus(integrationId: string): Promise<IntegrationStatusDetails> {
  const res = await fetch(`${API_BASE}/integrations/${integrationId}/status`, { 
    headers: getHeaders() 
  });
  if (!res.ok) throw new Error('Failed to get integration status');
  return res.json();
}

// GitHub integration endpoints
export async function gitHubCloneRepo(integrationId: string, repoUrl: string, branch: string, destination: string): Promise<{ success: boolean; message: string }> {
  const res = await fetch(`${API_BASE}/github/clone`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify({
      integration_id: integrationId,
      repo_url: repoUrl,
      branch,
      destination,
    }),
  });
  if (!res.ok) throw new Error('Failed to clone repository');
  return res.json();
}

export async function gitHubCreatePR(
  integrationId: string, 
  owner: string, 
  repo: string, 
  title: string, 
  body: string | undefined, 
  headBranch: string, 
  baseBranch: string
): Promise<{ success: boolean; pull_request?: any; message: string }> {
  const res = await fetch(`${API_BASE}/github/create-pr`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify({
      integration_id: integrationId,
      owner,
      repo,
      title,
      body,
      head_branch: headBranch,
      base_branch: baseBranch,
    }),
  });
  if (!res.ok) throw new Error('Failed to create pull request');
  return res.json();
}

export async function gitHubListRepos(integrationId: string, org?: string): Promise<{ success: boolean; repositories: any[]; message: string }> {
  const res = await fetch(`${API_BASE}/github/list-repos`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify({
      integration_id: integrationId,
      org,
    }),
  });
  if (!res.ok) throw new Error('Failed to list repositories');
  return res.json();
}

// Docker integration endpoints
export async function dockerBuild(
  integrationId: string,
  dockerfilePath: string,
  contextPath: string,
  imageName: string,
  tags: string[],
  buildArgs: Array<{ key: string; value: string }> = [],
  multiStage: boolean = false
): Promise<{ success: boolean; image_id?: string; message: string }> {
  const res = await fetch(`${API_BASE}/docker/build`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify({
      integration_id: integrationId,
      dockerfile_path: dockerfilePath,
      context_path: contextPath,
      image_name: imageName,
      tags,
      build_args: buildArgs,
      multi_stage: multiStage,
    }),
  });
  if (!res.ok) throw new Error('Failed to build Docker image');
  return res.json();
}

export async function dockerPush(integrationId: string, imageName: string, tag: string, registry: string): Promise<{ success: boolean; message: string }> {
  const res = await fetch(`${API_BASE}/docker/push`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify({
      integration_id: integrationId,
      image_name: imageName,
      tag,
      registry,
    }),
  });
  if (!res.ok) throw new Error('Failed to push Docker image');
  return res.json();
}

export async function dockerListImages(integrationId: string, repositoryFilter?: string): Promise<{ success: boolean; images: any[]; message: string }> {
  const res = await fetch(`${API_BASE}/docker/images`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify({
      integration_id: integrationId,
      repository_filter: repositoryFilter,
    }),
  });
  if (!res.ok) throw new Error('Failed to list Docker images');
  return res.json();
}

// AWS integration endpoints
export async function awsDeploy(integrationId: string, serviceType: string, deploymentConfig: Array<{ key: string; value: string }>): Promise<{ success: boolean; deployment_id?: string; endpoint?: string; message: string }> {
  const res = await fetch(`${API_BASE}/aws/deploy`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify({
      integration_id: integrationId,
      service_type: serviceType,
      deployment_config: deploymentConfig,
    }),
  });
  if (!res.ok) throw new Error('Failed to deploy to AWS');
  return res.json();
}

export async function awsS3Upload(
  integrationId: string, 
  bucketName: string, 
  key: string, 
  data: string, 
  contentType?: string
): Promise<{ success: boolean; url?: string; message: string }> {
  const res = await fetch(`${API_BASE}/aws/s3-upload`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify({
      integration_id: integrationId,
      bucket_name: bucketName,
      key,
      data,
      content_type: contentType,
    }),
  });
  if (!res.ok) throw new Error('Failed to upload to S3');
  return res.json();
}

export async function awsLambdaInvoke(integrationId: string, functionName: string, payload: string): Promise<{ success: boolean; response?: string; message: string }> {
  const res = await fetch(`${API_BASE}/aws/lambda-invoke`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify({
      integration_id: integrationId,
      function_name: functionName,
      payload,
    }),
  });
  if (!res.ok) throw new Error('Failed to invoke Lambda function');
  return res.json();
}

export async function awsCloudWatchMetric(
  integrationId: string,
  namespace: string,
  metricName: string,
  value: number,
  unit: string,
  dimensions: Array<{ key: string; value: string }> = []
): Promise<{ success: boolean; message: string }> {
  const res = await fetch(`${API_BASE}/aws/cloudwatch-metric`, {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify({
      integration_id: integrationId,
      namespace,
      metric_name: metricName,
      value,
      unit,
      dimensions,
    }),
  });
  if (!res.ok) throw new Error('Failed to publish CloudWatch metric');
  return res.json();
}

export type { Task, AuthResponse };