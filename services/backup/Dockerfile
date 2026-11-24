# ClickHouse Backup (Railway cron job): sends BACKUP/RESTORE ... S3 statements to
# ClickHouse over HTTP (curl) and manages retention in the Bucket (rclone).
FROM rclone/rclone:1.76.0@sha256:7cbeec24a44f206067597c0368be4de90ae19a64d5113c7d1938bd737a81e466 AS rclone

FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

RUN apk add --no-cache bash coreutils ca-certificates curl \
 && addgroup -S backup \
 && adduser -S -D -H -h /tmp -G backup backup

COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone
COPY --chmod=0755 clickhouse-backup.sh /usr/local/bin/clickhouse-backup

ENV HOME=/tmp

RUN rclone version >/dev/null \
 && curl --version >/dev/null \
 && date -u -d @0 +%Y >/dev/null \
 && bash -n /usr/local/bin/clickhouse-backup

USER backup
WORKDIR /tmp

ENTRYPOINT ["/usr/local/bin/clickhouse-backup"]
CMD ["backup"]
