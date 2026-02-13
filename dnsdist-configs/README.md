# dnsdist + Harbor Multi-Datacenter DNS Routing Setup

NOTE: THIS IS SUPERCEDED BY PANGOLIN DNS AUTHORITY FEATURES

## Overview

This document describes the configuration of dnsdist for intelligent DNS-based routing between two datacenters (DCA and DCB), providing failover and load balancing for Harbor Docker Registry services.

**Key Features:**
- **Internal/External client detection** - Returns internal IPs to VPN/LAN clients, external public IPs to internet clients
- **Health-check based failover** - Automatic failover between DCA and DCB based on HTTP health checks
- **IPv6 (AAAA) handling** - Properly returns NODATA for AAAA queries to avoid browser resolution delays
- **Packet caching** - 10k entry cache with 5-300s TTL for improved performance

## Architecture

```
                    ┌─────────────────────────────────────────────────────────────┐
                    │                      PUBLIC DNS                             │
                    │  docker.visnovsky.us  NS → ns1.docker.visnovsky.us (DCA)    │
                    │                       NS → ns2.docker.visnovsky.us (DCB)    │
                    └─────────────────────────────────────────────────────────────┘
                                    │                           │
                                    ▼                           ▼
                    ┌───────────────────────────┐   ┌───────────────────────────┐
                    │   DCA (68.142.136.236)    │   │   DCB (136.38.238.75)     │
                    │                           │   │                           │
                    │  ┌─────────────────────┐  │   │  ┌─────────────────────┐  │
                    │  │dnsdist (10.10.0.100)│  │   │  │dnsdist (192.168.50.103)│
                    │  │ Port 53 (forwarded) │  │   │  │ Port 53 (forwarded) │  │
                    │  └─────────────────────┘  │   │  └─────────────────────┘  │
                    │           │               │   │           │               │
                    │           ▼               │   │           ▼               │
                    │  ┌─────────────────────┐  │   │  ┌─────────────────────┐  │
                    │  │Pangolin (10.10.0.100)│ │   │  │  Harbor Cache       │  │
                    │  │ - Dockge UI         │  │   │  │  (192.168.50.104)   │  │
                    │  │ - Harbor Web UI     │  │   │  │  Port 80            │  │
                    │  └─────────────────────┘  │   │  └─────────────────────┘  │
                    │           │               │   │           │               │
                    │           ▼               │   │           ▼               │
                    │  ┌─────────────────────┐  │   │           │               │
                    │  │Harbor Master        │  │◄──┼───────────┘               │
                    │  │  (10.10.0.104)      │  │   │  (Proxy Cache from DCA)   │
                    │  │  Port 80            │  │   │                           │
                    │  └─────────────────────┘  │   │                           │
                    └───────────────────────────┘   └───────────────────────────┘
```

## Components

### Servers

| Server | Location | Internal IP | Public IP | Role |
|--------|----------|-------------|-----------|------|
| Proxy DCA | Datacenter A | 10.10.0.100 | 68.142.136.236 | dnsdist, Pangolin reverse proxy |
| Harbor | Datacenter A | 10.10.0.104 | (via DCA) | Primary Harbor registry |
| Tunnel DCB | Datacenter B | 192.168.50.103 | 136.38.238.75 | dnsdist |
| Harbor Cache | Datacenter B | 192.168.50.104 | (via DCB) | Harbor proxy cache |

### DNS Delegation (External DNS)

```dns
; Nameserver hostnames (glue records)
ns1.docker.visnovsky.us.    IN  A      68.142.136.236
ns2.docker.visnovsky.us.    IN  A      136.38.238.75

; Delegate *.docker.visnovsky.us to dnsdist servers
docker.visnovsky.us.        IN  NS     ns1.docker.visnovsky.us.
docker.visnovsky.us.        IN  NS     ns2.docker.visnovsky.us.
```

## dnsdist Configuration

### File Locations

- **DCA**: `/opt/stacks/dnsdist/dnsdist.conf`
- **DCB**: `/opt/stacks/dnsdist/dnsdist.conf`

### Key Configuration Elements

#### 1. Service Definitions

Each dnsdist instance defines services with:
- `local_ip`: The IP of the local Harbor instance
- `remote_ip`: The IP of the remote Harbor instance (for failover)
- `local_networks`: CIDR ranges considered "local" to this datacenter
- `health_check`: HTTP health check configuration

**DCA Configuration:**
```lua
local SERVICES = {
    {
        name = "Harbor Docker Registry",
        domains = {
            "%.docker%.visnovsky%.us%.$",  -- matches *.docker.visnovsky.us
        },
        local_ip = "10.10.0.104",          -- Harbor at DCA (internal)
        remote_ip = "192.168.50.104",      -- Harbor Cache at DCB (internal)
        external_ip_dca = "68.142.136.236", -- DCA public IP for external clients
        external_ip_dcb = "136.38.238.75",  -- DCB public IP for external clients
        health_check = {
            enabled = true,
            url_path = "/api/v2.0/health",
            interval = 30,
            timeout = 10
        },
        local_networks = {"10.10.0.0/16", "100.90.128.0/24", "192.168.50.0/24"}
    }
}
```

**DCB Configuration:**
```lua
local SERVICES = {
    {
        name = "Harbor Docker Registry",
        domains = {
            "%.docker%.visnovsky%.us%.$",
        },
        local_ip = "192.168.50.104",       -- Harbor Cache at DCB (internal)
        remote_ip = "10.10.0.104",         -- Harbor at DCA (internal)
        external_ip_dca = "68.142.136.236", -- DCA public IP for external clients
        external_ip_dcb = "136.38.238.75",  -- DCB public IP for external clients
        health_check = {
            enabled = true,
            url_path = "/api/v2.0/health",
            interval = 30,
            timeout = 10
        },
        local_networks = {"192.168.50.0/24", "10.10.0.0/16", "100.90.128.0/24"}
    }
}
```

#### 2. Static Host Mappings

For hosts that should always route to Pangolin (web UIs), with internal/external IP support:

```lua
local STATIC_HOSTS = {
    ["docker.visnovsky.us."] = {internal = "10.10.0.100", external = "68.142.136.236"},
    ["hub.docker.visnovsky.us."] = {internal = "10.10.0.100", external = "68.142.136.236"},
}

-- Networks considered "internal" (VPN/LAN)
local INTERNAL_NETWORKS = {"10.10.0.0/16", "100.90.128.0/24", "192.168.50.0/24"}
```

The `isInternalClient()` function checks if the requesting client is on an internal network and returns the appropriate IP.

#### 3. Routing Logic

The `routeQuery` function implements:

1. **Static host check first** - exact matches return immediately
2. **Pattern matching** - uses Lua patterns (note: `%.` escapes the dot)
3. **Client location detection** - checks if client IP is in `INTERNAL_NETWORKS`
4. **IPv6 (AAAA) handling** - returns NXDOMAIN immediately to avoid browser delays
5. **Health-based routing**:
   - **Internal client** + local healthy → internal local IP
   - **Internal client** + local unhealthy + remote healthy → internal remote IP
   - **External client** + DCA healthy → DCA external IP (68.142.136.236)
   - **External client** + DCA unhealthy + DCB healthy → DCB external IP (136.38.238.75)
   - Both unhealthy → default to DCA (external) or local (internal)

#### 4. Packet Cache

A packet cache is configured for improved performance:

```lua
pc = newPacketCache(10000, {
    maxTTL = 300,      -- Maximum 5 minutes
    minTTL = 5,        -- Minimum 5 seconds
    temporaryFailureTTL = 10,
    staleTTL = 60,
    dontAge = false
})
getPool(""):setCache(pc)
```

### Lua Pattern Notes

The pattern `%.docker%.visnovsky%.us%.$` means:
- `%.` = literal dot (escaped)
- `%.$` = ends with literal dot (DNS FQDN format)
- This matches `*.docker.visnovsky.us.` but NOT `docker.visnovsky.us.`

To match the bare domain, add it to `STATIC_HOSTS`.

## Harbor Configuration

### Harbor Master (DCA - 10.10.0.104)

- **Config**: `/root/harbor/harbor.yml`
- **Data**: `/data`
- **Hostname**: `hub.docker.visnovsky.us`
- **Port**: 80 (HTTP, behind Pangolin reverse proxy for HTTPS)

### Harbor Cache (DCB - 192.168.50.104)

- **Config**: `/root/harbor/harbor.yml`
- **Data**: `/mnt/harbor-data` (symlinked to `/data`)
- **Hostname**: `hub.docker.visnovsky.us`
- **Port**: 80
- **Admin credentials**: `admin` / `Harbor12345`

#### Setting Up Harbor Cache as Proxy Cache

1. Login to Harbor Cache web UI
2. Go to **Administration → Registries → + New Endpoint**
3. Configure:
   - Provider: Harbor
   - Name: `harbor-master`
   - Endpoint URL: `http://10.10.0.104`
   - Access ID: `admin`
   - Access Secret: (master's password)
4. Create proxy cache project:
   - Go to **Projects → + New Project**
   - Project Name: `library`
   - Enable **Proxy Cache**
   - Select `harbor-master` registry

## Health Checks

dnsdist performs HTTP health checks every 30 seconds:

```lua
function checkHealth(service_name, ip, url_path, timeout)
    local cmd = string.format(
        "curl -s -o /dev/null -w '%%{http_code}' --max-time %d http://%s%s",
        timeout, ip, url_path
    )
    -- Returns true if HTTP 200
end
```

Health status is stored in `health_status` table and used for routing decisions.

## Operational Commands

### Restart dnsdist

```bash
# On Proxy DCA:
cd /opt/stacks/dnsdist && docker compose restart

# On Tunnel DCB:
cd /opt/stacks/dnsdist && docker compose restart
```

### Restart Harbor

```bash
# On Harbor or Harbor Cache:
cd /root/harbor && docker compose restart
```

### Check Harbor Health

```bash
curl http://localhost/api/v2.0/health | jq '.'
```

### Test DNS Resolution

```bash
# From internal network:
dig hub.docker.visnovsky.us @10.10.0.100

# From external (should query public nameservers):
dig hub.docker.visnovsky.us @68.142.136.236
```

### Reset Harbor Admin Password

If you need to reset the admin password:

```bash
# Stop Harbor
cd /root/harbor && docker compose down

# Clear database
rm -rf /data/database/* /data/redis/* /data/secret/*

# Update password in harbor.yml
sed -i 's/^harbor_admin_password:.*/harbor_admin_password: YourNewPassword/' harbor.yml

# Re-prepare and start
./prepare
docker compose up -d
```

## Known Issues & Fixes

### ✅ FIXED: External Client Routing Issue

**Problem**: External clients were receiving internal IPs (10.10.0.x), which are not routable from the internet.

**Solution**: Added `external_ip_dca` and `external_ip_dcb` fields to service definitions, and `isInternalClient()` function to detect client network location. External clients now receive:
- `68.142.136.236` (DCA) - primary
- `136.38.238.75` (DCB) - failover

### ✅ FIXED: Browser 5-Second Delay (ERR_NAME_NOT_RESOLVED)

**Problem**: Browsers would show ERR_NAME_NOT_RESOLVED for ~5 seconds before loading pages.

**Root Cause**: AAAA (IPv6) queries were falling through to upstream DNS, which returned NXDOMAIN. Browsers try IPv6 first and wait for timeout before falling back to IPv4.

**Solution**: AAAA queries for managed domains now immediately return NXDOMAIN from dnsdist, eliminating the upstream lookup delay.

### VPN/Tailscale Networks

The configs include these networks as "internal":
- `10.10.0.0/16` - DCA internal network
- `192.168.50.0/24` - DCB internal network
- `100.90.128.0/24` - Tailscale VPN range

## File Sync

The dnsdist configs are synced via Royal TS to the servers. After editing locally:
1. Save the file
2. Royal TS syncs to the server
3. Restart dnsdist on the respective server

## References

- [dnsdist documentation](https://dnsdist.org/)
- [Harbor documentation](https://goharbor.io/docs/)
- [Harbor Proxy Cache](https://goharbor.io/docs/2.0.0/administration/configure-proxy-cache/)
