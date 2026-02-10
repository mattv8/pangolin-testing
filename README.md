# DNS Authority Feature — Testing & Deployment

End-to-end testing, build tooling, and staging deployment for the Pangolin DNS Authority, Auth Proxy, and OLM Redundant NS features.

This directory is designed to be committed to a standalone repo (or kept alongside the main repos). It contains:

- **Local test stack** — Docker Compose environment simulating the full Pangolin architecture
- **Deploy script** — Build images, cross-compile binaries, push to Harbor & GitHub, deploy to staging
- **Install scripts** — `get-newt.sh` / `get-olm.sh` for installing fork binaries (same pattern as upstream)
- **CI workflow** — GitHub Actions workflow for automated builds and releases

## 1. Quick Start: Testing Fork Binaries in Production

### Testing with Docker Images

```bash
# Update docker-compose.yml image references as needed:
# Testing: hub.docker.visnovsky.us/library/olm:dns-authority-dev
# Official: fosrl/olm:latest
```

### Install & Test OLM (Backup & Replace Method)

```bash
# 1. Install official Pangolin OLM (if not already installed)
curl -fsSL https://static.pangolin.net/get-olm.sh | bash

# 2. Backup the official version
sudo cp /usr/local/bin/olm /usr/local/bin/olm.official

# 3. Install testing fork (overwrites /usr/local/bin/olm)
curl -fsSL https://raw.githubusercontent.com/mattv8/pangolin-testing/main/scripts/get-olm.sh | bash

# 4. Verify version and test
sudo olm --version
sudo systemctl restart olm  # or however you run olm

# 5. Monitor for issues
sudo journalctl -u olm -f  # if running as systemd service
# OR
sudo olm --id <OLM_ID> --secret <SECRET> --endpoint <ENDPOINT>  # if running manually
```

### Rollback to Official OLM

```bash
# Restore official version if there are any issues
sudo cp /usr/local/bin/olm.official /usr/local/bin/olm
sudo systemctl restart olm
```

### Install & Test Newt (Same Approach)

```bash
# Backup & install testing version
sudo cp /usr/local/bin/newt /usr/local/bin/newt.official
curl -fsSL https://raw.githubusercontent.com/mattv8/pangolin-testing/main/scripts/get-newt.sh | bash

# Rollback if needed
sudo cp /usr/local/bin/newt.official /usr/local/bin/newt
sudo systemctl restart newt
```

> **Note:** Newt requires `sudo` to bind to privileged ports (53, 80, 443) for DNS Authority and Auth Proxy features.

### Install from GitHub (like upstream)

The fork install scripts work exactly like Pangolin's existing pattern — `curl | bash`:

```bash
# Install Newt (DNS Authority fork)
curl -fsSL https://raw.githubusercontent.com/mattv8/pangolin-testing/main/scripts/get-newt.sh | bash

# Install OLM (DNS Authority fork)
curl -fsSL https://raw.githubusercontent.com/mattv8/pangolin-testing/main/scripts/get-olm.sh | bash
```

The scripts auto-detect OS/arch and download the correct binary from the latest GitHub release.

**To use these install scripts**, the testing repo must be pushed to GitHub as `mattv8/pangolin-testing` (public). The scripts pull binary releases from this same repo by default.

> **Note:** The Pangolin UI is intentionally not modified — the install scripts are designed to be contributed back upstream. When contributing, the default `REPO` in the scripts should be updated back to `fosrl/newt` or `fosrl/olm`.

The install scripts support overriding the repo via environment variable:

```bash
# Use upstream instead of fork
NEWT_REPO=fosrl/newt curl -fsSL .../get-newt.sh | bash
OLM_REPO=fosrl/olm  curl -fsSL .../get-olm.sh | bash
```

### Run command (after install)

Since Newt now acts as an Edge Ingress (binding to ports 53/80/443), it requires root privileges:

```bash
# Same as what the Pangolin UI shows (added sudo):
sudo newt --id <NEWT_ID> --secret <SECRET> --endpoint https://proxy.visnovsky.us

# OLM (typically installed via the Pangolin UI dialog)
olm --id <OLM_ID> --secret <SECRET> --endpoint https://proxy.visnovsky.us
```

## 2. DNS Authority Setup (Production)

The DNS Authority feature lets Newt/OLM sites act as authoritative DNS servers for individual resources, enabling health-based routing. This is separate from the basic wildcard domain setup.

### Required DNS Records

For each resource with DNS Authority enabled (e.g., `app.example.com`), add these records at your registrar:

```
app.example.com      NS  ns1.app.example.com
ns1.app.example.com  A   [Newt/Site 1 Public IP]
```

For redundancy, add a second NS pointing to your OLM site:

```
app.example.com      NS  ns2.app.example.com
ns2.app.example.com  A   [OLM/Site 2 Public IP]
```

OLM receives the same zone configs as Newt via WebSocket and serves identical authoritative responses on port 53. Adding `ns2` ensures DNS resolution still works if Site 1 goes down. The authority server advertises all healthy targets as `ns1`, `ns2`, etc. in NS responses and includes glue A-records in the Additional section.

These must be **explicit records** — don't rely on a `*.example.com` wildcard to resolve the nameserver hostnames. NS delegation requires glue records that the parent zone serves as additional section data before your authority server is reachable.

### Other Requirements

- **Port 53 (UDP/TCP)** open on site firewalls
- **Public IP configured** on each site in Pangolin
- **DNS Authority enabled** on both the **site** and the **resource** in Pangolin
- The Pangolin UI shows the exact records needed under Resource → Intelligent DNS Routing

### How It Works

1. Pangolin pushes zone configs to Newt (and OLM for local/VPN redundancy) via WebSocket
2. Newt/OLM bind port 53 and serve authoritative A, NS, and SOA responses
3. A-record responses are selected based on routing policy (failover, round-robin, or all-healthy) and target health status
4. NS/SOA responses reference `ns1.{resource.fullDomain}`

### Not the Same as Wildcard Domains

| | Wildcard Domain | DNS Authority |
|---|---|---|
| **Scope** | All resources on a domain | Per-resource |
| **DNS records** | `*.example.com` + `example.com` A-records → server IP | NS + glue A-record per resource subdomain |
| **Routing** | Static — Pangolin handles internally via reverse proxy | Dynamic — sites respond to DNS queries based on health |
| **Setup in Pangolin** | Org Settings → Domains | Resource Settings → Intelligent DNS Routing |

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
│                      │     OLM      │  │ Test Client  │     │  Backend 2   │    │
│                      │ (Redundant   │  │ 172.28.0.100 │     │  172.28.0.21 │    │
│                      │   NS/Auth)   │  │ DNS→Newt     │     │    :80       │    │
│                      └──────────────┘  └──────────────┘     └──────────────┘    │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Start the test stack

```bash
cd testing/

# Fresh start (clears DB)
docker compose down -v && docker compose up -d

# Watch Pangolin compile (first start takes ~60s)
docker logs test-pangolin -f

# Check all services
docker compose ps
```

**Host port mappings:**

| Service | Host Port | URL / Command |
|---------|-----------|---------------|
| Pangolin UI | 3000 | http://localhost:3000 |
| Pangolin API | 3001 | http://localhost:3001/api/v1/health |
| DNS Authority | 5353 | `dig @localhost -p 5353 app.test.local A` |

### Run tests

```bash
./test-stack.sh test
# or directly:
docker compose exec test-client bash /scripts/run-tests.sh
```

### Test Scenarios

```bash
# DNS Authority resolution
dig @localhost -p 5353 app.test.local A

# From inside test-client
docker exec test-client dig @172.28.0.10 app.test.local A

# Auth Proxy redirect (unauthenticated → 302)
curl -sI http://localhost:8080/ | grep Location

# Health-based failover
docker compose stop backend
dig @localhost -p 5353 app.test.local A    # Should return secondary IP
docker compose start backend
```
