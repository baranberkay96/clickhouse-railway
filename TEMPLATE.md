# ClickHouse 26.8 LTS: Railway template spec

## Listing

| Field | Value |
|---|---|
| Name | **ClickHouse 26.8 LTS** (19 chars) |
| Description | Real-time analytics database with HTTPS, TLS native port and backups. (69 chars) |
| Category | Storage |
| Tags | clickhouse, olap, analytics, columnar, database, sql, backups, lts |
| Icon | `https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/clickhouse.svg` (200, image/svg+xml) |

## Base market templates

| Market template | Topology | Kept | Problems fixed |
|---|---|---|---|
| `clickhouse` (126 active) | `clickhouse/clickhouse-server:25.8`, public domain on 8123, `/ping` healthcheck, system-log config through a variable | Public HTTPS on 8123, `/ping`, log retention idea, URL variables | 25.8 (previous LTS), no TCP access for native clients, no backups, logs to files only |
| `clickhouse-1` (6 active) | `clickhouse/clickhouse-server:26.8` | Current LTS line | Floating minor tag, no backups |
| `clickhouse-cluster` (8 active) | 3 keepers + 6 servers + HAProxy | | Out of scope: single-node template; clusters need Keeper and are a different product |

### Improvements over market templates

1. ClickHouse 26.8.45.6 (current LTS patch) pinned by digest.
2. Native protocol over TLS on 9440 through the TCP proxy (self-signed certificate in the volume, renewed within 30 days of expiry), so `clickhouse client --secure` and native drivers work from outside without sending passwords in clear text.
3. TTLs on every system log table the 26.8 default config enables (`CLICKHOUSE_LOG_RETENTION_DAYS`, 7 days), caches sized from the memory limit, server stays under 85% of the limit.
4. Server log to stdout (Railway log viewer), files removed.
5. Fail-closed admin password (under 12 characters → random lock; 8.29); `CLICKHOUSE_SKIP_USER_SETUP` refused.
6. Nightly `BACKUP ALL EXCEPT DATABASES system ... TO S3` into a Railway Bucket (path-style URL, verified to work with Railway Buckets), status checked in `system.backups`, `.backup` file checked, retention, and a restore-as-new-database command.
7. Listens on `::` and `0.0.0.0` (image default kept), nothing resolves the service's own private name at boot (8.13/8.14).

## Pinned versions (checked 2026-11-24)

| Service | Image / build | Version |
|---|---|---|
| ClickHouse | repo `services/clickhouse`, `FROM clickhouse/clickhouse-server:26.8.45.6@sha256:7a5c190c…` + `openssl` | ClickHouse 26.8.45.6 LTS |
| ClickHouse Backup | repo `services/backup`, `alpine:3.24.2` + curl + rclone 1.76.0 | |

## Services

- **ClickHouse**: entrypoint `railway-clickhouse-start` → `/entrypoint.sh`. Volume `/var/lib/clickhouse`, public domain → 8123, TCP proxy → 9440, healthcheck `/ping` (300 s), restart ON_FAILURE ×10, draining 60 s.
- **ClickHouse Backup**: cron `0 4 * * *`, restart NEVER; `backup` (default), `list`, `restore` (start command `/usr/local/bin/clickhouse-backup restore`).

## Resources and cost

| Service | Idle RAM | Typical |
|---|---|---|
| ClickHouse | 0.75 GB after a restart, 1.0–1.3 GB after loading 1M rows (measured) | 1–4 GB depending on queries and merges |
| ClickHouse Backup | 0 | |

**Hobby recommended**: idle use is close to the 1 GB Trial cap. About $8–12/month idle at Railway prices plus volume and bucket storage.

## Verification checklist

- [x] Both services SUCCESS; `/ping` healthcheck passed; listeners on `[::]` for 8123, 9000, 9440.
- [x] HTTPS without credentials → 401; with the generated login: `SELECT version()` = 26.8.45.6; `/play`, `/dashboard`, `/ping` 200.
- [x] Native TLS through the TCP proxy: TLSv1.3 handshake on 9440.
- [x] MergeTree table, 1,000,000 rows inserted over HTTPS, `GROUP BY` with `uniqExact`.
- [x] Cache sizes and `max_server_memory_usage_to_ram_ratio` applied; system log tables have TTLs.
- [x] Backup cron run: `BACKUP_CREATED`, 20 files / 4.5 MB in the Bucket, MANIFEST, retention.
- [x] Restore run: `railway_restored.events` with 1,000,000 rows.
- [x] `CLICKHOUSE_PASSWORD=short`: deploy SUCCESS, login locked (403), log explains; restoring the password unlocked it; data persisted across redeploys.
- [x] First test deploy failed: `<ttl>` on `opentelemetry_span_log` (its default config sets `<engine>`) stops the server; removed. `CLICKHOUSE_DB` is now created on every boot because the image only creates it while initialising an empty data directory.

## Open questions

- Backups go through ClickHouse's S3 client with a path-style URL; if a future Railway Bucket refuses path-style requests, BACKUP fails (the job then fails loudly and keeps old backups).
