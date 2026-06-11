#!/usr/bin/env bash
# Deploys a Mattermost dist tarball on this host. Invoked over SSH by the
# build-deploy workflow; can also be run by hand.
#
# Usage: deploy.sh <tarball> <release-name>
#
# Layout it maintains:
#   /opt/mattermost                  -> symlink to the current release
#   /opt/mattermost-releases/<name>     extracted releases (rollback targets)
#   /opt/mattermost-shared/             config, data, logs, plugins, client-plugins
#   /opt/mattermost-backups/            pre-deploy pg_dump archives
#
# On first run against a plain /opt/mattermost directory install, it migrates
# to this layout automatically (the old install becomes release "initial").
# Rollback: ln -sfn /opt/mattermost-releases/<old> /opt/mattermost && systemctl
# restart mattermost — but remember DB migrations are one-way; restore the
# matching dump from /opt/mattermost-backups when rolling back across versions.
set -euo pipefail

TARBALL=${1:?usage: deploy.sh <tarball> <release-name>}
NAME=${2:?usage: deploy.sh <tarball> <release-name>}

ROOT=/opt/mattermost
RELEASES=/opt/mattermost-releases
SHARED=/opt/mattermost-shared
BACKUPS=/opt/mattermost-backups
KEEP=5

log() { echo "[deploy] $*"; }
fail() { echo "[deploy] ERROR: $*" >&2; exit 1; }

for cmd in jq pg_dump curl tar systemctl; do
    command -v "$cmd" >/dev/null || fail "$cmd not found (apt install jq postgresql-client curl)"
done
[ -f "$TARBALL" ] || fail "tarball not found: $TARBALL"
[ -e "$ROOT" ] || fail "$ROOT does not exist; is Mattermost installed here?"

CONFIG="$ROOT/config/config.json"
DSN=$(jq -r '.SqlSettings.DataSource' "$CONFIG")
LISTEN=$(jq -r '.ServiceSettings.ListenAddress' "$CONFIG")
PORT=${LISTEN##*:}
PORT=${PORT:-8065}
SVC_USER=$(systemctl show mattermost -p User --value)
SVC_USER=${SVC_USER:-root}

# --- Database backup (before touching anything) ---
mkdir -p "$BACKUPS"
log "Backing up database to $BACKUPS/pre-$NAME.sql.gz"
pg_dump --dbname="$DSN" | gzip >"$BACKUPS/pre-$NAME.sql.gz"

# --- One-time migration from a plain directory install ---
if [ ! -L "$ROOT" ]; then
    log "Plain install detected; converting to symlinked release layout"
    systemctl stop mattermost
    mkdir -p "$RELEASES" "$SHARED"
    mv "$ROOT" "$RELEASES/initial"
    for d in config data logs plugins; do
        mv "$RELEASES/initial/$d" "$SHARED/$d"
        ln -s "$SHARED/$d" "$RELEASES/initial/$d"
    done
    mv "$RELEASES/initial/client/plugins" "$SHARED/client-plugins"
    ln -s "$SHARED/client-plugins" "$RELEASES/initial/client/plugins"
    ln -s "$RELEASES/initial" "$ROOT"
    log "Old install preserved as release 'initial'"
fi

# --- Extract the new release and wire it to the shared dirs ---
DEST="$RELEASES/$NAME"
log "Extracting to $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf "$TARBALL" -C "$DEST" --strip-components=1
rm -rf "$DEST/config" "$DEST/data" "$DEST/logs" "$DEST/plugins" "$DEST/client/plugins"
ln -s "$SHARED/config" "$DEST/config"
ln -s "$SHARED/data" "$DEST/data"
ln -s "$SHARED/logs" "$DEST/logs"
ln -s "$SHARED/plugins" "$DEST/plugins"
ln -s "$SHARED/client-plugins" "$DEST/client/plugins"
chown -R "$SVC_USER:" "$DEST"

# --- Switch over ---
log "Switching $ROOT to $NAME and restarting"
systemctl stop mattermost
ln -sfn "$DEST" "$ROOT"
systemctl start mattermost

log "Waiting for health check on port $PORT (migrations may take a while)"
healthy=
for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null "http://127.0.0.1:$PORT/api/v4/system/ping"; then
        healthy=1
        break
    fi
    sleep 5
done
if [ -z "$healthy" ]; then
    log "Health check FAILED after 5 minutes; recent service log:"
    journalctl -u mattermost -n 50 --no-pager || true
    fail "deploy of $NAME did not become healthy; symlink still points at $NAME"
fi

# --- Prune old releases and backups (never the active release) ---
current=$(basename "$(readlink -f "$ROOT")")
cd "$RELEASES"
for old in $(ls -1t | tail -n +$((KEEP + 1))); do
    [ "$old" = "$current" ] && continue
    log "Pruning old release $old"
    rm -rf "${RELEASES:?}/$old"
done
cd "$BACKUPS"
ls -1t | tail -n +$((KEEP + 1)) | while read -r old; do
    log "Pruning old backup $old"
    rm -f "${BACKUPS:?}/$old"
done

rm -f "$TARBALL"
log "Deployed $NAME successfully"
