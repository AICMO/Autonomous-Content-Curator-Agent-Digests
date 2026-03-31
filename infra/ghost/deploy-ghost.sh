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
#      - Enable auto-update on boot (pulls latest images via systemd)
#
#   4. Open https://<your-fqdn>/ghost to create admin account
#
# Files deployed to /opt/ghost/:
#   docker-compose.yml  — Caddy + Ghost + MySQL services
#   .env                — credentials (auto-generated, chmod 600)
#
# Destroy everything (wipes all data):
#   cd /opt/ghost && docker compose down -v && rm -rf /opt/ghost
#
# Update Ghost (patch/minor within same major):
#   cd /opt/ghost && docker compose pull ghost && docker compose up -d ghost
#
# Upgrade Ghost (new major version, e.g. 6→7):
#   1. Back up:  docker exec ghost-db mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" ghost_db > /tmp/ghost_backup.sql
#   2. Edit docker-compose.yml: change ghost image tag (e.g. ghost:6 → ghost:7)
#   3. Pull and restart: docker compose pull ghost && docker compose up -d ghost
#   4. Check logs:  docker logs ghost --tail 50
#   If something breaks, restore the backup and revert the image tag.
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

# Auto-update on boot:
# 1. Docker restart:always brings containers up instantly (old images)
# 2. 30s later this cron pulls latest ghost:6/mysql:9/caddy:2 images
# 3. docker compose up -d recreates only containers whose image changed
# Data volumes are untouched — only container binaries update
CRON_JOB="@reboot sleep 30 && cd $GHOST_DIR && /usr/bin/docker compose pull --quiet && /usr/bin/docker compose up -d"
if ! crontab -l 2>/dev/null | grep -qF "ghost"; then
  (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
  echo "Added @reboot cron job (auto-pulls latest images on boot)"
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

echo "=== Newsletter Emails (Mailgun) ==="
echo "To send newsletter emails to subscribers:"
echo "  1. Create a Mailgun account: https://www.mailgun.com"
echo "  2. Add and verify your domain (e.g. mg.${GHOST_FQDN:-example.com})"
echo "  3. Get your private API key: https://app.mailgun.com/settings/api_security"
echo "  4. In Ghost admin → Settings → Mailgun, enter:"
echo "     - Mailgun domain: your verified domain (just the domain, not full URL)"
echo "     - Mailgun API key: your private API key"
echo "     - Mailgun region: US or EU (must match your Mailgun account)"
echo ""
echo "=== Email Sender Icon (BIMI) ==="
echo "To show your brand logo next to emails in Gmail:"
echo "  1. Set DMARC policy to quarantine or reject:"
echo "     _dmarc.${GHOST_FQDN:-example.com} TXT \"v=DMARC1; p=quarantine; rua=mailto:dmarc@${GHOST_FQDN:-example.com}\""
echo "  2. Host a square SVG logo at https://${GHOST_FQDN:-example.com}/logo.svg"
echo "  3. Add DNS TXT record:"
echo "     default._bimi.${GHOST_FQDN:-example.com} TXT \"v=BIMI1; l=https://${GHOST_FQDN:-example.com}/logo.svg\""
echo ""
echo "=== Mailgun Unsubscribe ==="
echo "Disable Mailgun's unsubscribe link (Ghost handles its own):"
echo "  Mailgun dashboard → Sending → Domains → Domain Settings → Tracking → Unsubscribes → Off"
echo ""
echo "NOTE: Run 'bash /path/to/ubuntu_security_hardening.sh' for firewall, SSH hardening, and fail2ban."