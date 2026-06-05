# DNS Authority — Testing & Deployment

## 1. Deploy Fork to Production

### Pangolin (Docker)

```yaml
# docker-compose.yml — change pangolin image:
image: hub.docker.visnovsky.us/library/pangolin:dns-authority-dev
# revert: image: docker.io/fosrl/pangolin:latest
```

```bash
docker compose pull pangolin && docker compose up -d pangolin
```

### Newt (binary — runs DNS Authority)

```bash
sudo cp /usr/local/bin/newt /usr/local/bin/newt.official
curl -fsSL https://raw.githubusercontent.com/mattv8/pangolin-testing/main/scripts/get-newt.sh | bash
sudo newt --version && sudo systemctl restart newt
sudo journalctl -u newt -f

# Rollback:
sudo cp /usr/local/bin/newt.official /usr/local/bin/newt && sudo systemctl restart newt
```

> **Note on Port 53 conflict:** If Newt fails to start because port 53 is in use by `systemd-resolved`, you can either disable resolved: `sudo systemctl disable --now systemd-resolved`, or bind Newt to a specific IP using the `--dns-bind` flag in the service file.

### OLM (binary — no DNS Authority, optional)

Only if testing OLM-specific changes. DNS Authority runs on Newt, not OLM.

```bash
sudo cp /usr/local/bin/olm /usr/local/bin/olm.official
curl -fsSL https://raw.githubusercontent.com/mattv8/pangolin-testing/main/scripts/get-olm.sh | bash
sudo olm --version && sudo systemctl restart olm

# Rollback:
sudo cp /usr/local/bin/olm.official /usr/local/bin/olm && sudo systemctl restart olm
```

### Run commands

```bash
# Newt (needs sudo for ports 53/80/443)
sudo newt --id <NEWT_ID> --secret <SECRET> --endpoint https://proxy.visnovsky.us

# OLM (unprivileged)
olm --id <OLM_ID> --secret <SECRET> --endpoint https://proxy.visnovsky.us
```

### Install script overrides

Scripts auto-detect OS/arch.

```bash
# Override repo (e.g. use upstream):
NEWT_REPO=fosrl/newt curl -fsSL .../get-newt.sh | bash
OLM_REPO=fosrl/olm  curl -fsSL .../get-olm.sh | bash
```

> When contributing back upstream, change default `REPO` in scripts to `fosrl/newt` / `fosrl/olm`.

## 2. DNS Authority Setup (Production)

### Domain-Level DNS Authority (Wildcard Failover)

When a site enables DNS Authority, **all wildcard domains** with resources on that site automatically get wildcard zone configs pushed to Newt. This provides domain-wide failover using your existing wildcard certs.

#### DNS Records (at your registrar)

```
docker.visnovsky.us      NS  ns1.docker.visnovsky.us
docker.visnovsky.us      NS  ns2.docker.visnovsky.us
ns1.docker.visnovsky.us  A   68.142.136.236   (DCA)
ns2.docker.visnovsky.us  A   136.38.238.75    (DCB)
```

Any query for `*.docker.visnovsky.us` now goes to your Newt instances, which return the healthy site IP based on target health checks.

#### How it works

1. User enables DNS Authority on a site + sets public IP
2. Pangolin automatically finds all wildcard domains with resources on that site
3. For each domain, builds a `*.domain` zone with all DNS Authority sites as targets
4. Pushes zone config to every DNS Authority Newt via WebSocket
5. On DNS query, Newt returns the healthy site's IP per routing policy
6. Health check updates automatically refresh the zone targets

#### Setup steps

1. **Sites**: Edit each site → enable DNS Authority + set public IP
2. **DNS**: Add NS + glue A records at your registrar (above)
3. **Done** — wildcard domains are opted-in automatically

No per-resource DNS Authority toggle needed for domain-level failover.

### Per-Resource DNS Authority (Optional)

For individual subdomain routing with per-resource policies (different TTL, routing policy per resource).

#### DNS Records

```
app.example.com      NS  ns1.app.example.com
ns1.app.example.com  A   [Newt Site 1 IP]

# Redundancy (second Newt site):
app.example.com      NS  ns2.app.example.com
ns2.app.example.com  A   [Newt Site 2 IP]
```

Must be explicit records — wildcard won't work for NS delegation (needs glue records).

### Requirements

- Port 53 (UDP/TCP) open on site firewalls
- Public IP set on each site in Pangolin
- DNS Authority enabled on the **site**
- For domain-level: wildcard domain configured in Org → Domains
- For per-resource: DNS Authority also enabled on the **resource**

### How it works

1. Pangolin pushes zone configs to Newt via WebSocket (on site toggle, Newt connect, and health updates)
2. Newt binds :53, serves A/NS/SOA responses
3. A-records selected by routing policy (failover / round-robin / all-healthy) + health status
4. NS/SOA reference `ns1.{zone domain}`

### Wildcard domains vs DNS Authority (comparison)

| | Wildcard (static) | Domain-Level DNS Authority | Per-Resource DNS Authority |
|---|---|---|---|
| Scope | All resources on domain | All resources on domain | Single resource |
| Records | `*.example.com` A → server IP | NS + glue A for parent zone | NS + glue A per subdomain |
| Routing | Static (single IP) | Dynamic (health-based DNS) | Dynamic (health-based DNS) |
| Failover | None | Automatic | Automatic |
| Setup | Org → Domains | Site → DNS Authority toggle | Resource → DNS Authority toggle |
| Cert | Wildcard cert works | Wildcard cert works | Individual cert needed |

## 3. Local Test Stack

### Prerequisites

- Docker & Docker Compose
- WireGuard kernel module loaded on the host (required by Gerbil exit node):
  ```bash
  sudo modprobe wireguard    # one-time per boot
  ```

### Architecture

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                              Docker Network (172.28.0.0/16)                          │
│                                                                                      │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                            │
│  │  PostgreSQL  │    │   Pangolin   │    │   Gerbil     │                            │
│  │  172.28.0.2  │◄──►│  172.28.0.3  │◄──►│  172.28.0.5  │                            │
│  │    :5432     │    │ :3000-3002   │    │ :51820/udp   │                            │
│  └──────────────┘    └──────┬───────┘    │ :3004 (HTTP) │                            │
│                             │ WS         └──────┬───────┘                            │
│                             │                   │ WireGuard                          │
│                             ▼                   ▼                                    │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐        │
│  │   Newt 1     │    │   Newt 2     │    │  Backend 1   │    │  Backend 2   │        │
│  │  172.28.0.10 │    │  172.28.0.11 │    │  172.28.0.20 │    │  172.28.0.21 │        │
│  │ :53 :8080    │    │ :53 :8080    │    │    :80       │    │    :80       │        │
│  │  :8443       │    │  :8080 :8443 │    └──────────────┘    └──────────────┘        │
│  └──────────────┘    └──────────────┘                                                │
│         ▲                   ▲                                                        │
│         │ DNS               │ DNS                                                    │
│         └─────────┬─────────┘                                                        │
│            ┌──────┴───────┐                                                          │
│            │ Test Client  │                                                          │
│            │ 172.28.0.100 │                                                          │
│            └──────────────┘                                                          │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

### Usage

```bash
cd testing/

# Ensure WireGuard kernel module is loaded
sudo modprobe wireguard

# Start stack (first start builds images, ~60-90s)
docker compose down -v && docker compose up -d
docker compose ps                        # all services should be healthy

# Bootstrap test data (creates admin, org, sites, resource, targets)
bash scripts/bootstrap.sh

# Or use the test harness, which bootstraps automatically on start/test
./test-stack.sh start
./test-stack.sh test
```

| Service | IP | Host Port | Access |
|---------|-----|-----------|--------|
| Pangolin UI | 172.28.0.3 | 3000 | http://localhost:3000 |
| Pangolin API | 172.28.0.3 | 3001 | http://localhost:3001/api/v1/ |
| Pangolin WS | 172.28.0.3 | 3002 | ws://localhost:3002 |
| Gerbil (exit node) | 172.28.0.5 | 51820/udp | WireGuard tunnel endpoint |
| Newt 1 DNS | 172.28.0.10 | 5353 | `dig @localhost -p 5353 app.test.dev A` |
| Newt 2 DNS | 172.28.0.11 | 5354 | `dig @localhost -p 5354 app.test.dev A` |
| Newt 1 Auth Proxy | 172.28.0.10 | 18080/18443 | http://localhost:18080 |
| Newt 2 Auth Proxy | 172.28.0.11 | 8089/8449 | http://localhost:8089 |
| Backend 1 | 172.28.0.20 | — | Internal only |
| Backend 2 | 172.28.0.21 | — | Internal only |
| Test Client | 172.28.0.100 | — | `docker exec -it test-client bash` |

### Connection Flow

1. **Gerbil** starts → registers with Pangolin (`POST /api/v1/gerbil/get-config`) → creates WireGuard interface `wg0`
2. **Newt** connects via WebSocket → registers in backwards-compatible mode → Pangolin sends exit node list
3. **Newt** pings Gerbil to measure latency → re-registers with ping results
4. **Pangolin** allocates WireGuard subnet → adds Newt as peer on Gerbil (`POST http://gerbil:3004/peer`)
5. **Pangolin** sends `newt/wg/connect` → Newt establishes userspace WireGuard tunnel through Gerbil
6. **Gerbil** reports bandwidth → Pangolin marks site online
7. **Pangolin** pushes DNS Authority zone configs to Newt via WebSocket

### Tests

```bash
# DNS Authority verification
dig @localhost -p 5353 app.test.dev A +short      # → 172.28.0.10
dig @localhost -p 5354 app.test.dev A +short      # → 172.28.0.10
dig @localhost -p 5353 anything.test.dev A +short  # → 172.28.0.10 (wildcard)

# Auth Proxy
curl -sI http://localhost:18080/ | grep Location   # → 302 redirect

# Failover
docker compose stop backend
dig @localhost -p 5353 app.test.dev A +short       # → secondary IP
docker compose start backend

# Check site status in DB
docker exec test-postgres psql -U pangolin -d pangolin \
  -c 'SELECT "siteId", "online", "subnet", "endpoint" FROM sites;'

# Check WireGuard peers on Gerbil
docker logs test-gerbil 2>&1 | grep -i peer
```
