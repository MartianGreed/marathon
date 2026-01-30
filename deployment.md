# Deploying Marathon on Dokploy

## Prerequisites

- A Dokploy instance with Let's Encrypt configured
- DNS A record pointing your domain (e.g. `marathon.example.com`) to the Dokploy server IP
- Docker images built and available (`marathon/orchestrator:latest`)

## Compose Configuration

Marathon uses a custom TCP protocol (MRTN magic header), not HTTP. Dokploy's built-in domain routing only handles HTTP, so we use **manual Traefik TCP labels** on the orchestrator service for TCP routing with TLS termination.

Create a `compose.yaml` adapted for Dokploy — the standalone Traefik service is removed since Dokploy provides its own Traefik instance:

```yaml
services:
  orchestrator:
    image: marathon/orchestrator:latest
    environment:
      MARATHON_ANTHROPIC_API_KEY: ${MARATHON_ANTHROPIC_API_KEY}
      MARATHON_POSTGRES_URL: postgresql://${POSTGRES_USER:-marathon}:${POSTGRES_PASSWORD:-marathon}@postgres:5432/${POSTGRES_DB:-marathon}
      MARATHON_REDIS_URL: redis://redis:6379
    labels:
      - "traefik.enable=true"
      - "traefik.tcp.routers.marathon.rule=HostSNI(`${MARATHON_DOMAIN}`)"
      - "traefik.tcp.routers.marathon.entrypoints=websecure"
      - "traefik.tcp.routers.marathon.tls=true"
      - "traefik.tcp.routers.marathon.tls.certresolver=letsencrypt"
      - "traefik.tcp.services.marathon.loadbalancer.server.port=50051"
    networks:
      - default
      - dokploy-network
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
      etcd:
        condition: service_healthy

  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-marathon}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-marathon}
      POSTGRES_DB: ${POSTGRES_DB:-marathon}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U marathon"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5

  etcd:
    image: quay.io/coreos/etcd:v3.5.17
    environment:
      ETCD_ADVERTISE_CLIENT_URLS: "http://0.0.0.0:2379"
      ETCD_LISTEN_CLIENT_URLS: "http://0.0.0.0:2379"
    volumes:
      - etcd_data:/etcd-data
    command:
      - etcd
      - --data-dir=/etcd-data
    healthcheck:
      test: ["CMD", "etcdctl", "endpoint", "health"]
      interval: 5s
      timeout: 5s
      retries: 5

volumes:
  postgres_data:
  redis_data:
  etcd_data:

networks:
  dokploy-network:
    external: true
```

Key differences from the standalone `compose.yaml`:

- **Removed** the `traefik` service and `letsencrypt_data` volume — Dokploy provides Traefik
- **Added** Traefik TCP labels on `orchestrator` for TLS termination via `HostSNI`
- **Added** `dokploy-network` (external) so Dokploy's Traefik can reach the orchestrator
- **Removed** host port bindings on `postgres`, `redis`, and `etcd` — no need to expose them

## Environment Variables

Set these in the Dokploy UI under your project's environment configuration:

| Variable | Required | Description |
|---|---|---|
| `MARATHON_DOMAIN` | Yes | Domain for TLS routing (e.g. `marathon.example.com`) |
| `MARATHON_ANTHROPIC_API_KEY` | Yes | Anthropic API key for Claude |
| `POSTGRES_USER` | No | PostgreSQL user (default: `marathon`) |
| `POSTGRES_PASSWORD` | No | PostgreSQL password (default: `marathon`) |
| `POSTGRES_DB` | No | PostgreSQL database (default: `marathon`) |

## Dokploy UI Setup

1. In Dokploy, create a new **Compose** project
2. Paste the compose configuration above (or point to your repo)
3. Go to **Environment** and set the required variables (`MARATHON_DOMAIN`, `MARATHON_ANTHROPIC_API_KEY`)
4. Set strong values for `POSTGRES_USER` and `POSTGRES_PASSWORD` in production
5. Deploy the project

## Verification

Check that all services are running:

```bash
docker compose ps
```

Check orchestrator logs for successful startup:

```bash
docker compose logs orchestrator
```

Test client connection with TLS:

```bash
marathon --host marathon.example.com --port 443 --tls status
```

If the connection fails, verify:

- DNS resolves to the Dokploy server IP
- Dokploy's Traefik is listening on port 443
- The orchestrator container is on the `dokploy-network`
- Let's Encrypt certificate was issued (check Traefik logs: `docker logs dokploy-traefik`)
