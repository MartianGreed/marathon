# Deploying Marathon

Build Rust images from the repository root:
```bash
docker build -f deploy/Dockerfile.orchestrator -t marathon/orchestrator:latest .
docker build --platform linux/amd64 -f deploy/Dockerfile.node-operator -t marathon/node-operator:latest .
```

The images use an Alpine Rust builder with musl and protoc. The orchestrator runtime is Alpine with certificates and a TCP health check on its gRPC port 8080, running as `nobody`. The node runtime includes Firecracker and jailer and requires an x86_64 Linux KVM host. It opens an outbound heartbeat stream and exposes no listening port.

## TLS and routing

Marathon uses tonic gRPC over HTTP/2. Traefik terminates TLS on port 443 and routes HTTP requests to `h2c://orchestrator:8080`, preserving gRPC streams. This follows [Traefik's documented gRPC configuration](https://doc.traefik.io/traefik/master/user-guides/grpc/). Local validation passed with `traefik:v3`, the same `TRAEFIK_*` static configuration as `compose.yaml`, and `traefik/dynamic.yaml`; only the backend address changed to reach the host orchestrator, and a local test CA replaced ACME. With `MARATHON_TLS_ENABLED=true` and `MARATHON_TLS_CA_PATH` set to that CA, `marathon register`, the server-streaming `submit` response, and `marathon status` worked through Traefik. The node operator registered over its bidirectional heartbeat stream, received the submitted task over that stream, and reported failure because Firecracker was missing on macOS. Rustls rejects a self-signed certificate that is its own CA with `CaUsedAsEndEntity`; for a private CA, sign a leaf certificate and provide the CA through `MARATHON_TLS_CA_PATH`. The backend remains plaintext within the private container network.

Root `compose.yaml` includes Traefik with a dynamic file provider and static settings supplied entirely through environment variables. Only the dynamic file is mounted, because [Traefik does not support mixing static configuration methods](https://doc.traefik.io/traefik/reference/install-configuration/boot-environment/). `traefik/traefik.yaml` is a standalone static file example; replace its email before using it directly. Set `MARATHON_DOMAIN` and `MARATHON_ACME_EMAIL`; the latter maps to Traefik's static configuration environment variable. Allow inbound 443 for the ACME TLS challenge. `traefik/dynamic.yaml` reads the domain using the file provider's template syntax.

For Dokploy, use `orchestrator/compose.yaml`. It retains the direct `8443:8080` mapping, serving plaintext h2c on port 8443; clients must leave `MARATHON_TLS_ENABLED=false`. The Rust orchestrator starts with an optional node auth key. An absent variable disables node authentication; an explicitly empty value is still configured and requires matching HMAC authentication from nodes. Dokploy retains `${MARATHON_NODE_AUTH_KEY:-}`; set the same value on the nodes.

Moving Dokploy behind its Traefik is a follow-up requiring validation against that deployment. Example labels, using its actual network, entrypoint and certificate resolver:
```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.marathon.rule=Host(`${MARATHON_DOMAIN}`)"
  - "traefik.http.routers.marathon.entrypoints=websecure"
  - "traefik.http.routers.marathon.tls.certresolver=letsencrypt"
  - "traefik.http.services.marathon.loadbalancer.server.port=8080"
  - "traefik.http.services.marathon.loadbalancer.server.scheme=h2c"
  - "traefik.docker.network=dokploy-network"
```

## Configuration and startup

Set `POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_DB`, plus `MARATHON_JWT_SECRET` and `MARATHON_NODE_AUTH_KEY`. The orchestrator receives `MARATHON_POSTGRES_URL` from compose. Set `MARATHON_ANTHROPIC_API_KEY` for actual task execution. Use strong deployment-specific secrets rather than the example values. Redis and etcd are retained in compose but are not used by the current Rust services.

```bash
docker compose up -d --build
docker compose ps
docker compose logs orchestrator
```

Connect using the Rust client:
```bash
export MARATHON_ORCHESTRATOR_ADDRESS=orchestrator.example.com
export MARATHON_ORCHESTRATOR_PORT=443
export MARATHON_TLS_ENABLED=true
marathon register --email user@example.com
marathon login --email user@example.com
marathon submit --repo https://github.com/user/repo --prompt "task"
marathon status <task-id>
marathon usage
```

`MARATHON_TLS_CA_PATH` selects a custom CA. Node operators use the same address, port, TLS settings, and shared node auth key. `MARATHON_TOTAL_VM_SLOTS`, `MARATHON_WARM_POOL_TARGET`, `MARATHON_SNAPSHOT_PATH`, `MARATHON_KERNEL_PATH`, and `MARATHON_ROOTFS_PATH` configure VM capacity and files. `scripts/deploy-node.sh` installs a Linux release binary from `target/release/`.

## Kubernetes

Build and publish the images before applying `deploy/k8s/`. Replace secret placeholders, using the same node auth key for both components. The node DaemonSet selects amd64 compute hosts, mounts `/dev/kvm`, and runs privileged. Its hostname comes from the Kubernetes node name; its ID is generated unless explicitly configured. The orchestrator enables metrics on 9090 and gRPC on 8080. The external LoadBalancer exposes plaintext 8080; add TLS termination before using it publicly, or configure `MARATHON_TLS_CERT_PATH` and `MARATHON_TLS_KEY_PATH` for server TLS. A plain LoadBalancer does not supply TLS on its own.

## Verification still owed

A local macOS smoke can verify PostgreSQL persistence, outbound node heartbeat registration, and client register/login/whoami/submit/status/usage with warm pools disabled. Task completion requires a real Firecracker end-to-end run on an x86_64 KVM host, which is owed until recorded. Image builds and CI configuration checks do not establish VM execution or production TLS routing.
