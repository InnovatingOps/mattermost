# Cutover checklist

Migrating from the **old production box** (~v11.4, local HDD file storage) to the
**new box** (`207.246.118.59`, v11.7.2 from CI, R2 file storage). Work top to
bottom — each phase gates the next.

---

## Phase 0 — Validate on the test box (no downtime, do now)

### 0.1 — DB migration rehearsal *(highest risk — do this first)*
The new box runs v11.7.2; the real data is from ~v11.4. Prove the one-way
schema migration succeeds and is fast **before** the live window.

- [ ] On the **old box**, take a fresh dump — `--no-owner --no-privileges` is
      required, else the restore fails on the old DB's role (e.g. `source`):
      `pg_dump --no-owner --no-privileges --dbname="$DSN" | gzip > /root/prod-rehearsal.sql.gz`
- [ ] Copy it to the test box
- [ ] On the **test box**, load it into a scratch DB. The `SET SESSION AUTHORIZATION`
      makes `mmuser` own the tables (so its migrations can alter them) — no password needed:
      `sudo -u postgres createdb mm_rehearsal -O mmuser`
      `(echo "SET SESSION AUTHORIZATION mmuser;"; zcat prod-rehearsal.sql.gz) | sudo -u postgres psql -q -d mm_rehearsal`
- [ ] Point a throwaway Mattermost config at `mm_rehearsal`, start it, and
      **watch the migration run** — note how long it takes
- [ ] Confirm healthy (`/api/v4/system/ping`) and spot-check that real channels,
      posts, and users render
- [ ] Tear down: `sudo -u postgres dropdb mm_rehearsal`
- [ ] ✅ Migration time is acceptable and no errors → cutover DB step is safe

### 0.2 — Prove R2 file storage works end-to-end
- [ ] System Console → File Storage → **Test Connection** passes
- [ ] Upload a **document** → confirm it appears in the R2 bucket
- [ ] Upload an **image** → confirm thumbnail + preview render in the client
- [ ] Restart Mattermost, reopen the image → still served (reading from R2, not cache)
- [ ] Let the **nightly B2 mirror run once** (or trigger `mattermost-offsite-backup`)
      → confirm `current/` populates in the B2 mirror bucket

### 0.3 — Confirm CD ships product-code changes
- [ ] Make a small visual change in the web client (`webapp/`)
- [ ] Update the *"No product code is modified yet"* line in `FORK.md`
- [ ] Commit + push to `production`
- [ ] Watch the deploy land (~15 min) and **verify the change is live** on
      `chat-test.sourcetemple.one`

### 0.4 — Documentation consolidated
- [ ] Push the pending local doc commits (restore procedure, R2 mirror, R2 file storage)
- [ ] FORK.md covers: provisioning · backup creation · backup restore · this cutover

---

## Phase 1 — Prep (a few days before the window)

- [ ] **Lower the production domain's DNS A-record TTL** to 60–300s so the switch
      propagates fast (and rollback is quick)
- [ ] First `rclone copy` pass: bulk-copy the **old box's** `data/` (~80 GB) into
      the R2 bucket while users keep working
      `rclone copy <old data dir> r2:continuum-mattermost-data --transfers 16 --fast-list --progress`
- [ ] Read through Phase 2 once, end to end, with the actual hostnames filled in
- [ ] Pick a quiet maintenance window and notify users

---

## Phase 2 — Cutover window (the runbook)

- [ ] **Final backup of the old box** (DB dump + confirm a restic snapshot exists)
- [ ] **Stop the old Mattermost** (`systemctl stop mattermost`) — begins downtime
- [ ] **Final DB dump** from old box (`pg_dump --no-owner --no-privileges`) →
      **restore** onto the new box's `mattermost` DB the same way as the
      Phase 0.1 rehearsal (`SET SESSION AUTHORIZATION mmuser` so `mmuser` owns the tables)
- [ ] **Second `rclone copy` pass** (same command as Phase 1) — only the files
      uploaded since the first pass; finishes in seconds
- [ ] On the new box, switch to the real domain:
  - [ ] `SiteURL` → real domain (System Console or config.json)
  - [ ] nginx `server_name` → real domain
  - [ ] Issue the real-domain Let's Encrypt cert
- [ ] **Switch DNS** A-record → `207.246.118.59`
- [ ] Start Mattermost on the new box; confirm migration ran clean + healthy
- [ ] **Smoke test:** log in, post a message, upload a file, view an old image,
      check a notification

---

## Phase 3 — After cutover

- [ ] Watch the new box for the first hours (logs, webhook deploy pings, backups run)
- [ ] Confirm the **nightly B2 mirror** of R2 runs against real data
- [ ] Keep the **old box untouched** as a fallback for a week, then decommission
- [ ] Restore the production DNS TTL to its normal value

---

## Rollback (if the new box misbehaves after DNS switch)

The old box is untouched and the DNS TTL is low, so reverting is fast:

1. Switch the DNS A-record back to the old box's IP
2. `systemctl start mattermost` on the old box
3. Service resumes on the old box within one TTL window

> Caveat: any messages/files created on the **new** box after cutover won't exist
> on the old one. Roll back quickly (within minutes) if at all — the longer the
> new box serves traffic, the more divergence a rollback would lose.
