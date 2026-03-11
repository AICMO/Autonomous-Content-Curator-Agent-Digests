#!/usr/bin/env bash
# ──────────────────────────────────────────────────
# Ubuntu Server Security Hardening
#
# Safe to rerun — idempotent, skips already-configured items.
#
# Usage:
#   ssh root@<ip>
#   bash ubuntu_security_hardening.sh
#
# What it does:
#   1. System updates + unattended security upgrades
#   2. SSH hardening (custom port, key-only, no root)
#   3. UFW firewall (Cloudflare-only HTTP/S, custom SSH port)
#   4. Docker iptables isolation (prevents Docker bypassing UFW)
#   5. fail2ban for SSH brute force protection
#   6. sysctl network hardening
#   7. Log retention (180 days)
# ──────────────────────────────────────────────────
set -euo pipefail

SSH_PORT=23232

# Detect SSH user: current non-root user or first sudoer
if [ "$(id -u)" -ne 0 ]; then
  SSH_USER="$(whoami)"
else
  SSH_USER=$(getent group sudo | cut -d: -f4 | tr ',' '\n' | head -1)
fi

if [ -z "$SSH_USER" ] || ! id "$SSH_USER" &>/dev/null; then
  echo "ERROR: No non-root sudo user found. Create one first."
  exit 1
fi

echo "=== Ubuntu Security Hardening (SSH user: ${SSH_USER}) ==="

# ── 1. System Updates ────────────────────────────

echo "--- System updates ---"
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -yq upgrade

# ── 2. Unattended Security Upgrades ──────────────

echo "--- Unattended upgrades ---"
apt-get install -y unattended-upgrades

# Enable auto-updates
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# Configure: enable ESM, allow auto-reboot at 02:00
UPGRADES_CONF=/etc/apt/apt.conf.d/50unattended-upgrades
sed -i 's|//\s*"${distro_id}ESMApps:${distro_codename}-apps-security";|"${distro_id}ESMApps:${distro_codename}-apps-security";|g' "$UPGRADES_CONF"
sed -i 's|//\s*"${distro_id}ESM:${distro_codename}-infra-security";|"${distro_id}ESM:${distro_codename}-infra-security";|g' "$UPGRADES_CONF"
sed -i 's|//\s*"${distro_id}:${distro_codename}-updates";|"${distro_id}:${distro_codename}-updates";|g' "$UPGRADES_CONF"
sed -i 's|//Unattended-Upgrade::Automatic-Reboot "false";|Unattended-Upgrade::Automatic-Reboot "true";|g' "$UPGRADES_CONF"
sed -i 's|//Unattended-Upgrade::Automatic-Reboot-WithUsers "true";|Unattended-Upgrade::Automatic-Reboot-WithUsers "true";|g' "$UPGRADES_CONF"
sed -i 's|//Unattended-Upgrade::Automatic-Reboot-Time "02:00";|Unattended-Upgrade::Automatic-Reboot-Time "02:00";|g' "$UPGRADES_CONF"

systemctl enable unattended-upgrades
systemctl restart unattended-upgrades
echo "Unattended upgrades configured (auto-reboot at 02:00)"

# ── 3. SSH Hardening ─────────────────────────────

echo "--- SSH hardening ---"
if grep -q "^Port" /etc/ssh/sshd_config \
  && grep -q "^AllowUsers" /etc/ssh/sshd_config \
  && grep -q "^PermitRootLogin" /etc/ssh/sshd_config \
  && grep -q "^PasswordAuthentication" /etc/ssh/sshd_config \
  && grep -q "^PermitEmptyPasswords" /etc/ssh/sshd_config; then
  echo "SSH already hardened — skipping"
else
  cat > /etc/ssh/sshd_config << EOF
Port ${SSH_PORT}
AllowUsers ${SSH_USER}
PermitRootLogin no
PermitEmptyPasswords no
PasswordAuthentication no
ChallengeResponseAuthentication no
MaxAuthTries 2
UsePAM no
ClientAliveInterval 300
ClientAliveCountMax 1
AllowTcpForwarding no
X11Forwarding no
PrintMotd no
AllowAgentForwarding no
AuthorizedKeysFile .ssh/authorized_keys
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

  if sshd -t; then
    systemctl restart sshd
    echo "SSH hardened (port ${SSH_PORT}, user ${SSH_USER}, key-only, no root, no empty passwords)"
  else
    echo "ERROR: sshd config invalid — not restarting. Fix /etc/ssh/sshd_config manually."
  fi
fi

# ── 4. UFW Firewall ──────────────────────────────

echo "--- UFW firewall ---"
apt-get install -y ufw

if ! ufw status | grep -q "${SSH_PORT}/tcp"; then
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  # SSH
  ufw allow 22/tcp comment 'SSH standard'
  ufw allow ${SSH_PORT}/tcp comment 'SSH custom'

  # HTTP/HTTPS — Cloudflare IPs only
  CF_IPV4=$(curl -s https://www.cloudflare.com/ips-v4)
  CF_IPV6=$(curl -s https://www.cloudflare.com/ips-v6)
  if [ -z "$CF_IPV4" ]; then
    echo "WARNING: Failed to fetch Cloudflare IPs — skipping HTTP/S rules"
  else
    for ip in $CF_IPV4 $CF_IPV6; do
      ufw allow from "$ip" to any port 80,443 proto tcp comment 'Cloudflare'
    done
    echo "HTTP/HTTPS restricted to Cloudflare IPs"
  fi

  ufw --force enable
  echo "UFW enabled"
else
  echo "UFW already configured — skipping"
fi

# ── 5. Docker iptables isolation ─────────────────

# Install Docker if not present
if ! command -v docker &> /dev/null; then
  echo "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
fi

if command -v docker &> /dev/null; then
  echo "--- Docker iptables isolation ---"
  if ! grep -q '"iptables": false' /etc/docker/daemon.json 2>/dev/null; then
    echo '{"iptables": false}' > /etc/docker/daemon.json
    systemctl restart docker
    echo "Docker iptables disabled — UFW controls all port access"
  else
    echo "Docker iptables already disabled — skipping"
  fi
fi

# ── 6. fail2ban ──────────────────────────────────

echo "--- fail2ban ---"
apt-get install -y fail2ban

if [ ! -f /etc/fail2ban/jail.local ]; then
  cat > /etc/fail2ban/jail.local << EOF
[sshd]
enabled = true
port = 22,${SSH_PORT}
filter = sshd
maxretry = 3
bantime = 3600
findtime = 600
EOF
  systemctl enable fail2ban
  systemctl restart fail2ban
  echo "fail2ban configured (ban after 3 attempts for 1h)"
else
  echo "fail2ban already configured — skipping"
fi

# ── 7. sysctl network hardening ──────────────────

echo "--- sysctl hardening ---"
SYSCTL_FILE=/etc/sysctl.d/99-hardening.conf
if [ ! -f "$SYSCTL_FILE" ]; then
  cat > "$SYSCTL_FILE" << 'EOF'
# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Don't send ICMP redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2

# IP spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Log martian packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Disable IPv6 if not used
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
  sysctl -p "$SYSCTL_FILE"
  echo "sysctl hardening applied"
else
  echo "sysctl hardening already configured — skipping"
fi

# ── 8. Log retention ─────────────────────────────

echo "--- Log retention ---"
sed -Ei "s/(.+rotate).+/\1 180/" /etc/logrotate.d/rsyslog
echo "Log rotation set to 180 days"

# ── Done ──────────────────────────────────────────

echo ""
echo "=== Security hardening complete ==="
echo "SSH port: ${SSH_PORT}"
echo "Firewall: UFW (Cloudflare-only HTTP/S)"
echo "Auto-updates: enabled (reboot at 02:00)"
echo "fail2ban: SSH protection active"
echo ""
echo "IMPORTANT: Make sure you can SSH on port ${SSH_PORT} before closing this session!"
