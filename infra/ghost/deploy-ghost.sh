#!/usr/bin/env bash
# ──────────────────────────────────────────────────
# Interactive Deploy Ghost (Docker Compose) on a fresh server
#
# Redeploy (safe to rerun — keeps data, skips existing config):
#   bash deploy-ghost.sh
#
# Prerequisites: SSH access to a Linux server (e.g. Hetzner)
#
# Usage:
#   1. Copy files directly to /opt/ghost/:
#      ssh root@<ip> mkdir -p /opt/ghost
#      scp infra/ghost/deploy-ghost.sh infra/ghost/docker-compose.yml root@<ip>:/opt/ghost/
#
#   2. SSH in and run:
#      ssh root@<ip>
#      bash /opt/ghost/deploy-ghost.sh
#
#   3. Script will:
#      - Install Docker + Compose if missing
#      - Prompt for your FQDN
#      - Generate random DB credentials in /opt/ghost/.env
#      - Start Ghost + MySQL + Caddy (auto SSL) at /opt/ghost/
#
#   4. Open https://<your-fqdn>/ghost to create admin account
#
# Files deployed to /opt/ghost/:
#   docker-compose.yml  — Caddy + Ghost + MySQL services
#   .env                — credentials (auto-generated, chmod 600)
#
# Destroy everything (wipes all data):
#   cd /opt/ghost && docker compose down -v && rm -rf /opt/ghost
# ──────────────────────────────────────────────────
set -euo pipefail

GHOST_DIR=/opt/ghost

echo "=== Ghost Setup ==="

# Install Docker if not present
if ! command -v docker &> /dev/null; then
  echo "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
fi

# Prevent Docker from bypassing UFW by disabling iptables manipulation
if ! grep -q '"iptables": false' /etc/docker/daemon.json 2>/dev/null; then
  echo '{"iptables": false}' > /etc/docker/daemon.json
  systemctl restart docker
  echo "Docker iptables disabled — UFW controls all port access"
fi

# Install Docker Compose plugin if not present
if ! docker compose version &> /dev/null; then
  echo "Installing Docker Compose plugin..."
  apt-get update && apt-get install -y docker-compose-plugin
fi

mkdir -p "$GHOST_DIR"

# Generate .env if not exists
if [ ! -f "$GHOST_DIR/.env" ]; then
  MYSQL_DATABASE="ghost_$(openssl rand -hex 4)"
  MYSQL_USER="ghost_$(openssl rand -hex 4)"
  MYSQL_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 20)
  MYSQL_ROOT_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 20)

  read -rp "Enter your FQDN (e.g. blog.example.com): " FQDN
  if [ -z "$FQDN" ]; then
    echo "FQDN is required." && exit 1
  fi

  cat > "$GHOST_DIR/.env" <<EOF
GHOST_FQDN=${FQDN}
GHOST_URL=https://${FQDN}
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
EOF

  chmod 600 "$GHOST_DIR/.env"
  echo "Generated .env at $GHOST_DIR/.env"
else
  echo "Using existing .env at $GHOST_DIR/.env"
  source "$GHOST_DIR/.env"

fi

# Copy compose file if running from outside GHOST_DIR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "$SCRIPT_DIR" != "$GHOST_DIR" ]; then
  cp "$SCRIPT_DIR/docker-compose.yml" "$GHOST_DIR/docker-compose.yml"
fi

# Start
cd "$GHOST_DIR"
docker compose up -d

source "$GHOST_DIR/.env"
SERVER_IP=$(curl -4 -s ifconfig.me)
echo ""
echo "=== Ghost is starting ==="
echo "URL:   ${GHOST_URL}"
echo "Admin: ${GHOST_URL}/ghost"
echo "Env:   ${GHOST_DIR}/.env"
echo ""
echo "=== DNS Setup ==="
echo "Add an A record in your domain registrar:"
echo "  Type: A"
echo "  Name: @"
echo "  Value: ${SERVER_IP}"
echo ""
echo "Once DNS propagates, Cloudflare will handle SSL."
echo ""

# ── Security ──────────────────────────────────────

# UFW — only allow Cloudflare IPs on 80/443 (skip if already configured)
if command -v ufw &> /dev/null && ! ufw status | grep -q "23232/tcp"; then
  echo "=== Configuring Firewall ==="
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp      # SSH
  ufw allow 23232/tcp   # SSH (alt)

  # Fetch Cloudflare IP ranges
  CF_IPV4=$(curl -s https://www.cloudflare.com/ips-v4)
  CF_IPV6=$(curl -s https://www.cloudflare.com/ips-v6)
  if [ -z "$CF_IPV4" ]; then
    echo "Failed to fetch Cloudflare IPs — check connection" && exit 1
  fi

  for ip in $CF_IPV4 $CF_IPV6; do
    ufw allow from "$ip" to any port 80,443 proto tcp
  done

  ufw --force enable
  echo "UFW enabled (HTTP/HTTPS restricted to Cloudflare IPs)"
fi

echo "Ghost admin access: restricted via Cloudflare WAF"