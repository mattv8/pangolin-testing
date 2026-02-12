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
export GITHUB_TOKEN=<PAT>
curl -fsSL -H "Authorization: token $GITHUB_TOKEN" -H "Accept: application/vnd.github.v3.raw" \
  "https://api.github.com/repos/mattv8/pangolin-testing/contents/scripts/get-newt.sh?ref=main" | bash
sudo newt --version && sudo systemctl restart newt
sudo journalctl -u newt -f

# Rollback:
sudo cp /usr/local/bin/newt.official /usr/local/bin/newt && sudo systemctl restart newt
```

### OLM (binary — no DNS Authority, optional)

Only if testing OLM-specific changes. DNS Authority runs on Newt, not OLM.

```bash
sudo cp /usr/local/bin/olm /usr/local/bin/olm.official
export GITHUB_TOKEN=<PAT>
curl -fsSL -H "Authorization: token $GITHUB_TOKEN" -H "Accept: application/vnd.github.v3.raw" \
  "https://api.github.com/repos/mattv8/pangolin-testing/contents/scripts/get-olm.sh?ref=main" | bash
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

Scripts auto-detect OS/arch. Repo must be public at `mattv8/pangolin-testing`.

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

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              Docker Network (172.28.0.0/16)                     │
│                                                                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐   │
│  │  PostgreSQL  │    │   Pangolin   │    │     Newt     │    │   Backend    │   │
│  │  172.28.0.2  │◄──►│  172.28.0.3  │◄──►│  172.28.0.10 │◄──►│  172.28.0.20 │   │
│  │    :5432     │    │ :3000-3002   │    │ :53 :8080    │    │    :80       │   │
│  └──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘   │
│                             │ WS              │ DNS Auth             ▲          │
│                             │                 │                      │          │
│                             ▼                 ▼                      │          │
│                      ┌──────────────┐  ┌──────────────┐     ┌────────┴─────┐    │
│                      │   Newt 2     │  │ Test Client  │     │  Backend 2   │    │
│                      │ (Redundant   │  │ 172.28.0.100 │     │  172.28.0.21 │    │
│                      │   NS site)   │  │ DNS→Newt     │     │    :80       │    │
│                      └──────────────┘  └──────────────┘     └──────────────┘    │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Usage

```bash
cd testing/
docker compose down -v && docker compose up -d
docker logs test-pangolin -f          # first start ~60s
docker compose ps
```

| Service | Port | Access |
|---------|------|--------|
| Pangolin UI | 3000 | http://localhost:3000 |
| Pangolin API | 3001 | http://localhost:3001/api/v1/health |
| DNS Authority | 5353 | `dig @localhost -p 5353 app.test.local A` |

### Tests

```bash
./test-stack.sh test

# Manual:
dig @localhost -p 5353 app.test.local A
docker exec test-client dig @172.28.0.10 app.test.local A
curl -sI http://localhost:8080/ | grep Location          # Auth proxy → 302

# Failover:
docker compose stop backend
dig @localhost -p 5353 app.test.local A                  # → secondary IP
docker compose start backend
```
