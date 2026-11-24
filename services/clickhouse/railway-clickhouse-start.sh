#!/bin/bash
# railway-clickhouse-start: prepares ClickHouse for Railway, then execs the image's
# /entrypoint.sh (which creates CLICKHOUSE_USER / CLICKHOUSE_DB and drops to the
# clickhouse user). Runs as root.
#
#   - config.d/zz-railway.xml, rewritten at every boot:
#       * the image's docker_related_config.xml already listens on :: and 0.0.0.0
#         (STANDARD 8.14); nothing here resolves the service's own private name
#         at boot (8.13)
#       * native protocol with TLS on 9440 (the TCP proxy target) using a
#         self-signed certificate kept in the volume
#       * TTLs on the system log tables (CLICKHOUSE_LOG_RETENTION_DAYS) so they
#         cannot fill the volume
#       * cache sizes scaled to the service's memory limit
#   - a too-short CLICKHOUSE_PASSWORD never leaves the database open: the login
#     is locked with a random password and the log says how to fix it (8.29).
set -uo pipefail
export LC_ALL=C

CONF=/etc/clickhouse-server/config.d/zz-railway.xml
DATA=/var/lib/clickhouse
TLS="$DATA/railway-tls"

log() { printf 'railway-clickhouse: %s\n' "$*"; }
is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
clamp() { local v=$1; [ "$v" -lt "$2" ] && v=$2; [ "$v" -gt "$3" ] && v=$3; echo "$v"; }

# --- login ----------------------------------------------------------------------
if [ "${CLICKHOUSE_SKIP_USER_SETUP:-0}" = 1 ]; then
  log "WARNING: CLICKHOUSE_SKIP_USER_SETUP=1 is ignored on Railway; the public HTTPS endpoint must not run without a password"
  export CLICKHOUSE_SKIP_USER_SETUP=0
fi
if ! [[ "${CLICKHOUSE_USER:-}" =~ ^[A-Za-z_][A-Za-z0-9_]{0,63}$ ]] || [ "${CLICKHOUSE_USER:-}" = default ]; then
  log "WARNING: CLICKHOUSE_USER='${CLICKHOUSE_USER:-}' must be a plain name other than 'default'; using 'clickhouse'"
  export CLICKHOUSE_USER=clickhouse
fi
if [ "${#CLICKHOUSE_PASSWORD}" -lt 12 ] 2>/dev/null || [ -z "${CLICKHOUSE_PASSWORD:-}" ]; then
  log "WARNING: CLICKHOUSE_PASSWORD is shorter than 12 characters; the login '${CLICKHOUSE_USER}' is LOCKED with a random password."
  log "Set CLICKHOUSE_PASSWORD on the ClickHouse service to 12+ characters and redeploy to unlock it."
  CLICKHOUSE_PASSWORD=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)
  export CLICKHOUSE_PASSWORD
fi
if [ -n "${CLICKHOUSE_DB:-}" ] && ! [[ "$CLICKHOUSE_DB" =~ ^[A-Za-z_][A-Za-z0-9_]{0,63}$ ]]; then
  log "WARNING: CLICKHOUSE_DB='${CLICKHOUSE_DB}' is not a plain name; using 'railway'"
  export CLICKHOUSE_DB=railway
fi
export CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT="${CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT:-1}"
case "$CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT" in 0 | 1) ;; *) export CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 ;; esac

# --- memory-scaled caches -----------------------------------------------------------
raw=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
host=$(awk '/^MemTotal:/ { printf "%d", $2 / 1024; exit }' /proc/meminfo 2>/dev/null)
if is_uint "$raw"; then MEM=$((raw / 1048576)); else MEM=${host:-4096}; fi
if is_uint "$host" && [ "$host" -gt 0 ] && [ "$host" -lt "$MEM" ]; then MEM=$host; fi
MARK=$(clamp $((MEM / 8)) 128 5120)
INDEX=$(clamp $((MEM / 16)) 64 5120)
UNCOMPRESSED=$(clamp $((MEM / 16)) 64 8192)
MERGE_POOL=$(clamp $(($(nproc 2>/dev/null || echo 2) * 2)) 4 16)
if [ "$MEM" -lt 2048 ]; then MERGE_POOL=4; fi
log "memory limit ${MEM} MB: mark cache ${MARK} MB, index caches ${INDEX} MB, background pool ${MERGE_POOL}"

LOG_LEVEL=${CLICKHOUSE_LOG_LEVEL:-information}
case "$LOG_LEVEL" in
  none | fatal | critical | error | warning | notice | information | debug | trace) ;;
  *) log "WARNING: CLICKHOUSE_LOG_LEVEL='${LOG_LEVEL}' is not a ClickHouse log level; using information"; LOG_LEVEL=information ;;
esac

DAYS=${CLICKHOUSE_LOG_RETENTION_DAYS:-7}
if ! is_uint "$DAYS" || [ "$DAYS" -lt 1 ]; then
  log "WARNING: CLICKHOUSE_LOG_RETENTION_DAYS='${DAYS}' is not a whole number >= 1; using 7"
  DAYS=7
fi

# --- TLS for the native protocol (TCP proxy) ----------------------------------------
CERT_DAYS=${SSL_CERT_DAYS:-820}
is_uint "$CERT_DAYS" && [ "$CERT_DAYS" -ge 30 ] || CERT_DAYS=820
install -d -m 0750 "$TLS"
if ! openssl x509 -checkend 2592000 -noout -in "$TLS/server.crt" >/dev/null 2>&1 || [ ! -s "$TLS/server.key" ]; then
  log "creating a self-signed TLS certificate for the native protocol (port 9440), valid ${CERT_DAYS} days"
  openssl req -new -x509 -nodes -days "$CERT_DAYS" -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -subj "/CN=${RAILWAY_PRIVATE_DOMAIN:-clickhouse}" -keyout "$TLS/server.key" -out "$TLS/server.crt" >/dev/null 2>&1 \
    || log "WARNING: could not create the certificate"
fi
chown -R clickhouse:clickhouse "$TLS" 2>/dev/null
chmod 0600 "$TLS/server.key" 2>/dev/null
SECURE_TCP=""
if [ -s "$TLS/server.crt" ] && [ -s "$TLS/server.key" ]; then
  SECURE_TCP="<tcp_port_secure>9440</tcp_port_secure>
    <openSSL>
        <server>
            <certificateFile>$TLS/server.crt</certificateFile>
            <privateKeyFile>$TLS/server.key</privateKeyFile>
            <verificationMode>none</verificationMode>
            <loadDefaultCAFile>false</loadDefaultCAFile>
            <cacheSessions>true</cacheSessions>
            <disableProtocols>sslv2,sslv3,tlsv1,tlsv1_1</disableProtocols>
            <preferServerCiphers>true</preferServerCiphers>
        </server>
    </openSSL>"
fi

ttl() { printf '    <%s>\n        <ttl>event_date + INTERVAL %s DAY DELETE</ttl>\n    </%s>\n' "$1" "$DAYS" "$1"; }

{
  cat <<EOF
<!-- Written by railway-clickhouse at every boot; edit the variables, not this file.
     Extra settings: add a file to config.d through CLICKHOUSE_EXTRA_CONFIG_XML. -->
<clickhouse>
    <http_port>8123</http_port>
    <tcp_port>9000</tcp_port>
    $SECURE_TCP
    <display_name>${RAILWAY_SERVICE_NAME:-clickhouse}</display_name>
    <!-- Server log to the Railway log (stdout), not to files in the container. -->
    <logger>
        <level>${LOG_LEVEL}</level>
        <console>1</console>
        <log remove="remove"/>
        <errorlog remove="remove"/>
    </logger>
    <mark_cache_size>$((MARK * 1048576))</mark_cache_size>
    <index_mark_cache_size>$((INDEX * 1048576))</index_mark_cache_size>
    <index_uncompressed_cache_size>$((INDEX * 1048576))</index_uncompressed_cache_size>
    <uncompressed_cache_size>$((UNCOMPRESSED * 1048576))</uncompressed_cache_size>
    <background_pool_size>${MERGE_POOL}</background_pool_size>
    <max_server_memory_usage_to_ram_ratio>0.85</max_server_memory_usage_to_ram_ratio>
EOF
  # Only tables the 26.8 default config enables (naming another one would enable it);
  # opentelemetry_span_log is left out: its default config sets an engine, which forbids <ttl>.
  for table in query_log query_thread_log query_views_log part_log trace_log text_log metric_log \
    asynchronous_metric_log error_log query_metric_log processors_profile_log \
    asynchronous_insert_log backup_log s3queue_log blob_storage_log background_schedule_pool_log; do
    ttl "$table"
  done
  echo "</clickhouse>"
} > "$CONF"
chmod 0644 "$CONF"

if [ -n "${CLICKHOUSE_EXTRA_CONFIG_XML:-}" ]; then
  printf '%s\n' "$CLICKHOUSE_EXTRA_CONFIG_XML" > /etc/clickhouse-server/config.d/zz-zz-extra.xml
  log "CLICKHOUSE_EXTRA_CONFIG_XML written to config.d/zz-zz-extra.xml"
else
  rm -f /etc/clickhouse-server/config.d/zz-zz-extra.xml
fi

if ! clickhouse extract-from-config --config-file /etc/clickhouse-server/config.xml --key=http_port >/dev/null 2>&1; then
  log "WARNING: the merged configuration does not parse; removing CLICKHOUSE_EXTRA_CONFIG_XML's file and retrying"
  rm -f /etc/clickhouse-server/config.d/zz-zz-extra.xml
fi

log "system log tables keep ${DAYS} days; native TLS port 9440 $( [ -n "$SECURE_TCP" ] && echo on || echo off )"

# The image creates CLICKHOUSE_DB only while initialising an empty data directory;
# make sure it exists on every boot (e.g. after a first start that failed later).
if [ -n "${CLICKHOUSE_DB:-}" ]; then
  (
    for _ in $(seq 1 120); do
      if clickhouse client --host 127.0.0.1 --user "$CLICKHOUSE_USER" --query "CREATE DATABASE IF NOT EXISTS \`${CLICKHOUSE_DB}\`" >/dev/null 2>&1; then
        log "database ${CLICKHOUSE_DB} is in place"
        exit 0
      fi
      sleep 5
    done
    log "WARNING: could not create database ${CLICKHOUSE_DB} within 10 minutes"
  ) &
fi
exec /entrypoint.sh "$@"
