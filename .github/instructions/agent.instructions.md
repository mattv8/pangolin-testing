# Fossorial Monorepo — Agent Instructions

## Architecture

Four repos forming a WireGuard-based remote access platform:

| Component | Lang | Role | Key paths |
|---|---|---|---|
| **Pangolin** | TS (Next.js 15 + Express 5) | Control plane — API, WS server, dashboard | `server/routers/`, `server/db/`, `src/` |
| **Newt** | Go 1.25 | Site agent — DNS Authority, Auth Proxy, WG tunnel | `dns/`, `websocket/`, `proxy/` |
| **OLM** | Go 1.25 | End-user client — connects through Gerbil relay | `olm/`, `peers/`, `dns/` |
| **Testing** | Docker Compose + Bash | E2E stack on `172.28.0.0/16` | `docker-compose.yml`, `scripts/` |

**Data flow:** OLM ↔ Gerbil (WG relay) ↔ Newt → Private Services. Pangolin orchestrates via WebSocket messages and REST API.

## Key Conventions

### Pangolin (TypeScript)

**Build variants:** Three modes (`oss`/`enterprise`/`saas`) set by `npm run set:oss`. Generates `server/build.ts` and copies matching `tsconfig.{variant}.json` → `tsconfig.json`. The `#dynamic/*` import alias switches between OSS and private implementations — never import `#private/` from OSS code.

**DB drivers:** `npm run set:sqlite` or `set:pg` generates `server/db/index.ts`. Two schema files (`server/db/pg/schema.ts` and `server/db/sqlite/schema.ts`) **must be kept in sync manually** — stick to common SQL types.

**Route handlers** follow this pattern (see `server/routers/site/createSite.ts`):
- Zod schemas: always `z.strictObject()`, not `z.object()`
- Never throw — always `return next(createHttpError(...))`
- All responses: `response<T>(res, { data, success, error, message, status })`
- Register in OpenAPI via `registry.registerPath()`
- Export inferred types (shared with frontend): `export type CreateSiteBody = z.infer<typeof bodySchema>`

**WebSocket handlers:** Message types use `/`-delimited paths (e.g., `newt/dns/authority/config`). Register in `server/routers/ws/messageHandlers.ts` as `Record<string, MessageHandler>`. Handlers receive `HandlerContext` with `sendToClient()` and `broadcastToAllExcept()`.

**Frontend:** shadcn/ui + Tailwind, `next-intl` for i18n (strings in `messages/en-US.json`), TanStack Query with uppercase keys (`["ORG", orgId, "SITES"]`), API calls via `createApiClient(useEnvContext())` — response data at `res.data.data.xxx`.

**Linting:** ESLint flat config — only `semi: "error"` and `prefer-const: "warn"`. CI runs `npx eslint .`.

**CI test** = `npx tsc --noEmit` (type-check) + start app + curl smoke test. No unit test runner.

### Newt & OLM (Go)

**Build:** `CGO_ENABLED=0` static binaries. `make local` for dev, `make go-build-release` for all platforms.

**WebSocket:** Both use `websocket.WSMessage { Type string, Data interface{} }`. Register handlers: `client.RegisterHandler("newt/wg/connect", func(msg WSMessage) {...})`. Data extraction requires double JSON pass: `json.Marshal(msg.Data)` → `json.Unmarshal` into typed struct.

**Testing conventions:**
- stdlib only (no testify) — `t.Fatalf`/`t.Errorf` with manual comparisons
- Table-driven tests with `t.Run(tt.name, ...)`
- Golden file pattern in `internal/telemetry/testdata/`
- Real sockets/`httptest.NewServer` instead of mocks
- CI only verifies compilation (`make` targets), not `go test`

**DNS Authority structs** (passed over WS from Pangolin to Newt):
```go
type DNSAuthorityConfig struct {
    Domain        string               `json:"domain"`
    TTL           uint32               `json:"ttl"`
    RoutingPolicy string               `json:"routingPolicy"` // "failover", "roundrobin", "priority"
    Targets       []DNSAuthorityTarget `json:"targets"`
}
```

## Testing Stack (`testing/`)

### Quick start
```bash
cd testing/
sudo modprobe wireguard          # required by Gerbil
docker compose down -v && docker compose up -d
bash scripts/bootstrap.sh        # idempotent — creates admin, org, sites, resources
./test-stack.sh test              # runs E2E tests inside test-client container
```

### Network layout
| Container | IP | Host ports | Role |
|---|---|---|---|
| `test-pangolin` | `.3` | `3000`/`3001`/`3002` | Control plane (OSS+PG) |
| `test-gerbil` | `.5` | `51820/udp` | WireGuard relay |
| `test-newt` | `.10` | `5353→53`, `8080`, `8443` | Site agent 1 |
| `test-newt-secondary` | `.11` | `5354→53`, `8089`, `8449` | Site agent 2 |
| `test-backend` / `-secondary` | `.20`/`.21` | — | nginx targets |
| `test-client` | `.100` | — | Test runner (curl/dig/jq) |

### Hot-reload mounts (no rebuild needed)
`server/routers`, `server/lib`, `server/private`, `src/` are bind-mounted read-only into Pangolin. Changes to `server/db/`, `server/setup/`, or `server/index.ts` require `docker compose build pangolin`.

### Build-test Pangolin inside container
```bash
docker exec test-pangolin rm -rf .next && docker exec -e NODE_ENV=production test-pangolin npx next build
```

### Stack commands (`./test-stack.sh`)
`build` | `start` | `stop` | `clean` (removes volumes) | `test` | `shell` (exec into test-client) | `dns [domain]` | `status`

### Bootstrap provisions (`scripts/bootstrap.sh`)
Admin `admin@test.dev` / `TestAdmin123!`, org `test-org`, 2 sites with DNS Authority, resource `app.test.dev` with failover targets at backends `.20`/`.21`.

### Dependency chain
```
postgres ← pangolin ← gerbil ← [newt, newt-secondary]
                                [newt, newt-secondary, backend*] ← test-client
```

## Cross-Component Patterns

**WebSocket envelope:** `{ "type": "newt/dns/authority/config", "data": {...}, "configVersion": 5 }` — `configVersion` tracks state across reconnects.

**Key message flows:**
1. Newt sends `newt/wg/register` → Pangolin allocates subnet → sends `newt/wg/connect` back
2. Pangolin pushes `newt/dns/authority/config` with zone configs → Newt responds `newt/dns/status`
3. Pangolin pushes `newt/healthcheck/add` → Newt runs checks → responds `newt/healthcheck/status`
4. OLM sends `olm/wg/register` → Pangolin sends `olm/wg/connect` + peer configs

**Adding a new WS message type:**
1. Pangolin: add handler function in `server/routers/{newt,olm}/`, export from module `index.ts`, register in `server/routers/ws/messageHandlers.ts`
2. Newt/OLM: call `client.RegisterHandler("newt/new/topic", handlerFunc)` in `main.go`

## Production Deployment (DNS Authority)

**Pangolin:** swap Docker image to fork tag, `docker compose pull && up -d pangolin`.

**Newt:** binary swap via `scripts/get-newt.sh` (auto-detects OS/arch). Port 53 conflict with `systemd-resolved` — either disable resolved or use `--dns-bind` flag.

**DNS delegation:** requires NS + glue A records at registrar pointing to Newt public IPs. Domain-level DNS Authority auto-covers all wildcard resources; per-resource DNS Authority needs explicit NS delegation per subdomain.
