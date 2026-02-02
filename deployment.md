# Deploying Marathon on Dokploy

## Prerequisites

- A Dokploy instance
- DNS A record pointing your domain (e.g. `orchestrator.example.com`) to the Dokploy server IP
- Docker images built and available (`marathon/orchestrator:latest`)

## Compose Configuration

Marathon uses a custom TCP protocol (MRTN magic header), not HTTP. Dokploy's Traefik forces HTTP parsing on the `websecure` entrypoint, so the orchestrator exposes port 8443 directly, bypassing Traefik entirely.

The compose file is at `orchestrator/compose.yaml`. Key points:

- Port 8443 on the host maps to 8080 inside the container (direct TCP, no Traefik)
- All services have `restart: unless-stopped`
- No Traefik labels — the MRTN protocol is incompatible with Dokploy's HTTP-only Traefik config

## Environment Variables

Set these in the Dokploy UI under your project's environment configuration:

| Variable | Required | Description |
|---|---|---|
| `MARATHON_ANTHROPIC_API_KEY` | Yes | Anthropic API key for Claude |
| `POSTGRES_USER` | Yes | PostgreSQL user |
| `POSTGRES_PASSWORD` | Yes | PostgreSQL password |
| `POSTGRES_DB` | Yes | PostgreSQL database |
| `MARATHON_NODE_AUTH_KEY` | No | Shared key for node operator auth |

## Dokploy UI Setup

1. In Dokploy, create a new **Compose** project
2. Point to the repo (compose path: `orchestrator/compose.yaml`)
3. Go to **Environment** and set the required variables
4. Deploy the project

## Client Connection

Connect directly to port 8443 without TLS:

```bash
MARATHON_ORCHESTRATOR_ADDRESS=orchestrator.example.com \
MARATHON_ORCHESTRATOR_PORT=8443 \
MARATHON_TLS_ENABLED=false \
marathon submit --repo https://github.com/user/repo --prompt "task"
```

**Note:** Port 8443 is plain TCP (no encryption). For production, add server-side TLS to the orchestrator directly.

## Verification

```bash
docker compose ps                    # all services should be "Up"
docker compose logs orchestrator     # check for successful startup
```

Test client connection:

```bash
MARATHON_ORCHESTRATOR_ADDRESS=orchestrator.example.com \
MARATHON_ORCHESTRATOR_PORT=8443 \
MARATHON_TLS_ENABLED=false \
marathon status
```
