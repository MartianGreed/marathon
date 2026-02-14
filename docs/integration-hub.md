# Marathon Integration Hub

The Marathon Integration Hub is a comprehensive system that connects Marathon with popular development tools and cloud services, enabling seamless automation and workflow orchestration.

## Overview

The Integration Hub provides:

- **Universal Connectivity**: Connect to GitHub, Docker registries, and AWS services
- **Secure Credential Management**: Encrypted storage with key rotation
- **Rate Limiting**: Built-in protection against API quota exhaustion
- **Health Monitoring**: Real-time status checking and alerting
- **Plugin Architecture**: Extensible design for adding new services

## Supported Integrations

### GitHub Integration
- Repository cloning and management
- Pull request creation, review, and merge automation
- Issue tracking and synchronization with Marathon tasks
- Branch management and protection rules
- GitHub Actions workflow integration
- Webhook handling for repository events

### Docker Integration
- Container image building and management
- Docker registry integration (Docker Hub, GitHub Container Registry)
- Container deployment and orchestration
- Health checks and service monitoring
- Multi-stage build optimization
- Docker Compose service management

### AWS Integration
- **S3**: Bucket management, file storage, and artifact handling
- **ECR**: Container registry for Docker images
- **Lambda**: Function deployment and management
- **CloudWatch**: Logs, monitoring, and metrics collection
- **EC2**: Instance management for remote execution
- **IAM**: Role and permission management

## Architecture

### Core Components

```
┌─────────────────────────────────────────────────────────────┐
│                    Marathon Integration Hub                  │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌──────────────────┐  ┌─────────────┐ │
│  │ CLI Commands    │  │ Web UI Dashboard │  │ API Endpoints│ │
│  │ - integration   │  │ - Service Cards  │  │ - REST/gRPC │ │
│  │ - github        │  │ - Setup Modals   │  │ - WebSockets│ │
│  │ - docker        │  │ - Status Views   │  │ - Webhooks  │ │
│  │ - aws           │  │ - Activity Logs  │  │             │ │
│  └─────────────────┘  └──────────────────┘  └─────────────┘ │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌──────────────────┐  ┌─────────────┐ │
│  │ Integration     │  │ Credential       │  │ Rate        │ │
│  │ Manager         │  │ Manager          │  │ Limiter     │ │
│  │ - Connectors    │  │ - Encryption     │  │ - Throttling│ │
│  │ - Health Checks │  │ - Key Rotation   │  │ - Retry Logic│ │
│  │ - Status Mgmt   │  │ - Secure Storage │  │ - Quotas    │ │
│  └─────────────────┘  └──────────────────┘  └─────────────┘ │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌──────────────────┐  ┌─────────────┐ │
│  │ GitHub Client   │  │ Docker Client    │  │ AWS Client  │ │
│  │ - API Wrapper   │  │ - Registry APIs  │  │ - Multi-svc │ │
│  │ - OAuth Flow    │  │ - Build Engine   │  │ - SDK Compat│ │
│  │ - Webhook Mgmt  │  │ - Compose Mgmt   │  │ - IAM Auth  │ │
│  └─────────────────┘  └──────────────────┘  └─────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Database Schema

The integration system uses three main tables:

#### integrations
```sql
CREATE TABLE integrations (
    id VARCHAR(255) PRIMARY KEY,
    integration_type SMALLINT NOT NULL,
    name VARCHAR(255) NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT true,
    settings JSONB NOT NULL DEFAULT '{}',
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    last_error TEXT,
    rate_limit_remaining INTEGER,
    rate_limit_reset_at BIGINT,
    user_id VARCHAR(255)
);
```

#### integration_credentials
```sql
CREATE TABLE integration_credentials (
    id SERIAL PRIMARY KEY,
    integration_id VARCHAR(255) NOT NULL,
    encrypted_data BYTEA NOT NULL,
    nonce BYTEA NOT NULL,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    rotation_count INTEGER NOT NULL DEFAULT 0
);
```

#### integration_activity_log
```sql
CREATE TABLE integration_activity_log (
    id SERIAL PRIMARY KEY,
    integration_id VARCHAR(255) NOT NULL,
    activity_type VARCHAR(50) NOT NULL,
    description TEXT,
    metadata JSONB,
    success BOOLEAN NOT NULL,
    error_message TEXT,
    timestamp BIGINT NOT NULL
);
```

## CLI Usage

### Integration Management

```bash
# List all configured integrations
marathon integration list

# Setup a new integration
marathon integration connect github
marathon integration connect docker-hub
marathon integration connect aws-s3

# Check integration status
marathon integration status github-1

# Test connection
marathon integration test github-1

# Remove integration
marathon integration disconnect github-1
```

### GitHub Operations

```bash
# Clone repository
marathon github clone --integration-id github-1 \
  --repo owner/repository \
  --branch feature-branch \
  --dest ./local-repo

# Create pull request
marathon github create-pr --integration-id github-1 \
  --repo owner/repository \
  --title "Add new feature" \
  --body "Description of changes" \
  --head-branch feature-branch \
  --base-branch main

# List repositories
marathon github list-repos --integration-id github-1

# Setup webhook
marathon github webhook --integration-id github-1 \
  --repo owner/repository \
  --url https://api.marathon.dev/webhooks/github \
  --events push,pull_request
```

### Docker Operations

```bash
# Build container image
marathon docker build --integration-id docker-1 \
  --dockerfile Dockerfile \
  --context . \
  --image myapp \
  --tag latest,v1.0

# Push to registry
marathon docker push --integration-id docker-1 \
  --image myapp \
  --tag latest \
  --registry docker.io

# Run container
marathon docker run --integration-id docker-1 \
  --image myapp:latest \
  --name web-server \
  --port 8080:80 \
  --env NODE_ENV=production

# List images
marathon docker images --integration-id docker-1
```

### AWS Operations

```bash
# Deploy to AWS Lambda
marathon aws deploy --integration-id aws-1 \
  --service lambda \
  --function-name my-function \
  --runtime nodejs18.x \
  --handler index.handler \
  --zip-file function.zip

# Upload to S3
marathon aws s3-upload --integration-id aws-1 \
  --bucket my-bucket \
  --key artifacts/build-123.tar.gz \
  --file ./build.tar.gz

# Invoke Lambda function
marathon aws lambda-invoke --integration-id aws-1 \
  --function my-function \
  --payload '{"key":"value"}'

# Publish CloudWatch metric
marathon aws cloudwatch-metric --integration-id aws-1 \
  --namespace "Marathon/Tasks" \
  --metric TasksCompleted \
  --value 1 \
  --unit Count
```

## Web UI

### Integration Dashboard

The web interface provides a comprehensive dashboard for managing integrations:

1. **Service Overview**: Cards showing connected services and their status
2. **Quick Setup**: One-click connection for popular services
3. **Status Monitoring**: Real-time health checks and error reporting
4. **Activity Logs**: Detailed history of integration activities
5. **Configuration Management**: Easy credential updates and settings

### Key Features

- **Visual Status Indicators**: Green/red/yellow status icons
- **Rate Limit Monitoring**: Progress bars showing API quota usage
- **Error Diagnostics**: Detailed error messages and troubleshooting
- **Quick Actions**: Common operations directly from the dashboard
- **Setup Wizards**: Guided configuration for new integrations

## Security

### Credential Management

- **Encryption**: All credentials encrypted using ChaCha20-Poly1305
- **Key Rotation**: Automatic rotation of encryption keys
- **Secure Storage**: Credentials never stored in plaintext
- **Access Control**: Integration-specific permission scoping

### Authentication Flow

1. User provides credentials through secure setup flow
2. Credentials encrypted with master key
3. Stored in dedicated credentials table
4. Retrieved and decrypted only when needed
5. Never logged or exposed in error messages

### Rate Limiting

- **Request Throttling**: Built-in rate limiting per integration
- **Quota Monitoring**: Real-time tracking of API usage
- **Backoff Strategy**: Exponential backoff for failed requests
- **Alert System**: Notifications when approaching limits

## Development

### Adding New Integrations

To add support for a new service:

1. **Create Client Module**: Implement API wrapper in `orchestrator/src/integrations/`
2. **Add Message Types**: Define protocol messages in `common/src/protocol_extensions.zig`
3. **Update CLI**: Add commands in `client/src/integration_commands.zig`
4. **Add UI Components**: Create React components for web interface
5. **Write Tests**: Include comprehensive test coverage

### Example Integration Structure

```zig
pub const NewServiceClient = struct {
    allocator: std.mem.Allocator,
    credentials: ?ServiceCredentials,
    rate_limiter: RateLimiter,
    
    pub fn init(allocator: std.mem.Allocator) NewServiceClient {
        return .{
            .allocator = allocator,
            .credentials = null,
            .rate_limiter = RateLimiter.init(),
        };
    }
    
    pub fn setCredentials(self: *NewServiceClient, creds: ServiceCredentials) !void {
        self.credentials = creds;
    }
    
    pub fn testConnection(self: *NewServiceClient) IntegrationStatus {
        // Implementation
    }
    
    pub fn performAction(self: *NewServiceClient, params: ActionParams) !ActionResult {
        // Implementation
    }
};
```

## Monitoring and Observability

### Health Checks

Each integration provides health check endpoints that monitor:

- API connectivity status
- Authentication validity  
- Rate limit status
- Service availability
- Error rates

### Metrics Collection

The system automatically collects:

- Request counts and latencies
- Error rates by type
- Rate limit utilization
- Integration usage patterns
- Performance metrics

### Logging

Structured logging captures:

- Integration operations
- Authentication events
- Error conditions
- Performance data
- Security events

## Troubleshooting

### Common Issues

#### Connection Failures
- Check credential validity
- Verify network connectivity
- Review rate limiting status
- Validate service availability

#### Authentication Errors
- Regenerate access tokens
- Check permission scopes
- Verify credential encryption
- Test authentication flow

#### Rate Limiting
- Monitor quota usage
- Implement backoff strategies
- Distribute load across time
- Consider multiple integrations

### Debugging Tools

```bash
# Enable debug logging
MARATHON_DEBUG=1 marathon integration test github-1

# Check integration logs
marathon integration logs github-1

# View health status
marathon integration health --all

# Test connectivity
marathon integration ping github-1
```

## Best Practices

### Security

1. **Rotate Keys Regularly**: Set up automatic key rotation
2. **Scope Permissions**: Use minimal required permissions
3. **Monitor Access**: Log all integration activities
4. **Validate Inputs**: Sanitize all user inputs
5. **Encrypt Transport**: Use TLS for all communications

### Performance

1. **Connection Pooling**: Reuse HTTP connections
2. **Async Operations**: Use non-blocking I/O
3. **Caching**: Cache frequently accessed data
4. **Batch Requests**: Group multiple operations
5. **Monitor Metrics**: Track performance indicators

### Reliability

1. **Error Handling**: Graceful degradation on failures
2. **Retry Logic**: Exponential backoff with jitter
3. **Circuit Breakers**: Prevent cascade failures
4. **Health Checks**: Regular connectivity testing
5. **Fallback Plans**: Alternative integration paths

## API Reference

### REST Endpoints

```http
GET    /api/v1/integrations
POST   /api/v1/integrations
GET    /api/v1/integrations/{id}
PUT    /api/v1/integrations/{id}
DELETE /api/v1/integrations/{id}
POST   /api/v1/integrations/{id}/test
GET    /api/v1/integrations/{id}/status
GET    /api/v1/integrations/{id}/logs
```

### gRPC Services

```protobuf
service IntegrationService {
  rpc ListIntegrations(ListIntegrationsRequest) returns (ListIntegrationsResponse);
  rpc ConnectIntegration(ConnectIntegrationRequest) returns (ConnectIntegrationResponse);
  rpc TestIntegration(TestIntegrationRequest) returns (TestIntegrationResponse);
  rpc GetIntegrationStatus(GetIntegrationStatusRequest) returns (GetIntegrationStatusResponse);
}
```

### WebSocket Events

```javascript
// Connection status updates
{
  "type": "integration.status.changed",
  "integration_id": "github-1",
  "status": "connected",
  "timestamp": 1640995200
}

// Rate limit warnings
{
  "type": "integration.rate_limit.warning",
  "integration_id": "github-1",
  "remaining": 100,
  "reset_at": 1640995200
}
```

## Contributing

To contribute to the Integration Hub:

1. **Fork the Repository**: Create your own fork
2. **Create Feature Branch**: Work on focused changes
3. **Write Tests**: Include comprehensive test coverage
4. **Update Documentation**: Keep docs current
5. **Submit Pull Request**: Follow the contribution guidelines

### Development Setup

```bash
# Clone repository
git clone https://github.com/MartianGreed/marathon.git
cd marathon

# Setup development environment
make setup-dev

# Run integration tests
make test-integrations

# Start development servers
make dev-orchestrator
make dev-web
```

For more detailed development information, see the [Development Guide](./development.md).