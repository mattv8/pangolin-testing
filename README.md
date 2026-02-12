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
curl -fsSL https://raw.githubusercontent.com/mattv8/pangolin-testing/main/scripts/get-newt.sh | GITHUB_TOKEN=<PAT> bash
sudo newt --version && sudo systemctl restart newt
sudo journalctl -u newt -f

# Rollback:
sudo cp /usr/local/bin/newt.official /usr/local/bin/newt && sudo systemctl restart newt
```

### OLM (binary — no DNS Authority, optional)

Only if testing OLM-specific changes. DNS Authority runs on Newt, not OLM.

```bash
sudo cp /usr/local/bin/olm /usr/local/bin/olm.official
curl -fsSL https://raw.githubusercontent.com/mattv8/pangolin-testing/main/scripts/get-olm.sh | GITHUB_TOKEN=<PAT> bash
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

Per-resource authoritative DNS via Newt sites. Redundancy = multiple Newt sites with targets for the same resource.

### DNS Records

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
- DNS Authority enabled on both the **site** and the **resource**
- Pangolin UI shows exact records: Resource → Intelligent DNS Routing

### How it works

1. Pangolin pushes zone configs to Newt via WebSocket
2. Newt binds :53, serves A/NS/SOA responses
3. A-records selected by routing policy (failover / round-robin / all-healthy) + health status
4. NS/SOA reference `ns1.{resource.fullDomain}`

### Wildcard domains vs DNS Authority

| | Wildcard | DNS Authority |
|---|---|---|
| Scope | All resources on domain | Per-resource |
| Records | `*.example.com` A → server IP | NS + glue A per subdomain |
| Routing | Static (reverse proxy) | Dynamic (health-based DNS) |
| Setup | Org → Domains | Resource → Intelligent DNS Routing |

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
