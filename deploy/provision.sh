#!/usr/bin/env bash
# One-shot provisioning for a fresh Debian 13 host that will run Mattermost
# deployed by the build-deploy workflow (see deploy/deploy.sh).
#
# Usage (as root on the new server):
#   provision.sh --domain chat.example.com --tarball /root/mattermost-team-linux-amd64.tar.gz [--email you@example.com]
#
#   --domain   public hostname (DNS A record should already point here for TLS)
#   --tarball  CI-built dist tarball used to seed the first install
#              (required unless /opt/mattermost already exists)
#   --email    Let's Encrypt account email (recommended for expiry notices)
#
# Idempotent: every phase checks before acting, so re-running after a partial
# failure (e.g. TLS before DNS was ready) is safe. The DB password is generated
# once and kept in /root/.mattermost-db-pass.
set -euo pipefail

DOMAIN=""
TARBALL=""
EMAIL=""
while [ $# -gt 0 ]; do
    case "$1" in
    --domain) DOMAIN=$2; shift 2 ;;
    --tarball) TARBALL=$2; shift 2 ;;
    --email) EMAIL=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

log() { echo -e "\n[provision] $*"; }
fail() { echo "[provision] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fail "run as root"
[ -n "$DOMAIN" ] || fail "--domain is required"
grep -q 'VERSION_CODENAME=trixie' /etc/os-release || echo "[provision] WARNING: not Debian 13, proceeding anyway"

export DEBIAN_FRONTEND=noninteractive

# --- Phase 1: base system, hardening, firewall, swap ---
log "Updating system and installing packages"
apt-get update -q
apt-get full-upgrade -y -q
apt-get install -y -q unattended-upgrades ufw nginx certbot python3-certbot-nginx \
    postgresql jq curl

cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

log "Hardening sshd (key-only auth)"
cat >/etc/ssh/sshd_config.d/90-hardening.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin prohibit-password
EOF
systemctl reload ssh

log "Configuring firewall (22, 80, 443 only)"
ufw allow OpenSSH >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null

ram_mb=$(free -m | awk '/^Mem:/{print $2}')
if [ "$ram_mb" -lt 3900 ] && [ -z "$(swapon --show --noheadings)" ]; then
    log "RAM is ${ram_mb}MB; adding 2G swapfile"
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

# --- Phase 2: PostgreSQL role and database ---
PASS_FILE=/root/.mattermost-db-pass
if [ ! -f "$PASS_FILE" ]; then
    openssl rand -hex 24 >"$PASS_FILE"
    chmod 600 "$PASS_FILE"
fi
DB_PASS=$(cat "$PASS_FILE")
DSN="postgres://mmuser:${DB_PASS}@localhost:5432/mattermost?sslmode=disable"

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='mmuser'" | grep -q 1; then
    log "Creating database role mmuser"
    sudo -u postgres psql -qc "CREATE ROLE mmuser LOGIN PASSWORD '$DB_PASS';"
fi
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='mattermost'" | grep -q 1; then
    log "Creating database mattermost"
    sudo -u postgres psql -qc "CREATE DATABASE mattermost OWNER mmuser;"
fi

# --- Phase 3: seed Mattermost install (pipeline owns upgrades afterwards) ---
if ! id mattermost >/dev/null 2>&1; then
    useradd --system --user-group --home-dir /opt/mattermost --shell /usr/sbin/nologin mattermost
fi

if [ ! -e /opt/mattermost ]; then
    [ -n "$TARBALL" ] && [ -f "$TARBALL" ] || fail "/opt/mattermost missing and no --tarball given"
    log "Seeding /opt/mattermost from $TARBALL"
    tar -xzf "$TARBALL" -C /opt
    CONFIG=/opt/mattermost/config/config.json
    jq --arg dsn "$DSN" --arg url "https://$DOMAIN" '
        .SqlSettings.DriverName = "postgres" |
        .SqlSettings.DataSource = $dsn |
        .ServiceSettings.SiteURL = $url |
        .ServiceSettings.ListenAddress = ":8065"
    ' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
    chown -R mattermost:mattermost /opt/mattermost
else
    log "/opt/mattermost already exists; skipping seed install"
fi

if [ ! -f /etc/systemd/system/mattermost.service ]; then
    log "Installing systemd unit"
    cat >/etc/systemd/system/mattermost.service <<'EOF'
[Unit]
Description=Mattermost
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=notify
User=mattermost
Group=mattermost
WorkingDirectory=/opt/mattermost
ExecStart=/opt/mattermost/bin/mattermost
TimeoutStartSec=3600
KillMode=mixed
Restart=always
RestartSec=10
LimitNOFILE=49152

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable mattermost >/dev/null
fi
systemctl start mattermost

log "Waiting for Mattermost health check"
healthy=
for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null http://127.0.0.1:8065/api/v4/system/ping; then
        healthy=1
        break
    fi
    sleep 5
done
[ -n "$healthy" ] || { journalctl -u mattermost -n 50 --no-pager; fail "Mattermost did not become healthy"; }

# --- Phase 4: nginx reverse proxy + TLS ---
# We write the TLS server block ourselves and renew via webroot, instead of
# relying on certbot's nginx installer (its config parser is unreliable).
WEBROOT=/var/www/letsencrypt
CERT_DIR=/etc/letsencrypt/live/$DOMAIN
mkdir -p "$WEBROOT"

cat >/etc/nginx/snippets/mattermost-proxy.conf <<'EOF'
client_max_body_size 100M;

location ~ /api/v[0-9]+/(users/)?websocket$ {
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_buffers 256 16k;
    proxy_read_timeout 600s;
    proxy_http_version 1.1;
    proxy_pass http://mattermost_backend;
}

location / {
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Connection "";
    proxy_buffers 256 16k;
    proxy_read_timeout 600s;
    proxy_http_version 1.1;
    proxy_pass http://mattermost_backend;
}
EOF

write_site_config() { # arg: "plain" (pre-cert) or "tls"
    {
        cat <<EOF
upstream mattermost_backend {
    server 127.0.0.1:8065;
    keepalive 64;
}

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root $WEBROOT;
    }
EOF
        if [ "$1" = tls ]; then
            cat <<EOF

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $DOMAIN;

    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    include snippets/mattermost-proxy.conf;
}
EOF
        else
            cat <<'EOF'

    include snippets/mattermost-proxy.conf;
}
EOF
        fi
    } >/etc/nginx/sites-available/mattermost
    ln -sf /etc/nginx/sites-available/mattermost /etc/nginx/sites-enabled/mattermost
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl reload nginx
}

if [ ! -d "$CERT_DIR" ]; then
    log "Requesting Let's Encrypt certificate for $DOMAIN (webroot)"
    write_site_config plain
    email_args=(--register-unsafely-without-email)
    [ -n "$EMAIL" ] && email_args=(-m "$EMAIL")
    if ! certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" --non-interactive --agree-tos "${email_args[@]}"; then
        echo "[provision] WARNING: certbot failed (DNS not pointing here yet?)." \
             "Site is HTTP-only for now; fix DNS and re-run this script."
    fi
fi

if [ -d "$CERT_DIR" ]; then
    # A previous run may have registered the cert with the nginx authenticator/
    # installer; convert renewals to webroot so they never parse nginx config.
    renew_conf=/etc/letsencrypt/renewal/$DOMAIN.conf
    if grep -q 'authenticator = nginx' "$renew_conf" 2>/dev/null; then
        sed -i -e 's/authenticator = nginx/authenticator = webroot/' \
               -e '/installer = nginx/d' "$renew_conf"
        grep -q 'webroot_map' "$renew_conf" || \
            printf '[[webroot_map]]\n%s = %s\n' "$DOMAIN" "$WEBROOT" >>"$renew_conf"
    fi
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    printf '#!/bin/sh\nsystemctl reload nginx\n' >/etc/letsencrypt/renewal-hooks/deploy/nginx-reload
    chmod 755 /etc/letsencrypt/renewal-hooks/deploy/nginx-reload
    log "Enabling HTTPS server block"
    write_site_config tls
fi

# --- Phase 5: nightly local DB backup (off-box backup is a separate, later step) ---
cat >/usr/local/sbin/mattermost-nightly-backup <<'EOF'
#!/usr/bin/env bash
# Nightly pg_dump, rotating over day-of-week (7 kept). Installed by provision.sh.
set -euo pipefail
dsn=$(jq -r '.SqlSettings.DataSource' /opt/mattermost/config/config.json)
mkdir -p /opt/mattermost-backups
pg_dump --dbname="$dsn" | gzip >"/opt/mattermost-backups/nightly-$(date +%u).sql.gz"
EOF
chmod 755 /usr/local/sbin/mattermost-nightly-backup
echo '15 3 * * * root /usr/local/sbin/mattermost-nightly-backup' >/etc/cron.d/mattermost-backup

log "DONE. Mattermost is healthy on https://$DOMAIN"
echo "  DB password:      $PASS_FILE (used in config.json)"
echo "  Nightly DB dumps: /opt/mattermost-backups (DB only — file uploads in"
echo "                    /opt/mattermost/data need off-box backup, set up later)"
echo "  Next: configure DEPLOY_* secrets in GitHub; deploys then own /opt/mattermost."
