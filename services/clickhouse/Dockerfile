# ClickHouse 26.8 LTS for Railway.
#
# Base: the official clickhouse/clickhouse-server image (Ubuntu), pinned by tag
# and digest. Added: openssl (self-signed certificate for the native TLS port)
# and a start script that writes config.d/zz-railway.xml at every boot before
# handing over to the image's /entrypoint.sh.
#
# Upgrade: change the tag/digest to a newer 26.8.x patch release (same LTS).
# Moving to the next LTS (27.3) is the same edit; ClickHouse upgrades the data
# in place, but take a backup first and read the backward-incompatible changes.
FROM clickhouse/clickhouse-server:26.8.45.6@sha256:7a5c190c9cc314f703631bfe7d3ccc03a2e79fddc6ca5310d54fa88dd50e6136

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssl \
 && rm -rf /var/lib/apt/lists/* \
 && clickhouse-server --version | grep -q '26\.8\.'

COPY --chmod=0755 railway-clickhouse-start.sh /usr/local/bin/railway-clickhouse-start
RUN bash -n /usr/local/bin/railway-clickhouse-start

ENTRYPOINT ["/usr/local/bin/railway-clickhouse-start"]
