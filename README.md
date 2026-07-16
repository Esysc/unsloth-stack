# Unsloth Stack

Run [Unsloth Studio](https://docs.unsloth.ai/basics/getting-started-with-chat) behind a Caddy reverse proxy, accessible over the internet via a custom domain.

## Architecture

```
Internet
   |
   v
[DNS: your-domain.com] --> your public IP
   |
   v
[Caddy] (Docker, host network mode, port 443/80)
   |
   v
[Unsloth Studio] (local, 192.168.x.x:8000)
```

Caddy handles TLS termination (automatic HTTPS via Let's Encrypt) and proxies requests to Unsloth Studio running on your local machine.

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

| Variable       | Description                              | Default                   |
|----------------|------------------------------------------|---------------------------|
| `STUDIO_HOST`  | Local IP of the machine running Studio   | `192.168.x.x`           |
| `STUDIO_PORT`  | Port Unsloth Studio listens on           | `8000`                    |
| `DOMAIN`       | Public domain for reverse proxy          | `your-domain.com`   |

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

## How It Works

- **Caddy** runs in a Docker container with `network_mode: host`, giving it direct access to your machine's network. It automatically provisions TLS certificates for your domain via Let's Encrypt.
- **Unsloth Studio** runs as a background process managed by `run.sh`. Process IDs are tracked in `.pids/` and logs are written to `logs/`.

## Files

| File               | Description                                      |
|--------------------|--------------------------------------------------|
| `run.sh`           | Management script (start/stop/restart/status)    |
| `docker-compose.yml` | Docker Compose config for Caddy                |
| `Caddyfile`        | Caddy reverse proxy configuration                |
| `.env.example`     | Template for environment configuration           |
| `.env`             | Your local configuration (not committed)         |

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
