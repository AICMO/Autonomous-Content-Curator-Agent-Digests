#!/usr/bin/env bash
# ──────────────────────────────────────────────────
# One-Click Hetzner VPS Setup
#
# Provisions a fully hardened Ubuntu server accessible only via Tailscale.
# No SSH exposed on public IP — connect with Mosh/SSH through Tailscale.
#
# What you get:
#   - Ubuntu 24.04 with unattended security upgrades (auto-reboot at 02:00)
#   - Tailscale mesh VPN (private SSH + Mosh access)
#   - Docker Engine + Compose plugin
#   - Mosh, curl, jq, tmux, git
#   - Hetzner HW firewall (80/443 only, no public SSH)
#   - UFW: Cloudflare-only HTTP/S (default) + all traffic on tailscale0
#   - SSH bound to Tailscale IP only (key-only, no root, no passwords)
#   - fail2ban, sysctl hardening, 180-day log retention
#   - Auto-appends server to ~/.ssh/config
#
# Prerequisites:
#   brew install hcloud
#   export HCLOUD_TOKEN="..."                      # https://console.hetzner.cloud > Security > API Tokens (Read & Write)
#   export TAILSCALE_AUTH_KEY="tskey-auth-..."      # https://login.tailscale.com/admin/settings/keys (reusable recommended)
#   SSH key uploaded to Hetzner:                   # https://console.hetzner.com > Security > SSH Keys
#
# Usage:
#   bash infra/hetzner-setup.sh <server-name>
#   # ex.: bash infra/hetzner-setup.sh hetzner-server-evios  # Default (cx23, Helsinki)
#
# Connect (after ~3 min):
#   mosh evios@<server-name>     # Mosh via Tailscale
#   ssh evios@<server-name>      # SSH via Tailscale
#   # Or in Termius: add host <server-name>, enable Mosh
#
# Override defaults:
#   HCLOUD_SERVER_TYPE=cx32 HCLOUD_LOCATION=fsn1 bash infra/hetzner-setup.sh my-server
#   CLOUDFLARE_ONLY=false bash infra/hetzner-setup.sh my-server
#   TIMEZONE=Europe/Kyiv HCLOUD_SSH_KEY=other_key bash infra/hetzner-setup.sh my-server
#
# Config (env vars):
#   HCLOUD_SERVER_TYPE  — server type              (default: cx23)
#   HCLOUD_LOCATION     — datacenter location      (default: hel1)
#   HCLOUD_SSH_KEY      — SSH key name in Hetzner  (default: evios_id_ed25519.pub)
#   TIMEZONE            — server timezone          (default: UTC)
#   CLOUDFLARE_ONLY     — restrict HTTP/S to CF    (default: true)
#
# Destroy:
#   hcloud server delete <server-name>
#
# ── Details ──────────────────────────────────────
#
# Server types (HCLOUD_SERVER_TYPE):
#     cx23   — 2 vCPU,  4GB,  40GB NVMe  ~€3/mo  (default)
#     cx33   — 4 vCPU,  8GB,  80GB NVMe  ~€7/mo
#     cax23  — 4 vCPU,  8GB,  80GB NVMe  ~€5/mo  (Arm64)
#   Full list: https://www.hetzner.com/cloud/ | hcloud server-type list
#
# Locations (HCLOUD_LOCATION):
#     hel1   — Helsinki, FI  (default)
#     fsn1   — Falkenstein, DE
#     ash    — Ashburn, US
#   Full list: hcloud location list
#
# Architecture:
#   Internet --> Hetzner HW FW (80/443 only) --> UFW --> Docker containers
#                                                  |
#   You --> Tailscale tunnel --> tailscale0 --> SSH/Mosh (all ports allowed)
#
#   Tailscale uses outbound connections (NAT traversal) — works with zero inbound ports.
#   Mosh UDP traffic (60000-61000) flows through the Tailscale tunnel, not public IP.
#
# What happens:
#   Local machine (hcloud CLI):
#     1. Creates Hetzner HW firewall — 80/443 only, no public SSH
#     2. Generates cloud-init with your SSH key, Tailscale auth key, and config
#     3. Creates Ubuntu 24.04 server with cloud-init user-data + firewall attached
#
#   Server (cloud-init, first boot ~3 min):
#     1. Creates 'evios' user with your SSH key
#     2. Installs + upgrades system packages
#     3. Installs Tailscale, joins your tailnet with --ssh
#     4. Binds SSH to Tailscale IP only (ListenAddress 100.x.y.z)
#     5. Configures UFW (Cloudflare-only HTTP/S by default + everything on tailscale0)
#     6. Installs Docker + Compose, configures iptables isolation + NAT
#     7. Enables unattended security upgrades (auto-reboot at 02:00)
#     8. Activates fail2ban, sysctl hardening, 180-day log retention
#     9. Writes completion marker to /var/log/hetzner-setup-done
#
# Security:
#   - SSH: key-only, no root, no passwords, bound to Tailscale IP only
#   - UFW: Cloudflare-only HTTP/S (default) + all on tailscale0 (defense-in-depth)
#   - Docker: iptables: false + explicit NAT rules (prevents bypassing UFW)
#   - fail2ban: SSH brute-force protection (ban after 3 attempts for 1h)
#   - sysctl: SYN flood protection, IP spoofing, ICMP hardening, martian logging
#   - Updates: unattended security upgrades with auto-reboot at 02:00
#   - Logs: 180-day retention
#
# Connect (after ~3 min):
#   tailscale status                       # verify server appeared in your tailnet
#   mosh evios@<server-name>               # Mosh via Tailscale (recommended)
#   ssh evios@<server-name>                # SSH via Tailscale
#   Termius: add host '<server-name>', user 'evios', enable Mosh
#
# Verify:
#   ssh evios@<server-name> cat /var/log/hetzner-setup-done
#   ssh evios@<server-name> cat /var/log/hetzner-setup.log
#
# Deploy Ghost:
#   scp infra/ghost/{deploy-ghost.sh,docker-compose.yml} evios@<server-name>:/opt/ghost/
#   ssh evios@<server-name> bash /opt/ghost/deploy-ghost.sh
#
# Debug (if Tailscale doesn't appear after 5 min):
#   Hetzner Console (VNC): https://console.hetzner.cloud
#   Check logs: cat /var/log/cloud-init-output.log && cat /var/log/hetzner-setup.log
#
# ──────────────────────────────────────────────────
set -eo pipefail

# ── Config ──────────────────────────────────────
SERVER_NAME="${1:?Usage: bash infra/hetzner-setup.sh <server-name>}"
SERVER_TYPE="${HCLOUD_SERVER_TYPE:-cx23}"         # 2 vCPU, 4GB, 40GB NVMe (~€3/mo)
SERVER_LOCATION="${HCLOUD_LOCATION:-hel1}"        # Helsinki, FI
SSH_USER="evios"
HCLOUD_SSH_KEY="${HCLOUD_SSH_KEY:-evios_id_ed25519.pub}"
TIMEZONE="${TIMEZONE:-UTC}"
CLOUDFLARE_ONLY="${CLOUDFLARE_ONLY:-true}"        # restrict HTTP/S to Cloudflare IPs
FW_NAME="http-s-only-fw"

# ── Validate ────────────────────────────────────
if [ -z "${HCLOUD_TOKEN:-}" ]; then
  echo "ERROR: HCLOUD_TOKEN is required -- https://console.hetzner.cloud > Security > API Tokens"
  exit 1
fi
if [ -z "${TAILSCALE_AUTH_KEY:-}" ]; then
  echo "ERROR: TAILSCALE_AUTH_KEY is required -- https://login.tailscale.com/admin/settings/keys"
  exit 1
fi

command -v hcloud &>/dev/null || { echo "ERROR: hcloud CLI not found -- brew install hcloud"; exit 1; }

# Verify SSH key exists in Hetzner
hcloud ssh-key describe "$HCLOUD_SSH_KEY" &>/dev/null 2>&1 \
  || { echo "ERROR: SSH key '$HCLOUD_SSH_KEY' not found in Hetzner. Upload at https://console.hetzner.com -> Security -> SSH Keys"; exit 1; }
SSH_PUB_KEY=$(hcloud ssh-key describe "$HCLOUD_SSH_KEY" -o format='{{.PublicKey}}')

if hcloud server describe "$SERVER_NAME" &>/dev/null 2>&1; then
  echo "ERROR: Server '$SERVER_NAME' already exists"
  echo "  Delete: hcloud server delete $SERVER_NAME && hcloud firewall delete $FW_NAME"
  exit 1
fi

echo "=== Hetzner VPS Setup ==="
echo "Server:    $SERVER_NAME ($SERVER_TYPE @ $SERVER_LOCATION)"
echo "User:      $SSH_USER"
echo "Timezone:  $TIMEZONE"
echo "Firewall:  80/443 only (SSH via Tailscale)"
echo ""

# ── Hetzner Firewall (80/443 only) ──────────────
if ! hcloud firewall describe "$FW_NAME" &>/dev/null 2>&1; then
  echo "--- Creating firewall: $FW_NAME ---"
  hcloud firewall create --name "$FW_NAME"
  hcloud firewall add-rule "$FW_NAME" --direction in --protocol tcp --port 80 \
    --source-ips 0.0.0.0/0 --source-ips ::/0 --description "HTTP"
  hcloud firewall add-rule "$FW_NAME" --direction in --protocol tcp --port 443 \
    --source-ips 0.0.0.0/0 --source-ips ::/0 --description "HTTPS"
else
  echo "Firewall '$FW_NAME' exists -- reusing"
fi

# ── Generate Cloud-Init ─────────────────────────
# Uses single-quoted heredoc (no expansion) + sed substitution for safety.
# All __PLACEHOLDER__ values are replaced with local variables before upload.
CLOUD_INIT=$(mktemp /tmp/cloud-init-XXXX.yml)
trap 'rm -f "$CLOUD_INIT"' EXIT

cat > "$CLOUD_INIT" <<'CIEOF'
#cloud-config

timezone: __TIMEZONE__

users:
  - name: __SSH_USER__
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - __SSH_PUB_KEY__

package_update: true
package_upgrade: true

packages:
  - mosh
  - fail2ban
  - unattended-upgrades
  - apt-listchanges
  - curl
  - jq
  - tmux
  - git
  - ufw

write_files:
  # Auto-updates
  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";

  # fail2ban
  - path: /etc/fail2ban/jail.local
    content: |
      [sshd]
      enabled = true
      port = 22
      maxretry = 3
      bantime = 3600
      findtime = 600

  # sysctl hardening
  - path: /etc/sysctl.d/99-hardening.conf
    content: |
      net.ipv4.conf.all.accept_redirects = 0
      net.ipv4.conf.default.accept_redirects = 0
      net.ipv6.conf.all.accept_redirects = 0
      net.ipv6.conf.default.accept_redirects = 0
      net.ipv4.conf.all.send_redirects = 0
      net.ipv4.conf.default.send_redirects = 0
      net.ipv4.icmp_echo_ignore_broadcasts = 1
      net.ipv4.tcp_syncookies = 1
      net.ipv4.tcp_max_syn_backlog = 2048
      net.ipv4.tcp_synack_retries = 2
      net.ipv4.conf.all.rp_filter = 1
      net.ipv4.conf.default.rp_filter = 1
      net.ipv4.conf.all.log_martians = 1
      net.ipv4.conf.default.log_martians = 1

  # Docker: prevent bypassing UFW
  - path: /etc/docker/daemon.json
    content: |
      {"iptables": false}

  # SSH config template (Tailscale IP filled in at boot)
  - path: /etc/ssh/sshd_config.tpl
    content: |
      ListenAddress __TS_IP__
      PermitRootLogin no
      AllowUsers __SSH_USER__
      PasswordAuthentication no
      PermitEmptyPasswords no
      KbdInteractiveAuthentication no
      MaxAuthTries 3
      UsePAM no
      X11Forwarding no
      AllowTcpForwarding no
      AllowAgentForwarding no
      PrintMotd no
      AuthorizedKeysFile .ssh/authorized_keys
      AcceptEnv LANG LC_*
      Subsystem sftp /usr/lib/openssh/sftp-server

  # Main setup script — runs once on first boot
  - path: /opt/setup.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      echo "=== Server Setup Started $(date -Iseconds) ==="

      # ── Tailscale ──────────────────────────────
      echo "--- Installing Tailscale ---"
      curl -fsSL https://tailscale.com/install.sh | sh
      tailscale up --auth-key=__TAILSCALE_AUTH_KEY__ --ssh --hostname=__SERVER_NAME__
      TS_IP=$(tailscale ip -4)
      echo "Tailscale connected: $TS_IP"

      # ── SSH: Tailscale interface only ──────────
      echo "--- Configuring SSH ---"
      sed "s/__TS_IP__/$TS_IP/" /etc/ssh/sshd_config.tpl > /etc/ssh/sshd_config
      rm /etc/ssh/sshd_config.tpl
      systemctl restart sshd
      echo "SSH bound to $TS_IP"

      # ── UFW (defense-in-depth) ─────────────────
      echo "--- Configuring UFW ---"
      ufw default deny incoming
      ufw default allow outgoing

      if [ "__CLOUDFLARE_ONLY__" = "true" ]; then
        # HTTP/S from Cloudflare IPs only
        CF_IPV4=$(curl -s https://www.cloudflare.com/ips-v4)
        CF_IPV6=$(curl -s https://www.cloudflare.com/ips-v6)
        if [ -n "$CF_IPV4" ]; then
          for ip in $CF_IPV4 $CF_IPV6; do
            ufw allow from "$ip" to any port 80,443 proto tcp comment 'Cloudflare'
          done
          echo "HTTP/S restricted to Cloudflare IPs"
        else
          echo "WARNING: Failed to fetch Cloudflare IPs -- allowing all"
          ufw allow 80/tcp comment 'HTTP'
          ufw allow 443/tcp comment 'HTTPS'
        fi
      else
        ufw allow 80/tcp comment 'HTTP'
        ufw allow 443/tcp comment 'HTTPS'
      fi

      ufw allow in on tailscale0 comment 'Tailscale - SSH, Mosh, all'
      ufw --force enable

      # ── Docker + Compose ───────────────────────
      echo "--- Installing Docker ---"
      curl -fsSL https://get.docker.com | sh
      systemctl enable docker
      usermod -aG docker __SSH_USER__
      apt-get install -y docker-compose-plugin
      systemctl restart docker

      # Docker NAT (required when iptables: false)
      DOCKER_SUB=$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || echo "172.17.0.0/16")
      EXT_IF=$(ip route | awk '/default/ {print $5; exit}')

      BEFORE_RULES=/etc/ufw/before.rules
      if ! grep -q "Docker NAT" "$BEFORE_RULES" 2>/dev/null; then
        sed -i "1i\\
      # Docker NAT\\
      *nat\\
      :POSTROUTING ACCEPT [0:0]\\
      -A POSTROUTING -s ${DOCKER_SUB} -o ${EXT_IF} -j MASQUERADE\\
      COMMIT\\
      " "$BEFORE_RULES"

        sed -i "/^# don't delete the 'COMMIT' line/i\\
      # Docker forwarding\\
      -A ufw-before-forward -s ${DOCKER_SUB} -o ${EXT_IF} -j ACCEPT\\
      -A ufw-before-forward -d ${DOCKER_SUB} -m state --state RELATED,ESTABLISHED -j ACCEPT" "$BEFORE_RULES"

        ufw reload
      fi
      echo "Docker installed (iptables isolated, NAT configured)"

      # ── Unattended upgrades ────────────────────
      echo "--- Configuring auto-updates ---"
      CONF=/etc/apt/apt.conf.d/50unattended-upgrades
      sed -i 's|//Unattended-Upgrade::Automatic-Reboot "false";|Unattended-Upgrade::Automatic-Reboot "true";|g' "$CONF"
      sed -i 's|//Unattended-Upgrade::Automatic-Reboot-WithUsers "true";|Unattended-Upgrade::Automatic-Reboot-WithUsers "true";|g' "$CONF"
      sed -i 's|//Unattended-Upgrade::Automatic-Reboot-Time "02:00";|Unattended-Upgrade::Automatic-Reboot-Time "02:00";|g' "$CONF"
      systemctl enable unattended-upgrades
      systemctl restart unattended-upgrades

      # ── Apply hardening ────────────────────────
      echo "--- Applying hardening ---"
      sysctl -p /etc/sysctl.d/99-hardening.conf
      systemctl enable fail2ban && systemctl restart fail2ban
      sed -Ei 's/(.+rotate).+/\1 180/' /etc/logrotate.d/rsyslog

      # ── Done ───────────────────────────────────
      echo "SETUP_COMPLETE $(date -Iseconds)" > /var/log/hetzner-setup-done
      echo "=== Setup Complete ==="

runcmd:
  - bash /opt/setup.sh 2>&1 | tee /var/log/hetzner-setup.log
  - rm -f /opt/setup.sh
CIEOF

# Substitute local values into cloud-init template
sed_inplace() {
  if [[ "$OSTYPE" == darwin* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

sed_inplace \
  -e "s|__SSH_USER__|${SSH_USER}|g" \
  -e "s|__SSH_PUB_KEY__|${SSH_PUB_KEY}|g" \
  -e "s|__TAILSCALE_AUTH_KEY__|${TAILSCALE_AUTH_KEY}|g" \
  -e "s|__SERVER_NAME__|${SERVER_NAME}|g" \
  -e "s|__TIMEZONE__|${TIMEZONE}|g" \
  -e "s|__CLOUDFLARE_ONLY__|${CLOUDFLARE_ONLY}|g" \
  "$CLOUD_INIT"

# ── Create Server ───────────────────────────────
echo "--- Creating server ---"
hcloud server create \
  --name "$SERVER_NAME" \
  --type "$SERVER_TYPE" \
  --image ubuntu-24.04 \
  --location "$SERVER_LOCATION" \
  --firewall "$FW_NAME" \
  --ssh-key "$HCLOUD_SSH_KEY" \
  --user-data-from-file "$CLOUD_INIT"

SERVER_IP=$(hcloud server ip "$SERVER_NAME")

# ── Wait for cloud-init + Tailscale ─────────────
echo ""
echo "--- Waiting for setup to complete ---"
SECONDS=0
while true; do
  elapsed=$SECONDS
  # Check if server appears in Tailscale
  if tailscale status 2>/dev/null | grep -q "$SERVER_NAME"; then
    echo -e "\r[${elapsed}s] Tailscale connected!                "
    break
  fi
  printf "\r[%ds] Waiting for cloud-init + Tailscale..." "$elapsed"
  if [ "$elapsed" -gt 600 ]; then
    echo -e "\r[${elapsed}s] Timeout -- check Hetzner console for errors"
    break
  fi
  sleep 5
done

# ── Append to ~/.ssh/config ────────────────────
SSH_CONFIG="$HOME/.ssh/config"
SSH_IDENTITY_FILE="${HCLOUD_SSH_KEY%.pub}"
if ! grep -q "^Host ${SERVER_NAME}$" "$SSH_CONFIG" 2>/dev/null; then
  cat >> "$SSH_CONFIG" <<SSHCONF

# vps auto-spawned $(date +%Y-%m-%d)
Host ${SERVER_NAME}
    Hostname ${SERVER_NAME}
    User ${SSH_USER}
    IdentityFile ~/.ssh/${SSH_IDENTITY_FILE}
SSHCONF
  echo "Added ${SERVER_NAME} to ~/.ssh/config"
else
  echo "${SERVER_NAME} already in ~/.ssh/config -- skipping"
fi

echo ""
echo "=== Server Created ==="
echo "Name:      $SERVER_NAME"
echo "Public IP: $SERVER_IP"
echo "Firewall:  $FW_NAME (80/443 only)"
echo ""
echo "=== Connect (wait ~3 min for setup) ==="
echo "  tailscale status                       # verify server appeared"
echo "  mosh ${SSH_USER}@${SERVER_NAME}        # Mosh via Tailscale"
echo "  ssh ${SSH_USER}@${SERVER_NAME}         # SSH via Tailscale"
echo ""
echo "  Termius: add host '${SERVER_NAME}', user '${SSH_USER}', enable Mosh"
echo ""
echo "=== Verify ==="
echo "  ssh ${SSH_USER}@${SERVER_NAME} cat /var/log/hetzner-setup-done"
echo "  ssh ${SSH_USER}@${SERVER_NAME} cat /var/log/hetzner-setup.log"
echo ""
echo "=== Deploy Ghost ==="
echo "  scp infra/ghost/{deploy-ghost.sh,docker-compose.yml} ${SSH_USER}@${SERVER_NAME}:/opt/ghost/"
echo "  ssh ${SSH_USER}@${SERVER_NAME} bash /opt/ghost/deploy-ghost.sh"
echo ""
echo "=== Destroy ==="
echo "  hcloud server delete ${SERVER_NAME}"