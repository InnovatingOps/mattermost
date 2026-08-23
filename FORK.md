# About this fork

This is InnovatingOps' fork of [mattermost/mattermost](https://github.com/mattermost/mattermost).
Its purpose is to run a self-hosted Mattermost (Team Edition, built from this
source) with custom aesthetics on top of a stable upstream release, with
automated upstream syncing and push-to-deploy CD. **No product code is modified
yet** — everything the fork adds is listed below.

## Branch model

| Branch | Role |
|---|---|
| `master` | Untouched mirror of upstream `master`. Never commit here. |
| `production` | Default branch. Based on an upstream Extended Support Release (ESR) tag plus everything in this document. All custom work (aesthetics, features) goes here, directly or via PRs. Every push deploys. |

## Files added on top of upstream

### `UPSTREAM_TRACK`
Declares which upstream release line we follow (`LINE`) and its end-of-life
date (`EOL`). We track ESR lines: upstream ships a new ESR every February and
August, each supported ~12 months with security backports. Bumping to the next
ESR is a deliberate one-line edit of this file (upgrades run one-way DB
migrations, so it should never be fully automatic).

### `.github/workflows/upstream-sync.yml`
Scheduled every Saturday 06:00 UTC (also manually triggerable). It:
1. Fetches upstream tags and finds the newest patch release on the tracked line.
2. If it's newer than what `production` contains, merges it on a `sync/vX.Y.Z`
   branch and opens a PR — merging that PR is the upgrade-and-deploy button.
   On merge conflict it opens an issue instead.
3. Opens a warning issue when the tracked line is within 45 days of EOL.
4. Posts to the Mattermost webhook (secret `MATTERMOST_WEBHOOK_URL`) whenever
   any of the above happened.

Secrets: `MATTERMOST_WEBHOOK_URL` (optional) and `SYNC_TOKEN` (**required in
practice**). GitHub refuses any push from the built-in `GITHUB_TOKEN` that
creates or updates files under `.github/workflows/**`, and upstream releases
touch those files routinely — so without `SYNC_TOKEN` the sync silently stops
working the first time a release includes a workflow change (it did, at
v11.7.7; v11.7.9 had to be merged by hand). `SYNC_TOKEN` is a fine-grained or
classic PAT with the `workflow` scope plus write access to this repo. The same
restriction applies locally: push workflow changes over the SSH remote, since
the `gh` OAuth token lacks `workflow`.

### `.github/workflows/build-deploy.yml`
Runs on every push to `production`:
1. **build** — builds the Team Edition `mattermost-team-linux-amd64.tar.gz`
   using upstream's own recipe (`mattermost/mattermost-build-server` container,
   `make build-cmd && make package-linux-amd64`), uploads it as the `dist`
   artifact (~390 MB, kept 7 days). Takes ~10–15 minutes.
2. **deploy** — runs under the `production` GitHub Environment and streams the
   tarball over SSH to the restricted `deploy` user on the production host:
   `ssh deploy@$DEPLOY_HOST "$RELEASE" < tarball`. Skips gracefully (still
   green) when the `DEPLOY_*` secrets are absent. Posts the outcome to the
   Mattermost webhook. Deploys never run concurrently.

Secrets (in the `production` environment): `DEPLOY_HOST`, `DEPLOY_SSH_KEY`
(required), `DEPLOY_USER` (default `deploy`), `DEPLOY_PORT` (default 22),
`MATTERMOST_WEBHOOK_URL` (optional, repo-level, shared with the sync workflow).

### `deploy/deploy.sh`
The upgrade procedure that runs (as root) on the server. Maintains:

```
/opt/mattermost                  -> symlink to the current release
/opt/mattermost-releases/<name>     extracted releases (rollback targets, 5 kept)
/opt/mattermost-shared/             config, data, logs, plugins, client-plugins
/opt/mattermost-backups/            pre-deploy pg_dump archives (5 kept)
```

Each deploy: pg_dump backup → extract → symlink shared dirs in → stop service →
flip `/opt/mattermost` symlink → start → health-check `/api/v4/system/ping`
(up to 5 min) → prune. On first contact with a plain directory install it
migrates it to this layout automatically (old install becomes release
`initial`).

**Rollback:** `ln -sfn /opt/mattermost-releases/<previous> /opt/mattermost &&
systemctl restart mattermost`. DB migrations are one-way — when rolling back
across versions, also restore the matching dump from `/opt/mattermost-backups`.

**Note:** the copy that actually runs is pinned on the server at
`/usr/local/sbin/mattermost-deploy.sh` (see `server-setup.sh`). Editing
`deploy/deploy.sh` in git does **not** change production behavior until
`server-setup.sh` is re-run on the host — a deliberate security property.

### `deploy/provision.sh`
One-shot, idempotent provisioning of a fresh Debian 13 host:
system upgrade + unattended security updates, key-only sshd, ufw (22/80/443),
2 GB swap if RAM < 4 GB, PostgreSQL with generated credentials (kept in
`/root/.mattermost-db-pass`), seeds `/opt/mattermost` from a CI-built tarball
(runs as the unprivileged `mattermost` user, systemd unit included), nginx
reverse proxy with WebSocket support, Let's Encrypt via webroot (the TLS
server block is written by the script, not by certbot's installer), and a
nightly local pg_dump rotating over 7 days. Safe to re-run after partial
failures.

```
bash provision.sh --domain chat.example.com --tarball mattermost-team-linux-amd64.tar.gz --email admin@example.com
```

### `deploy/backup-setup.sh`
Sets up nightly encrypted off-box backups with restic + a systemd timer
(04:15). Each run backs up a fresh `pg_dump`, `/opt/mattermost-shared/data`
and `/opt/mattermost-shared/config`, applies 7-daily/4-weekly/6-monthly
retention, spot-checks 1% of repository data, and notifies the Mattermost
webhook on failure. Backend is any S3-compatible bucket configured in
`/etc/restic/env` (Backblaze B2 recommended). Run once to get the config
template, fill it in, run again to initialize and enable. **The encryption
key `/etc/restic/repo-password` must be copied somewhere safe off the server.**

When file uploads live in Cloudflare R2 (see "File storage" below), the same
nightly run also mirrors the live R2 bucket to a second B2 bucket with rclone:
`current/` is an exact copy, and anything deleted or overwritten in R2 is
retained 30 days under `deleted/<date>/`. Enabled by filling the `R2_*` /
`B2_MIRROR_*` block in `/etc/restic/env` and re-running `backup-setup.sh`.

#### Restoring from backup

Every restic command needs the repo credentials in the environment first:

```
set -a; . /etc/restic/env; set +a
restic snapshots          # each backup run leaves two: tag `db` and tag `files`
```

Restore files (uploads + config) and the database dump:

```
restic restore latest --tag files --target /tmp/restore
restic dump latest --tag db /mattermost.sql > /tmp/restore/mattermost.sql
```

The files land under `/tmp/restore/opt/mattermost-shared/...`; copy what you
need back into place (`chown -R mattermost:mattermost` after). To load the
database, stop Mattermost first, then:

```
sudo -u postgres dropdb mattermost && sudo -u postgres createdb mattermost -O mmuser
sudo -u postgres psql -q -d mattermost -f /tmp/restore/mattermost.sql
```

**Total server loss:** provision a fresh box (`provision.sh` + `server-setup.sh`
below), recreate `/etc/restic/env` with the bucket credentials and the saved
repo password, then restore as above and switch DNS. Nothing on the old box is
needed — which is the point.

**Restore drill** (verified 2026-06-12 — repeat occasionally, it's
non-destructive): restore files to `/tmp/restore-test` and `diff -r` against
the live `data/` dir; load the SQL dump into a scratch DB
(`createdb restore_drill -O mmuser`), sanity-check row counts in `users` /
`posts` / `channels`, then `dropdb restore_drill` and remove `/tmp/restore-test`.

### `deploy/server-setup.sh`
One-time hardening of the deploy entry point on the host. Creates the `deploy`
user whose SSH key is locked in `authorized_keys` with
`restrict,command="/usr/local/sbin/mattermost-deploy"`: no shell, no scp, no
forwarding — the key can only stream a tarball to the pinned deploy script
(invoked through a single-command sudoers rule). Re-run it to refresh the
pinned copy of `deploy.sh` from the `production` branch.

## File storage (Cloudflare R2)

File uploads are stored in a Cloudflare R2 bucket via Mattermost's native S3
driver, not on local disk — `/opt/mattermost-shared/data` is only a legacy
location. Configured in System Console → Environment → File Storage (lands in
`FileSettings` of `config.json`, which restic backs up):

| Setting | Value |
|---|---|
| File Storage System | Amazon S3 |
| Amazon S3 Bucket | the R2 bucket name |
| Amazon S3 Region | `auto` |
| Amazon S3 Endpoint | `<ACCOUNT_ID>.r2.cloudflarestorage.com` |
| Access Key / Secret | from an R2 API token scoped to that bucket (Object Read & Write) |
| Enable Secure Connections | true |

Rationale: object storage is ~$1.35/month per 100 GB (vs $18/month minimum for
Vultr Object Storage or slow HDD block storage), R2 egress is free, and the
server's NVMe stays reserved for Postgres. Users never talk to R2 — Mattermost
proxies all file traffic. Backup: nightly rclone mirror to B2 (see
`backup-setup.sh` above). Migrating an existing local `data/` dir into the
bucket is a plain `rclone copy` — the on-disk layout maps 1:1 to S3 keys.

## Day-to-day operations

- **Deploy a change:** commit to `production` (or merge a PR into it) and push.
  Live in ~15 minutes.
- **Upstream security patch:** merge the PR the Saturday sync opens.
- **Move to the next ESR:** edit `LINE`/`EOL` in `UPSTREAM_TRACK` when the EOL
  warning issue appears; the next sync run merges the new line.
- **Update deploy logic on the server:** edit `deploy/deploy.sh`, push, then
  re-run `server-setup.sh` on the host (root).
- **Rebuild/replace the server:** `provision.sh` + `server-setup.sh` on a fresh
  box, point `DEPLOY_HOST` at it.
