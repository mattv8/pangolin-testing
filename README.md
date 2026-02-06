# DNS Authority Feature — Testing & Deployment

End-to-end testing, build tooling, and staging deployment for the Pangolin DNS Authority, Auth Proxy, and OLM Redundant NS features.

This directory is designed to be committed to a standalone repo (or kept alongside the main repos). It contains:

- **Local test stack** — Docker Compose environment simulating the full Pangolin architecture
- **Deploy script** — Build images, cross-compile binaries, push to Harbor & GitHub, deploy to staging
- **Install scripts** — `get-newt.sh` / `get-olm.sh` for installing fork binaries (same pattern as upstream)
- **CI workflow** — GitHub Actions workflow for automated builds and releases

## Quick Reference

```bash
# ── Local test stack ──
./test-stack.sh build && ./test-stack.sh start    # Build & start
./test-stack.sh test                               # Run E2E tests
./test-stack.sh status                             # Health check
./test-stack.sh logs newt                          # Tail logs

# ── Build & deploy ──
./scripts/deploy.sh status                         # Show repo/image state
./scripts/deploy.sh compile                        # Cross-compile Go binaries
./scripts/deploy.sh build                          # Build Docker images
./scripts/deploy.sh push                           # Push images to Harbor
./scripts/deploy.sh release                        # Create GitHub releases
./scripts/deploy.sh deploy-staging                 # Deploy to proxy.visnovsky.us
./scripts/deploy.sh all                            # Full pipeline

# ── Git workflow ──
./scripts/deploy.sh push-git                       # Push all repos to origin
./scripts/deploy.sh sync-upstream                  # Rebase all repos on upstream
```

---

## 1. Forked Repos & Git Workflow

All three components are forked from `fosrl/*` to `mattv8/*`:

| Component | Fork (origin) | Upstream |
|-----------|---------------|----------|
| Pangolin | `mattv8/pangolin` | `fosrl/pangolin` |
| Newt | `mattv8/newt` | `fosrl/newt` |
| OLM | `mattv8/olm` | `fosrl/olm` |

### Push changes to your fork

```bash
# Push all three repos at once
./scripts/deploy.sh push-git

# Or push individually
cd ../pangolin && git push origin main
cd ../newt && git push origin main
cd ../olm && git push origin main
```

### Sync with upstream

```bash
# Fetch upstream and rebase all repos
./scripts/deploy.sh sync-upstream

# Then push the rebased branches
./scripts/deploy.sh push-git
```

If there are rebase conflicts, the script aborts the rebase and tells you which repo needs manual resolution.

---

## 2. Building & Compiling

### Cross-compile Go binaries (Newt & OLM)

```bash
./scripts/deploy.sh compile
```

This builds binaries for linux/amd64, linux/arm64, linux/arm32, linux/arm32v6, darwin/amd64, and darwin/arm64 into `testing/bin/`. Output:

```
bin/
├── newt_linux_amd64
├── newt_linux_arm64
├── newt_linux_arm32
├── newt_linux_arm32v6
├── newt_darwin_amd64
├── newt_darwin_arm64
├── olm_linux_amd64
├── olm_linux_arm64
├── olm_linux_arm32
├── olm_linux_arm32v6
├── olm_darwin_amd64
└── olm_darwin_arm64
```

### Build Docker images

```bash
# Single-arch (local, fast)
./scripts/deploy.sh build

# Multi-arch (buildx, pushes directly to Harbor)
./scripts/deploy.sh build-multiarch
```

Images are tagged as:
- `hub.docker.visnovsky.us/library/pangolin:dns-authority-dev`
- `hub.docker.visnovsky.us/library/newt:dns-authority-dev`
- `hub.docker.visnovsky.us/library/olm:dns-authority-dev`

Override the tag: `TAG=v0.2.0 ./scripts/deploy.sh build`

---

## 3. Pushing to Harbor

Harbor is at `hub.docker.visnovsky.us` (project: `library`).

```bash
# Login first (one-time)
docker login hub.docker.visnovsky.us

# Push all images
./scripts/deploy.sh push

# Or push individually
docker push hub.docker.visnovsky.us/library/pangolin:dns-authority-dev
```

For multi-arch builds, use `build-multiarch` which pushes automatically via `--push`.

---

## 4. GitHub Releases & Install Scripts

### Create releases

After compiling, create GitHub pre-releases with the binaries attached:

```bash
./scripts/deploy.sh compile
./scripts/deploy.sh release
```

This creates a consolidated release on **`mattv8/pangolin-testing`** with both Newt and OLM binaries attached. This allows the install scripts to pull from a single reliable source during development.

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

---

## 5. CI / GitHub Actions

The workflow at `.github/workflows/build-release.yml` automates:

1. **Cross-compile** Newt & OLM for all platforms
2. **Create GitHub releases** with binaries attached
3. **Optionally build & push Docker images** to Harbor

### Trigger manually

Go to Actions → "Build & Release Newt + OLM" → Run workflow:
- `tag`: Release tag (e.g. `dns-authority-v0.1.0`)
- `push_docker`: Check to also push Docker images to Harbor

### Trigger via tag push

```bash
git tag dns-authority-v0.1.0
git push origin dns-authority-v0.1.0
```

### Required GitHub secrets

Set these in the **`mattv8/pangolin-testing`** repository's Settings → Secrets → Actions:

| Secret | Description |
|--------|-------------|
| `HARBOR_USERNAME` | Harbor registry username (e.g. `harbor`) |
| `HARBOR_PASSWORD` | Harbor registry password |
| `COSIGN_PRIVATE_KEY` | PEM-encoded private key for image signing |
| `COSIGN_PASSWORD` | Password for the cosign private key |

---

## 6. Security & Cryptography

This feature implements a robust **Hybrid Authentication** model to balance security and performance at the edge.

### RSA Identity Keypair

Pangolin now automatically generates an **RSA 2048-bit Identity Keypair** on first boot.
- **Private Key**: Stored in `config/auth/jwt_private.pem` (protected with `0o600` permissions). Used to sign JWTs for user sessions.
- **Public Key**: Stored in `config/auth/jwt_public.pem`. This PEM-encoded key is sent to Newt instances via the Auth Proxy configuration message over WebSocket.

### Hybrid Validation Flow

When a user accesses a protected resource through Newt:
1. **Local JWT Check**: Newt attempts to verify the user's `p_session` cookie locally using the RSA Public Key. If valid, the request is proxied immediately (sub-millisecond latency).
2. **Session API Fallback**: If local verification fails (e.g., the token is an older opaque session string or the JWT is malformed), Newt falls back to calling Pangolin's `/api/v1/auth/session/validate` endpoint.
3. **Strict Enforcement**: If both checks fail, the user is redirected to the Pangolin login page. This ensures backward compatibility with existing sessions while enabling zero-callback validation for newer JWT-based sessions.

### Container Signing (Sigstore/Cosign)

All Docker images pushed via `deploy.sh` or CI are signed using **Cosign**.
- Annotations include the build date, commit SHA, and repository URL.
- Verification: `cosign verify --key cosign.pub hub.docker.visnovsky.us/library/pangolin:dns-authority-dev`

---

## 8. Deploy to Staging

The staging environment is on `proxy.visnovsky.us` (Proxy DCA) running the production-like stack (Pangolin + Traefik + CrowdSec + Gerbil).

```bash
./scripts/deploy.sh deploy-staging
```

This SSHs into the staging server and:
1. Pulls the new Pangolin image from Harbor
2. Updates `docker-compose.yml` with the new image reference
3. Restarts the Pangolin container
4. Waits for the health check to pass

### Manual staging deploy

```bash
ssh root@proxy.visnovsky.us
cd /root
docker pull hub.docker.visnovsky.us/library/pangolin:dns-authority-dev
# Edit docker-compose.yml to update the pangolin image
docker compose up -d pangolin
```

### Deploying Newt/OLM to remote sites

Newt and OLM are installed as binaries on remote machines (not Docker on the proxy). Use the install scripts:

```bash
# On the target machine:
curl -fsSL https://raw.githubusercontent.com/mattv8/pangolin-testing/main/scripts/get-newt.sh | bash
newt --id <ID> --secret <SECRET> --endpoint https://proxy.visnovsky.us
```

---

## 9. Local Test Stack

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

### Hot-Reload

Source directories are bind-mounted for live editing:

| Host Path | Container Path | Purpose |
|-----------|---------------|---------|
| `../pangolin/server/routers/` | `/app/server/routers/` | API route handlers |
| `../pangolin/server/lib/` | `/app/server/lib/` | Server libraries |
| `../pangolin/server/private/` | `/app/server/private/` | Private/internal routes |
| `../pangolin/src/` | `/app/src/` | Next.js frontend |

> DB schema changes (`server/db/`) require a full rebuild: `docker compose build pangolin --no-cache`

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

---

## 10. Environment Variables

All configurable via env vars when calling `deploy.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `HARBOR_URL` | `hub.docker.visnovsky.us` | Harbor registry URL |
| `HARBOR_PROJECT` | `library` | Harbor project name |
| `GITHUB_USER` | `mattv8` | GitHub username (for releases) |
| `TAG` | `dns-authority-dev` | Docker image / release tag |
| `PLATFORMS` | `linux/amd64,linux/arm64` | Buildx target platforms |

---

## 11. Key Implementation Files

### Pangolin (TypeScript/Next.js)

| File | Purpose |
|------|---------|
| `server/routers/dns/dnsAuthority.ts` | DNS authority config builder |
| `server/routers/site/updateSite.ts` | Site update API with DNS validation |
| `server/routers/newt/getNewtToken.ts` | Auto-detects site publicIp from Newt |
| `server/lib/serverIpService.ts` | Pangolin's own public IP detection |
| `server/db/*/schema/schema.ts` | Schema: sites.publicIp, dnsAuthorityEnabled |
| `src/app/[orgId]/settings/sites/[niceId]/general/page.tsx` | DNS Authority UI toggle |

### Newt (Go)

| File | Purpose |
|------|---------|
| `dns/authority.go` | Authoritative DNS server (miekg/dns) |
| `main.go` | WebSocket handler for DNS config |

### OLM (Go)

| File | Purpose |
|------|---------|
| `dns/authority.go` | Authoritative DNS server |
| `olm/dns_authority.go` | WebSocket config handler |

---

## 10. Troubleshooting

### Pangolin won't start — migration error
```bash
docker compose down -v    # Clear volumes (destroys DB)
docker compose up -d
```

### Pangolin won't start after schema changes
```bash
docker compose build pangolin --no-cache
docker compose down -v && docker compose up -d
```

### Port 53 conflict on host
DNS is mapped to host port 5353. Use `dig @localhost -p 5353`.

### Harbor push fails — unauthorized
```bash
docker login hub.docker.visnovsky.us
# Username: admin
```

### `gh` CLI not authenticated
```bash
gh auth login
```

### Buildx builder not available
```bash
docker buildx create --name pangolin-builder --use
docker buildx inspect --bootstrap
```

### Deploy script can't SSH to staging
Ensure your SSH key is added to `root@proxy.visnovsky.us`:
```bash
ssh-copy-id root@proxy.visnovsky.us
```

### Checking container health
```bash
docker compose ps                          # Status overview
docker logs test-pangolin --tail 50        # Pangolin logs
docker logs test-newt --tail 50            # Newt logs
docker exec test-client dig @172.28.0.10 app.test.local A  # DNS test
curl -s http://localhost:3001/api/v1/health # API check
```
