#!/usr/bin/env bash
# Sets up encrypted off-box backups for Mattermost using restic + a systemd
# timer. Backs up nightly: a fresh pg_dump, /opt/mattermost-shared/data
# (file uploads) and /opt/mattermost-shared/config.
#
# Usage (as root):
#   1. bash backup-setup.sh          # installs everything, writes config template
#   2. edit /etc/restic/env          # point it at your S3-compatible bucket
#   3. bash backup-setup.sh          # re-run: initializes repo, enables timer,
#                                    # runs the first backup
#
# IMPORTANT: /etc/restic/repo-password encrypts the backups. Copy it somewhere
# safe off this server — without it the backups are unreadable.
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
command -v restic >/dev/null || apt-get install -y -q restic
command -v rclone >/dev/null || apt-get install -y -q rclone

mkdir -p /etc/restic

if [ ! -f /etc/restic/repo-password ]; then
    openssl rand -hex 32 >/etc/restic/repo-password
    chmod 600 /etc/restic/repo-password
fi

if [ ! -f /etc/restic/env ]; then
    cat >/etc/restic/env <<'EOF'
# Restic backend configuration. Fill in and re-run backup-setup.sh.
#
# Backblaze B2 (recommended): create a bucket (private) and an application key
# restricted to it, then use the S3-compatible endpoint shown in the bucket
# details, e.g.:
#   RESTIC_REPOSITORY=s3:https://s3.us-west-004.backblazeb2.com/YOUR-BUCKET
#   AWS_ACCESS_KEY_ID=YOUR-KEY-ID
#   AWS_SECRET_ACCESS_KEY=YOUR-APPLICATION-KEY
#
# Vultr Object Storage works the same way:
#   RESTIC_REPOSITORY=s3:https://ewr1.vultrobjects.com/YOUR-BUCKET
#
RESTIC_REPOSITORY=CHANGE-ME
AWS_ACCESS_KEY_ID=CHANGE-ME
AWS_SECRET_ACCESS_KEY=CHANGE-ME
RESTIC_PASSWORD_FILE=/etc/restic/repo-password

# Optional: Mattermost incoming webhook to notify on backup FAILURE.
#MM_WEBHOOK_URL=
EOF
    chmod 600 /etc/restic/env
    echo "Template written to /etc/restic/env — fill it in, then re-run this script."
    exit 0
fi

if grep -q CHANGE-ME /etc/restic/env; then
    echo "/etc/restic/env still contains CHANGE-ME placeholders — fill it in, then re-run." >&2
    exit 1
fi

if ! grep -q 'R2_BUCKET=' /etc/restic/env; then
    cat >>/etc/restic/env <<'EOF'

# --- Cloudflare R2 primary file store (optional) ---
# When Mattermost's FileSettings points at an R2 bucket, set these and the
# nightly backup also mirrors that bucket to a SECOND B2 bucket (separate from
# the restic repo, with its own application key). Deleted/overwritten files
# are kept 30 days under deleted/<date>/ in the mirror bucket.
#R2_ACCOUNT_ID=
#R2_ACCESS_KEY_ID=
#R2_SECRET_ACCESS_KEY=
#R2_BUCKET=
#B2_S3_ENDPOINT=s3.us-west-004.backblazeb2.com
#B2_MIRROR_KEY_ID=
#B2_MIRROR_SECRET=
#B2_MIRROR_BUCKET=
EOF
    echo "Added R2 mirror template to /etc/restic/env — fill in once files live in R2."
fi

cat >/usr/local/sbin/mattermost-offsite-backup <<'EOF'
#!/usr/bin/env bash
# Nightly off-box backup (installed by backup-setup.sh, run by systemd timer).
set -euo pipefail
set -a
. /etc/restic/env
set +a

notify_failure() {
    [ -n "${MM_WEBHOOK_URL:-}" ] || return 0
    jq -n --arg text ":x: Off-box backup FAILED on $(hostname) — check: journalctl -u mattermost-backup" \
        '{text: $text}' | curl -fsS -X POST -H 'Content-Type: application/json' -d @- "$MM_WEBHOOK_URL" || true
}
trap 'notify_failure' ERR

dsn=$(jq -r '.SqlSettings.DataSource' /opt/mattermost/config/config.json)
pg_dump --dbname="$dsn" | restic backup --stdin --stdin-filename mattermost.sql --tag db
restic backup --tag files /opt/mattermost-shared/data /opt/mattermost-shared/config

# When file uploads live in Cloudflare R2 (FileSettings = amazons3), mirror the
# live bucket to B2. `sync` makes current/ an exact copy; anything deleted or
# overwritten in R2 is moved to deleted/<date>/ and kept for 30 days.
if [ -n "${R2_BUCKET:-}" ]; then
    export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare
    export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
    export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
    export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
    export RCLONE_CONFIG_B2M_TYPE=s3 RCLONE_CONFIG_B2M_PROVIDER=Other
    export RCLONE_CONFIG_B2M_ENDPOINT="https://${B2_S3_ENDPOINT}"
    export RCLONE_CONFIG_B2M_ACCESS_KEY_ID="$B2_MIRROR_KEY_ID"
    export RCLONE_CONFIG_B2M_SECRET_ACCESS_KEY="$B2_MIRROR_SECRET"
    rclone sync "r2:$R2_BUCKET" "b2m:$B2_MIRROR_BUCKET/current" \
        --backup-dir "b2m:$B2_MIRROR_BUCKET/deleted/$(date +%F)" --fast-list -q
    cutoff=$(date -d '30 days ago' +%F)
    rclone lsf "b2m:$B2_MIRROR_BUCKET/deleted/" --dirs-only 2>/dev/null | \
    while read -r day; do
        day=${day%/}
        if [ "$day" \< "$cutoff" ]; then
            rclone purge "b2m:$B2_MIRROR_BUCKET/deleted/$day" -q
        fi
    done
fi

restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
restic check --read-data-subset=1%
EOF
chmod 755 /usr/local/sbin/mattermost-offsite-backup

cat >/etc/systemd/system/mattermost-backup.service <<'EOF'
[Unit]
Description=Mattermost off-box backup (restic)
Wants=network-online.target
After=network-online.target postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mattermost-offsite-backup
Nice=10
IOSchedulingClass=idle
EOF

cat >/etc/systemd/system/mattermost-backup.timer <<'EOF'
[Unit]
Description=Nightly Mattermost off-box backup

[Timer]
OnCalendar=*-*-* 04:15:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload

echo "Checking repository access"
set -a; . /etc/restic/env; set +a
restic snapshots >/dev/null 2>&1 || restic init

systemctl enable --now mattermost-backup.timer

echo "Running first backup now (may take a while for the initial upload)"
systemctl start mattermost-backup.service

echo
echo "Done. Verify with: restic snapshots   (after sourcing /etc/restic/env)"
echo "REMINDER: store a copy of /etc/restic/repo-password somewhere safe off this"
echo "server — without it these backups cannot be restored."
