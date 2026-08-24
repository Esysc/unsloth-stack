# Unsloth Stack

Run [Unsloth Studio](https://docs.unsloth.ai/basics/getting-started-with-chat) behind a Caddy reverse proxy with **multi-factor authentication (MFA)**, accessible over the internet via a custom domain.

## Architecture

```
Internet
   |
   v
[DNS: your-domain.com] --> your public IP
   |
   v
[Caddy + caddy-security] (Docker, host network mode, port 443/80)
   |
   ├── /auth/*                          → Authentication portal (login + TOTP MFA)
   ├── /api, /v1, /openai, /chat/*      → Unsloth Studio (no auth - API access)
   ├── requests from LAN IPs            → Unsloth Studio (no auth, plain HTTP or HTTPS)
   └── everything else                  → Unsloth Studio (requires MFA login)
```

Caddy handles TLS termination (automatic HTTPS via Let's Encrypt), MFA authentication via the [caddy-security](https://github.com/greenpau/caddy-security) plugin, and proxies requests to Unsloth Studio running on your local machine. API endpoints are accessible without authentication for programmatic access.

## Prerequisites

- **Docker** and **Docker Compose** installed
- A **public domain** with DNS A record pointing to your machine's public IP
- Port **80** and **443** open on your router/firewall

Unsloth Studio is checked on each start and the installer is run so it can install or upgrade the CLI if needed.

## Setup

### 1. Configure environment

```bash
cp .env.example .env
```

Edit `.env` with your values:

| Variable | Description | Default |
|---|---|---|
| `STUDIO_HOST` | Local IP of the machine running Studio | `192.168.x.x` |
| `STUDIO_PORT` | Port Unsloth Studio listens on | `8000` |
| `DOMAIN` | Public domain for reverse proxy | `your-domain.com` |
| `ADMIN_USERNAME` | Initial admin username for MFA portal | `admin` |
| `ADMIN_PASSWORD` | Initial admin password (bcrypt-hashed at boot) | *(required)* |
| `ADMIN_EMAIL` | Initial admin email address | *(required)* |
| `JWT_SECRET` | Secret key for JWT token signing | *(required)* |

> **Security note:** Change `ADMIN_PASSWORD` and `JWT_SECRET` from their defaults before deploying to production.

### 2. Point DNS to your machine

Create an A record for your domain pointing to your public IP address. You can use a service like [No-IP](https://www.noip.com/) or [DuckDNS](https://www.duckdns.org/) if your ISP gives you a dynamic IP.

### 3. Open firewall ports

Ports 80 and 443 must be reachable from the internet. Forward these to your machine in your router settings.

> **Alternative: Cloudflare Tunnel**
> Unsloth Studio can be exposed via [Cloudflare Tunnel](https://developers.com.cloudflare.com/cloudflare-one/connections/connect-networks/) without opening ports. However, the tunnel URL regenerates on every restart, making it impractical for stable remote access. The Caddy + port forwarding approach recommended above provides a persistent URL.

## Usage

```bash
# Start both Caddy and Unsloth Studio in the background
./run.sh start

# Check if services are running
./run.sh status

# View Unsloth Studio logs (live tail)
./run.sh logs

# Restart both services
./run.sh restart

# Stop both services
./run.sh stop
```

## MFA Setup

1. Start the stack with `./run.sh start`
2. Open `https://your-domain.com` in a browser — you will be redirected to the login portal
3. Log in with the `ADMIN_USERNAME` and `ADMIN_PASSWORD` from your `.env`
4. Click **Portal Settings** in the navigation bar
5. Under **Multi-Factor Authentication**, scan the QR code with an authenticator app (Google Authenticator, Authy, etc.)
6. Enter the 6-digit TOTP code to verify and complete enrollment

> **Important:** Complete MFA enrollment immediately after first login. Until enrolled, you will only have single-factor authentication.

## Local Network Access (LAN Bypass)

Clients connecting from trusted private networks skip the login portal and MFA entirely and go straight to Unsloth Studio:

- `192.168.0.0/16`
- `10.0.0.0/8`
- `172.16.0.0/12`
- `127.0.0.0/8`, `::1` (localhost)
- `fc00::/7` (IPv6 unique-local)

Internet clients still get the full password + TOTP MFA flow.

### Plain HTTP for local clients

Trusted LAN clients can use plain `http://` (port 80) — no TLS and no redirect:

```bash
http://your-domain.com        # direct access from the LAN
http://<machine-lan-ip>/      # also works when accessing by IP
https://your-domain.com       # TLS without login, also available
```

Internet clients hitting port 80 are still redirected to `https://` automatically (`auto_https disable_redirects` removes Caddy's built-in redirect so it cannot shadow the LAN check; the explicit `@wan_clients` route handles it instead).

To customize the trusted ranges, edit the `(lan_ranges)` snippet in the `Caddyfile` and restart with `./run.sh restart`.

> **Security note:** Anyone who can reach this machine from a trusted range gets unauthenticated access to the Studio UI. Only trust ranges that are genuinely under your control — for example, clients connecting through a VPN into your LAN will also bypass MFA.

## API Access

API endpoints are accessible without authentication for programmatic access:

```bash
# Example: chat completion via API
curl https://your-domain.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "unsloth/Qwen3-8B", "messages": [{"role": "user", "content": "Hello"}]}'
```

The following paths bypass MFA and are proxied directly to Unsloth Studio:
- `/api/*`
- `/v1/*`
- `/openai/*`
- `/chat/completions`

## How It Works

- **Caddy** runs in a Docker container with `network_mode: host`, giving it direct access to your machine's network. It automatically provisions TLS certificates for your domain via Let's Encrypt.
- **Unsloth Studio** runs as a background process managed by `run.sh`. Process IDs are tracked in `.pids/` and logs are written to `logs/`.

## Systemd Integration

For production environments, you can run the Unsloth Stack components as separate systemd services.

### Unsloth Studio Service

An example `Type=simple` service file is provided at `systemd/unsloth-studio.service.example`.

To use it:

1. Copy the example service file to the systemd directory:
   ```bash
   sudo cp systemd/unsloth-studio.service.example /etc/systemd/system/unsloth-studio.service
   ```

2. Edit `/etc/systemd/system/unsloth-studio.service` to match your environment:
   - Update `WorkingDirectory` to the path of your unsloth-stack directory
   - Update `EnvironmentFile` to point to your `.env` file
   - Update the log file paths in `StandardOutput` and `StandardError`
   - Update `User` and `Group` to the non-root user and group that should run the service

3. Reload systemd and start the service:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable unsloth-studio.service
   sudo systemctl start unsloth-studio.service
   ```

4. Check the service status:
   ```bash
   sudo systemctl status unsloth-studio.service
   ```

### Caddy Proxy Service (Docker Compose)

An example service file for starting the Caddy Docker Compose service is provided at `systemd/caddy-proxy.service.example`.

To use it:

1. Copy the example service file to the systemd directory:
   ```bash
   sudo cp systemd/caddy-proxy.service.example /etc/systemd/system/caddy-proxy.service
   ```

2. Edit `/etc/systemd/system/caddy-proxy.service` to match your environment:
   - Update `WorkingDirectory` to the path of your unsloth-stack directory
   - Update `EnvironmentFile` to point to your `.env` file
   - Update the `ExecStart` and `ExecStop` paths to match the location of your `docker-compose.yml` file
   - Update `User` and `Group` to the non-root user and group that should run the service. **Note:** The user must be a member of the `docker` group to run `docker compose` commands.

3. Reload systemd and start the service:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable caddy-proxy.service
   sudo systemctl start caddy-proxy.service
   ```

4. Check the service status:
   ```bash
   sudo systemctl status caddy-proxy.service
   ```

## Files

| File | Description |
|---|---|
| `run.sh` | Management script (start/stop/restart/status) |
| `docker-compose.yml` | Docker Compose config for Caddy |
| `Caddyfile` | Caddy reverse proxy + MFA configuration |
| `Dockerfile` | Custom Caddy image with caddy-security plugin |
| `entrypoint.sh` | Bootstrap script for admin user creation |
| `.env.example` | Template for environment configuration |
| `.env` | Your local configuration (not committed) |

## Troubleshooting

### Studio won't start

Check the logs:
```bash
./run.sh logs
# or directly:
cat logs/unsloth-studio.log
```

### Caddy isn't reaching Unsloth Studio

Verify Unsloth Studio is listening on the expected address:
```bash
curl http://192.168.x.x:8000
```

Check Caddy logs:
```bash
docker logs caddy-proxy
```

### HTTPS certificate not provisioning

- Ensure DNS A record is correct: `dig your-domain.com`
- Ensure ports 80/443 are open and forwarded to your machine
- Caddy logs will show certificate provisioning status: `docker logs caddy-proxy`

### Process appears dead but PID file exists

Clean up stale PID files:
```bash
rm -f .pids/unsloth-studio.pid
./run.sh start
```
