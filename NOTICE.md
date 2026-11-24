# NOTICE

This Railway template is a community package. It is not affiliated with or endorsed by ClickHouse, Inc. or Railway. ClickHouse is a registered trademark of ClickHouse, Inc.

## What this template runs

| Component | Source | License |
|---|---|---|
| ClickHouse 26.8.45.6 (LTS) | official image `clickhouse/clickhouse-server:26.8.45.6` (digest `sha256:7a5c190c…`), https://github.com/ClickHouse/ClickHouse; its `/entrypoint.sh` and `docker_related_config.xml` are used unmodified | Apache-2.0 |
| Ubuntu package added at build time | `openssl` | Apache-2.0 |
| Backup image | `alpine:3.24.2` + `bash`, `coreutils`, `ca-certificates`, `curl`; rclone 1.76.0 from `rclone/rclone:1.76.0` | per package; rclone MIT |

## Files written for this template

- `services/clickhouse/Dockerfile`, `railway-clickhouse-start.sh` (writes `config.d/zz-railway.xml` at every boot: TLS native port, console logging, system log TTLs, memory-scaled caches; fail-closed password handling).
- `services/backup/Dockerfile`, `clickhouse-backup.sh` (uses ClickHouse's `BACKUP`/`RESTORE ... S3`; retention logic adapted from our own `56-pgvector` backup job).
- `TEMPLATE.md`, `README.md`, `template.json`, this file.

## Reused or not reused

- The marketplace templates in `../_market/` (`clickhouse`, `clickhouse-1`, `clickhouse-cluster` → `railwayapp-templates/clickhouse-cluster`) were read for settings only (public HTTP domain on 8123, `/ping` healthcheck, system log retention idea). No files or text were copied.

## Upstream material checked (2026-11-24)

- `ClickHouse/ClickHouse` at `v26.8.45.6-lts`: `programs/server/config.xml` (which system log tables are enabled by default), `docker/server/entrypoint.sh` (`CLICKHOUSE_USER`/`PASSWORD`/`DB`/`DEFAULT_ACCESS_MANAGEMENT`, default user removal), `docker/server/docker_related_config.xml` (listens on `::` and `0.0.0.0`).
- ClickHouse docs: backup and restore to S3 (`BACKUP ... TO S3(url, key, secret) ASYNC`, `system.backups`), TLS (`tcp_port_secure`, `openSSL.server`).
