# Testing Stack Architecture

## Network & Services

Docker bridge network `172.28.0.0/16` with 8 containers:

| Container | IP | Ports (host) | Role |
|---|---|---|---|
| `test-postgres` | `.2` | — | PostgreSQL 16 |
| `test-pangolin` | `.3` | `3000` (Next.js), `3001` (API), `3002` (WS) | Control plane (OSS + PG) |
| `test-gerbil` | `.5` | `51820/udp` | WireGuard relay (prebuilt `fosrl/gerbil:latest`) |
| `test-newt` | `.10` | `5353→53`, `8080`, `8443` | Site agent 1 (DNS Authority + Auth Proxy) |
| `test-newt-secondary` | `.11` | `5354→53`, `8089→8080`, `8449→8443` | Site agent 2 (failover) |
| `test-backend` | `.20` | — | nginx primary (`/health`, `/api/whoami`) |
| `test-backend-secondary` | `.21` | — | nginx secondary |
| `test-client` | `.100` | — | Alpine with curl/dig/jq/tcpdump/nmap/python3 |

## Pangolin Test Container

Built from `../pangolin` with `services/pangolin/Dockerfile` (node:22-alpine). Configured as **OSS + PostgreSQL**: generates `server/build.ts` with `"oss"`, copies `tsconfig.oss.json`, sets PG driver. Runs `npm run db:pg:push && npm run dev`.

**Hot-reload mounts** (read-only over baked copies):
- `../pangolin/server/routers` → `/app/server/routers`
- `../pangolin/server/lib` → `/app/server/lib`
- `../pangolin/server/private` → `/app/server/private`
- `../pangolin/src` → `/app/src`

Changes to these directories are reflected without rebuilding the container. Files outside these mounts (e.g., `server/db/`, `server/setup/`, `server/index.ts`) require `docker compose build pangolin`.

**Build-testing Pangolin inside the container:**
```bash
docker exec test-pangolin rm -rf .next && docker exec -e NODE_ENV=production test-pangolin npx next build
```

## Newt Test Containers

Built from `../newt` with `services/newt/Dockerfile` (Go 1.25, static binary). Both share `config/newt/` mount; env vars override `NEWT_ID` (`test-newt-001` / `test-newt-002`). Both have `NET_ADMIN` + `NET_RAW` capabilities.

Key env: `PANGOLIN_ENDPOINT=http://pangolin:3002`, `DNS_AUTHORITY_ENABLED=true`, `AUTH_PROXY_ENABLED=true`.

## Connection Flow

1. Gerbil starts → fetches config from Pangolin → creates `wg0`
2. Newt connects via WebSocket (port 3002) → registers → pings Gerbil for latency
3. Pangolin allocates WireGuard subnet → adds Newt as peer on Gerbil
4. Pangolin sends `newt/wg/connect` → Newt establishes userspace WireGuard tunnel
5. Gerbil reports bandwidth → Pangolin marks site online
6. Pangolin pushes DNS Authority zone configs to Newt via WebSocket

## Bootstrap Provisioning (`scripts/bootstrap.sh`)

Runs from host against `http://localhost:3001/api/v1`. Idempotent — checks existence before creating.

1. Wait for Pangolin API readiness
2. Extract setup token from `docker logs test-pangolin` if initial setup not done
3. Create server admin (`admin@test.dev` / `TestAdmin123!`)
4. Login → store cookies
5. Create org `test-org` (auto-picks subnet from `/pick-org-defaults`)
6. Create 2 sites: `test-newt-001` (publicIp `.10`) and `test-newt-002` (publicIp `.11`), enable DNS Authority on each
7. Create resource `app.test.dev` with 2 targets (backends at `.20:80` and `.21:80`), enable DNS Authority with failover
8. Verify DNS with `dig @localhost -p 5353 app.test.dev A`

## Pangolin Config (`config/pangolin/config.yml`)

Key values: domain ID `test-domain` with base `test.dev`; gerbil subnet `100.89.137.0/20`; server secret is test-only; `allow_raw_resources: true`; email verification disabled.

## Stack Commands (`test-stack.sh`)

| Command | Action |
|---|---|
| `build` | `docker compose build --parallel` |
| `start` | `docker compose up -d` + health wait |
| `stop` / `clean` | Down (clean also removes volumes) |
| `test` | Runs `scripts/run-tests.sh` inside test-client |
| `shell` | Exec bash into test-client |
| `dns [domain]` | `dig @172.28.0.10 <domain> A` via test-client |
| `status` | Container status + health checks |

## Dependency Chain

```
postgres ← pangolin ← gerbil ← [newt, newt-secondary]
                                [newt, newt-secondary, backend*] ← test-client
```

All `depends_on` use `condition: service_healthy`.
