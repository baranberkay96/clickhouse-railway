# Deploy and Host ClickHouse with Railway

ClickHouse is an open-source column-oriented database for real-time analytics: it scans billions of rows per second and compresses data heavily. This community template runs ClickHouse 26.8 LTS with a password-protected HTTPS endpoint, the native protocol over TLS through a TCP proxy, bounded system logs, and daily backups to a Railway Bucket with ClickHouse's own `BACKUP` command.

## About Hosting ClickHouse

A single ClickHouse server is simple to start but needs care in production: the default user has no password, system log tables grow until the disk is full, caches assume a large machine, the native protocol is unencrypted, and backups need a place to go. This template replaces the default user with a generated admin login, puts TTLs on every system log table, sizes the caches from the service's memory limit, enables the native protocol on port 9440 with a self-signed certificate for outside clients, logs to Railway's log viewer, and runs a nightly `BACKUP ... TO S3` into a Bucket with retention and a tested restore path.

## Common Use Cases

- Product and web analytics (events, sessions, funnels) behind tools such as PostHog-style pipelines, Grafana or Metabase
- Log and observability storage with fast aggregations over months of data
- Real-time dashboards on top of Kafka, HTTP or batch inserts
- Time-series and financial data where columnar compression keeps storage small
- An analytics replica for data copied from Postgres or MySQL

## Dependencies for ClickHouse Hosting

- ClickHouse server 26.8 LTS (included: `clickhouse/clickhouse-server:26.8.45.6`)
- A Railway Bucket for backups (included, created by the template)

### Deployment Dependencies

- ClickHouse documentation: https://clickhouse.com/docs
- Docker image and its variables: https://hub.docker.com/r/clickhouse/clickhouse-server
- Backup and restore: https://clickhouse.com/docs/operations/backup
- Release and LTS policy: https://clickhouse.com/docs/whats-new/changelog
- Railway Storage Buckets: https://docs.railway.com/storage-buckets

### Implementation Details

| Service | Source | Purpose |
|---|---|---|
| ClickHouse | built from this repo (`services/clickhouse`, `FROM clickhouse/clickhouse-server:26.8.45.6`) | Server, volume at `/var/lib/clickhouse`, public HTTPS on 8123, TCP proxy to the TLS native port 9440, healthcheck `/ping` |
| ClickHouse Backup | built from this repo (`services/backup`) | Daily cron (04:00 UTC): `BACKUP ALL EXCEPT DATABASES system ... TO S3(...)`, checked, 14-day retention (at least 3 runs kept) |
| Bucket | Railway Bucket | Private S3 storage for the backups |

**Connecting** (variables on the ClickHouse service; reference them as `${{ClickHouse.NAME}}`):

- `CLICKHOUSE_URL`: HTTP interface on the private network, for apps in this project (clickhouse-js, clickhouse-connect, JDBC over HTTP)
- `CLICKHOUSE_NATIVE_URL`: native protocol on the private network (clickhouse-go, port 9000)
- `CLICKHOUSE_PUBLIC_URL`: HTTPS from anywhere, e.g. `curl -u clickhouse:{password} https://{domain}/?query=SELECT+1`
- `CLICKHOUSE_PUBLIC_NATIVE_URL`: native protocol with TLS through the TCP proxy: `clickhouse client --host {proxy-domain} --port {proxy-port} --secure --accept-invalid-certificate --user clickhouse --password`

**First steps**

1. Open `https://{your-domain}/play`, log in with `CLICKHOUSE_USER` / `CLICKHOUSE_PASSWORD` and run `SELECT version()`.
2. Create a table: `CREATE TABLE railway.events (ts DateTime, user_id UInt64, event LowCardinality(String)) ENGINE = MergeTree ORDER BY (event, ts);`
3. Insert and query it; `https://{your-domain}/dashboard` shows server metrics.
4. Create separate users with `CREATE USER ... IDENTIFIED BY ...` and `GRANT` (the admin has access management enabled).

**Configuration**: the start script writes `config.d/zz-railway.xml` at every boot. System log tables keep `CLICKHOUSE_LOG_RETENTION_DAYS` days (7). Mark and index caches are an eighth and a sixteenth of the memory limit; ClickHouse itself stays under 85% of the limit. Add your own server settings with `CLICKHOUSE_EXTRA_CONFIG_XML` (a complete ClickHouse XML config document with a clickhouse root element); a document that does not parse is dropped with a warning instead of stopping the server. A `CLICKHOUSE_PASSWORD` under 12 characters locks the login with a random password (see the log) rather than leaving the database open.

**Backups and restore**: each run writes a native ClickHouse backup to `clickhouse/{timestamp}/` in the Bucket plus `MANIFEST.txt`. Trigger one with `railway cron run --service "ClickHouse Backup"`. To restore a database, set the backup service's start command to `/usr/local/bin/clickhouse-backup restore`, optionally set `RESTORE_RUN`, `RESTORE_DATABASE` and `RESTORE_TARGET`, run it once and clear the start command again; it restores as `{database}_restored` and never touches an existing database. The ClickHouse server must be able to read the Bucket (it writes and reads the backup itself).

**Scaling**: ClickHouse uses all the CPU and memory you give it; raise the service limits for heavier queries, merges and inserts, and grow the volume (5 GB on Hobby, 50 GB+ on Pro). Batch inserts (thousands of rows per insert) or `async_insert=1` keep merges cheap.

**Versions and upgrades**: pinned to 26.8.45.6 (26.8 is an LTS release with a year of fixes). For patch releases, change the tag and digest in `services/clickhouse/Dockerfile`; for the next LTS, take a backup and read the changelog first.

### Why Deploy ClickHouse on Railway?

Railway gives ClickHouse a persistent volume, an HTTPS endpoint, a TCP proxy and a managed bucket in one project, so a secured analytics database with backups is running in minutes. Apps in the same project connect over the private network by reference, and you scale by raising the service limits rather than running servers.
