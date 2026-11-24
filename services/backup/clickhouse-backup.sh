#!/bin/bash
# ClickHouse backups to a Railway Bucket with ClickHouse's own BACKUP ... TO S3,
# with retention. Runs once and exits: "ClickHouse Backup" is a Railway cron job.
#
#   clickhouse-backup backup    BACKUP ALL user databases -> Bucket, verify, prune (default)
#   clickhouse-backup list      list the backup runs stored in the Bucket
#   clickhouse-backup restore   RESTORE DATABASE RESTORE_DATABASE AS RESTORE_TARGET (new name)
#
# The server writes the backup straight to the Bucket (parts are copied, not
# re-encoded), so this job only sends SQL over the private network (HTTP 8123)
# and uses rclone for listing and retention.
#
# Bucket layout (one folder per run, UTC timestamp):
#   {BACKUP_PREFIX}/20261124T040000Z/.backup + data/ + metadata/   ClickHouse backup
#   {BACKUP_PREFIX}/20261124T040000Z/MANIFEST.txt                  written last
set -Eeuo pipefail

PREFIX="${BACKUP_PREFIX:-clickhouse}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
KEEP_MIN="${BACKUP_KEEP_MIN:-3}"
WAIT_SECONDS="${BACKUP_WAIT_SECONDS:-600}"
MAX_HOURS="${BACKUP_MAX_HOURS:-12}"
INCOMPLETE_GRACE_DAYS=2
RUN_RE='^[0-9]{8}T[0-9]{6}Z$'
NAME_RE='^[A-Za-z_][A-Za-z0-9_]{0,63}$'
REMOTE=""
CH_URL=""
WORK="${TMPDIR:-/tmp}/clickhouse-backup.$$"

log() { printf '[clickhouse-backup] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

require_uint() {
  [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge "$3" ] || die "$1 must be a whole number >= $3 (got '$2')"
}

validate_settings() {
  require_uint BACKUP_RETENTION_DAYS "${RETENTION_DAYS}" 1
  require_uint BACKUP_KEEP_MIN "${KEEP_MIN}" 1
  require_uint BACKUP_WAIT_SECONDS "${WAIT_SECONDS}" 0
  require_uint BACKUP_MAX_HOURS "${MAX_HOURS}" 1
  [[ "${PREFIX}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] && [[ "/${PREFIX}/" != */./* ]] && [[ "/${PREFIX}/" != */../* ]] \
    || die "BACKUP_PREFIX must be a folder path of letters, digits, '.', '_' and '-'"
  local var missing=()
  for var in CLICKHOUSE_HOST CLICKHOUSE_USER CLICKHOUSE_PASSWORD; do
    [ -n "${!var:-}" ] || missing+=("${var}")
  done
  [ "${#missing[@]}" -eq 0 ] || die "ClickHouse connection not configured (missing: ${missing[*]})"
  CH_URL="http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT:-8123}/"
  mkdir -p "${WORK}"
  chmod 0700 "${WORK}"
  # Credentials go to curl through a config file, never the command line.
  printf 'user = "%s:%s"\n' "${CLICKHOUSE_USER}" "${CLICKHOUSE_PASSWORD//\"/\\\"}" > "${WORK}/curl.conf"
}

configure_remote() {
  local var missing=()
  for var in BACKUP_S3_BUCKET BACKUP_S3_ENDPOINT BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY; do
    [ -n "${!var:-}" ] || missing+=("${var}")
  done
  [ "${#missing[@]}" -eq 0 ] || die "Bucket not configured (missing: ${missing[*]})"
  export RCLONE_CONFIG="${HOME:-/tmp}/rclone.conf"
  : > "${RCLONE_CONFIG}"
  export RCLONE_CONFIG_BUCKET_TYPE=s3
  export RCLONE_CONFIG_BUCKET_PROVIDER=Other
  export RCLONE_CONFIG_BUCKET_ENDPOINT="${BACKUP_S3_ENDPOINT}"
  export RCLONE_CONFIG_BUCKET_REGION="${BACKUP_S3_REGION:-auto}"
  export RCLONE_CONFIG_BUCKET_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID}"
  export RCLONE_CONFIG_BUCKET_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY}"
  export RCLONE_CONFIG_BUCKET_FORCE_PATH_STYLE="${BACKUP_S3_FORCE_PATH_STYLE:-false}"
  export RCLONE_CONFIG_BUCKET_NO_CHECK_BUCKET=true
  REMOTE="bucket:${BACKUP_S3_BUCKET}/${PREFIX}"
}

# ClickHouse's S3() wants a path-style URL to the folder; Railway Buckets accept it.
s3_function() {
  local run="$1" key secret
  key="${BACKUP_S3_ACCESS_KEY_ID//\'/\\\'}"
  secret="${BACKUP_S3_SECRET_ACCESS_KEY//\'/\\\'}"
  printf "S3('%s/%s/%s/%s/', '%s', '%s')" "${BACKUP_S3_ENDPOINT%/}" "${BACKUP_S3_BUCKET}" "${PREFIX}" "${run}" "${key}" "${secret}"
}

# Run one SQL statement over HTTP; the statement is sent as the request body.
ch() {
  printf '%s' "$1" > "${WORK}/query.sql"
  curl -sS --fail-with-body -K "${WORK}/curl.conf" --max-time 600 --data-binary @"${WORK}/query.sql" "${CH_URL}"
}

wait_for_clickhouse() {
  local waited=0
  until curl -fsS --max-time 10 "${CH_URL}ping" >/dev/null 2>&1 && ch "SELECT 1" >/dev/null 2>&1; do
    [ "${waited}" -ge "${WAIT_SECONDS}" ] && die "ClickHouse at ${CH_URL} not ready (or login refused) after ${WAIT_SECONDS}s"
    log "waiting for ClickHouse at ${CH_URL}"
    sleep 10
    waited=$((waited + 10))
  done
  SERVER_VERSION="$(ch "SELECT version()")"
}

# Wait for an ASYNC BACKUP/RESTORE; print its final row.
wait_operation() {
  local id="$1" expected="$2" row status deadline
  deadline=$(( $(date +%s) + MAX_HOURS * 3600 ))
  while true; do
    row="$(ch "SELECT status, replaceAll(error, '\n', ' '), num_files, total_size FROM system.backups WHERE id = '${id}' FORMAT TSV")" \
      || { log "ERROR: could not read the status of ${id} from system.backups"; return 1; }
    status="${row%%$'\t'*}"
    case "${status}" in
      "${expected}") printf '%s\n' "${row}"; return 0 ;;
      *FAILED* | *CANCELLED*) log "ERROR: operation ${id}: ${row}"; return 1 ;;
    esac
    [ "$(date +%s)" -lt "${deadline}" ] || { log "ERROR: operation ${id} still '${status}' after ${MAX_HOURS}h"; return 1; }
    sleep 10
  done
}

list_runs() {
  rclone lsf --dirs-only "${REMOTE}/" 2>/dev/null | sed 's#/$##' | grep -E "${RUN_RE}" | sort || true
}

list_complete_runs() {
  rclone lsf -R --files-only --max-depth 2 --include 'MANIFEST.txt' "${REMOTE}/" 2>/dev/null \
    | sed 's#/MANIFEST.txt$##' | grep -E "${RUN_RE}" | sort || true
}

run_backup() {
  local run_id out id row databases
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  databases="$(ch "SELECT arrayStringConcat(groupArray(name), ',') FROM system.databases WHERE name NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')")"
  log "starting run ${run_id} -> ${PREFIX}/${run_id}/ (ClickHouse ${SERVER_VERSION}; databases: ${databases:-none})"
  out="$(ch "BACKUP ALL EXCEPT DATABASES system, information_schema, INFORMATION_SCHEMA TO $(s3_function "${run_id}") ASYNC FORMAT TSV")" \
    || die "BACKUP was refused: ${out:-no answer}"
  id="${out%%$'\t'*}"
  [[ "${id}" =~ ^[A-Za-z0-9-]+$ ]] || die "unexpected BACKUP answer: ${out}"
  log "backup ${id} running"
  row="$(wait_operation "${id}" BACKUP_CREATED)" || die "run ${run_id} failed (no MANIFEST.txt); older backups were left untouched"
  rclone lsf "${REMOTE}/${run_id}/" | grep -qxF '.backup' || die "run ${run_id}: ClickHouse reported success but ${PREFIX}/${run_id}/.backup is missing"
  {
    printf 'run=%s\nserver_version=%s\nbackup_id=%s\ndatabases=%s\n' "${run_id}" "${SERVER_VERSION}" "${id}" "${databases}"
    printf 'status_error_files_bytes=%s\n' "${row}"
  } | rclone rcat "${REMOTE}/${run_id}/MANIFEST.txt"
  log "run ${run_id} complete (${row//$'\t'/ | })"
  CURRENT_RUN="${run_id}"
}

prune() {
  local now cutoff incomplete_cutoff complete=() run keep protected=" " total
  now="$(date -u +%s)"
  cutoff="$(date -u -d "@$((now - RETENTION_DAYS * 86400))" +%Y%m%dT%H%M%SZ)"
  incomplete_cutoff="$(date -u -d "@$((now - INCOMPLETE_GRACE_DAYS * 86400))" +%Y%m%dT%H%M%SZ)"
  while IFS= read -r run; do [ -n "${run}" ] && complete+=("${run}"); done < <(list_complete_runs)
  total="${#complete[@]}"
  keep=$((total - KEEP_MIN))
  for run in ${complete[@]+"${complete[@]}"}; do
    if [ "${keep}" -le 0 ]; then protected="${protected}${run} "; fi
    keep=$((keep - 1))
  done
  log "retention: ${total} complete run(s), keep ${RETENTION_DAYS} days, at least ${KEEP_MIN}"
  while IFS= read -r run; do
    [ -n "${run}" ] || continue
    [ "${run}" = "${CURRENT_RUN:-}" ] && continue
    case "${protected}" in *" ${run} "*) continue ;; esac
    if printf '%s\n' ${complete[@]+"${complete[@]}"} | grep -qx "${run}"; then
      [[ "${run}" < "${cutoff}" ]] || continue
      log "deleting expired run ${run}"
    else
      [[ "${run}" < "${incomplete_cutoff}" ]] || continue
      log "deleting incomplete run ${run}"
    fi
    rclone purge "${REMOTE}/${run}" || log "WARNING: could not delete ${run}"
  done < <(list_runs)
}

show_runs() {
  local complete=" " run
  while IFS= read -r run; do complete="${complete}${run} "; done < <(list_complete_runs)
  while IFS= read -r run; do
    [ -n "${run}" ] || continue
    case "${complete}" in *" ${run} "*) printf '%s complete\n' "${run}" ;; *) printf '%s incomplete\n' "${run}" ;; esac
  done < <(list_runs)
}

# Restores one database under a NEW name; an existing database is never touched.
run_restore() {
  local run="${RESTORE_RUN:-latest}" db="${RESTORE_DATABASE:-${CLICKHOUSE_DB:-}}" target out id row
  [[ "${db}" =~ ${NAME_RE} ]] || die "RESTORE_DATABASE must name the database to restore (got '${db}')"
  target="${RESTORE_TARGET:-${db}_restored}"
  [[ "${target}" =~ ${NAME_RE} ]] || die "RESTORE_TARGET '${target}' must be a plain name"
  if [ "${run}" = latest ]; then
    run="$(list_complete_runs | tail -n 1)"
    [ -n "${run}" ] || die "no complete backup run in ${PREFIX}/"
  fi
  [[ "${run}" =~ ${RUN_RE} ]] || die "RESTORE_RUN must be 'latest' or a run folder like 20261124T040000Z"
  [ "$(ch "SELECT count() FROM system.databases WHERE name = '${target}'")" = 0 ] \
    || die "database ${target} already exists; set RESTORE_TARGET to a new name"
  log "restoring database ${db} from ${PREFIX}/${run}/ as ${target}"
  out="$(ch "RESTORE DATABASE \`${db}\` AS \`${target}\` FROM $(s3_function "${run}") ASYNC FORMAT TSV")" \
    || die "RESTORE was refused: ${out:-no answer}"
  id="${out%%$'\t'*}"
  row="$(wait_operation "${id}" RESTORED)" || die "restore ${id} failed"
  log "restore finished: ${target} ($(ch "SELECT count() FROM system.tables WHERE database = '${target}'") table(s); ${row//$'\t'/ | })"
}

main() {
  # A Railway start command such as "/usr/local/bin/clickhouse-backup restore" arrives
  # as arguments of the entrypoint; drop the repeated program name.
  case "${1:-}" in */clickhouse-backup | clickhouse-backup) shift ;; esac
  local cmd="${1:-backup}"
  case "${cmd}" in
    backup)
      validate_settings
      configure_remote
      wait_for_clickhouse
      run_backup
      prune
      log "done"
      ;;
    list)
      configure_remote
      show_runs
      ;;
    restore)
      validate_settings
      configure_remote
      wait_for_clickhouse
      run_restore
      ;;
    *) die "unknown command '${cmd}' (use: backup, list, restore)" ;;
  esac
}

main "$@"
