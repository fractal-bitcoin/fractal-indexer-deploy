#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

FRACTAL_INDEXER_INIT_END_HEIGHT=256
FRACTALD_INIT_HEIGHT_CHECK_ATTEMPTS=720
FRACTALD_INIT_HEIGHT_CHECK_DELAY_SECONDS=10
FRACTAL_INDEXER_API_CHECK_ATTEMPTS=120
FRACTAL_INDEXER_API_CHECK_DELAY_SECONDS=5

usage() {
  cat <<'EOF'
Usage:
  scripts/deploy.sh [--snapshot=<height|latest>] [--download-only] [--force] [--skip-init-db] [--skip-checks=memory,disk] [--yes]

Snapshot restore environment:
  AWS_ACCESS_KEY_ID       Read-only Cloudflare R2 access key; defaults to bundled read-only key
  AWS_SECRET_ACCESS_KEY   Read-only Cloudflare R2 secret key; defaults to bundled read-only key

Without --snapshot, the script initializes configs and starts services without
restoring Kopia snapshot data.

Use --snapshot=latest to restore the highest height that has all required
snapshot datasets.

Options:
  --force                  Skip runtime data directory existence checks. With
                           --snapshot, restore snapshots with --delete-extra.
  --download-only          Restore snapshot datasets and exit without
                           initializing configs or starting services. Requires
                           --snapshot=<height|latest>.
  --skip-init-db           Skip fractal-indexer DB initialization.
  --skip-checks=<list>     Downgrade selected machine requirement failures to
                           warnings. Supported values: memory,disk.
  --yes                    Automatically confirm non-snapshot deployment warnings.
EOF
}

snapshot_height=""
snapshot_blocks_object_id=""
snapshot_chainstate_object_id=""
snapshot_indexer_object_id=""
force=0
skip_init_db=0
assume_yes=0
download_only=0
skip_checks=""
original_args=("$@")

validate_skip_checks() {
  local value="$1"
  local item
  local -a items

  if [ -z "$value" ]; then
    usage_error "--skip-checks requires at least one value"
  fi

  IFS=',' read -r -a items <<<"$value"
  for item in "${items[@]}"; do
    case "$item" in
      memory|disk)
        ;;
      "")
        usage_error "--skip-checks contains an empty value"
        ;;
      *)
        usage_error "unsupported --skip-checks value: $item"
        ;;
    esac
  done
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --snapshot=*)
      snapshot_height="${1#--snapshot=}"
      ;;
    --force)
      force=1
      ;;
    --download-only)
      download_only=1
      ;;
    --skip-init-db)
      skip_init_db=1
      ;;
    --skip-checks=*)
      skip_checks="${1#--skip-checks=}"
      validate_skip_checks "$skip_checks"
      ;;
    --yes)
      assume_yes=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
  shift
done

if [ -n "$snapshot_height" ] && ! is_numeric "$snapshot_height"; then
  if [ "$snapshot_height" != "latest" ]; then
    usage_error "snapshot height must be numeric or latest"
  fi
fi

use_snapshot=0
if [ -n "$snapshot_height" ]; then
  use_snapshot=1
fi

if [ "$download_only" -eq 1 ] && [ "$use_snapshot" -eq 0 ]; then
  usage_error "--download-only requires --snapshot=<height|latest>"
fi

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  require_command sudo
  log "Re-running deploy script as root via sudo"
  exec sudo -E bash "$0" "${original_args[@]}"
fi

check_env_args=()
if [ "$assume_yes" -eq 1 ]; then
  check_env_args+=(--yes)
fi
if [ -n "$skip_checks" ]; then
  check_env_args+=(--skip-checks="$skip_checks")
fi
log "Installing missing deployment dependencies"
bash "${SCRIPT_DIR}/install-deps.sh"

load_default_readonly_r2_credentials

require_command docker
require_command jq
require_command curl
compose_cmd >/dev/null
ensure_fractal_network
check_port_publication_security

if [ "$use_snapshot" -eq 1 ]; then
  require_command kopia
  require_env AWS_ACCESS_KEY_ID
  require_env AWS_SECRET_ACCESS_KEY
  require_env KOPIA_REPOSITORY_PASSWORD

  if [ "$snapshot_height" = "latest" ]; then
    latest_snapshot_selection=""
    log "Connecting Kopia repository as read-only"
    kopia_connect_s3 readonly
    log "Resolving latest complete snapshot roots"
    latest_snapshot_selection="$(kopia_latest_complete_snapshot_selection)"
    IFS=$'\t' read -r \
      snapshot_height \
      snapshot_blocks_object_id \
      snapshot_chainstate_object_id \
      snapshot_indexer_object_id <<<"$latest_snapshot_selection"
    log "Latest complete snapshot height: ${snapshot_height}"
  fi
fi

if [ "$use_snapshot" -eq 1 ]; then
  check_env_args+=(--snapshot="$snapshot_height")
fi

log "Running deployment environment checks"
bash "${SCRIPT_DIR}/check-env.sh" "${check_env_args[@]}"

ensure_clickhouse_data_empty_for_non_snapshot_init() {
  local path="${REPO_ROOT}/fractal-indexer/data/clickhouse"
  local max_size_mb=1024
  local size_mb=0

  if [ -d "$path" ]; then
    size_mb="$(du -sm "$path" | awk '{print $1}')"
  fi

  if [ "$size_mb" -gt "$max_size_mb" ]; then
    die "${path} is ${size_mb}M, greater than ${max_size_mb}M; non-snapshot deployment must start with an empty fractal-indexer db. Stop services and remove runtime data before redeploying: scripts/cleanup.sh --data"
  fi
}

log "Checking ports"
check_ports_free 10333 8000

if [ "$force" -eq 1 ]; then
  warn "Skipping runtime data directory checks because --force was provided"
  if [ "$use_snapshot" -eq 1 ]; then
    warn "Snapshot restore will use --delete-extra for existing target directories"
  fi
else
  log "Checking runtime data directories"
  ensure_empty_or_missing "${REPO_ROOT}/fractald/data"
  ensure_empty_or_missing "${REPO_ROOT}/fractal-indexer/data"
fi

if [ "$use_snapshot" -eq 0 ] && [ "$skip_init_db" -eq 0 ]; then
  ensure_clickhouse_data_empty_for_non_snapshot_init
fi

restore_dataset() {
  local dataset="$1"
  local target="$2"
  local object_id
  local preselected_object_id=""
  local delete_extra=0

  if [ "$force" -eq 1 ]; then
    delete_extra=1
  fi

  case "$dataset" in
    fractald-blocks)
      preselected_object_id="$snapshot_blocks_object_id"
      ;;
    fractald-chainstate)
      preselected_object_id="$snapshot_chainstate_object_id"
      ;;
    fractal-indexer-data)
      preselected_object_id="$snapshot_indexer_object_id"
      ;;
  esac

  kopia_restore_snapshot_dataset "$snapshot_height" "$dataset" "$target" "$delete_extra" "$preselected_object_id"
  object_id="$KOPIA_RESTORED_OBJECT_ID"
  printf '%s\t%s\t%s\n' "$dataset" "$object_id" "$target" >>"$restore_summary_file"
}

restore_summary_file=""
fractald_info_file=""
fractald_rpc_error_file=""
fractal_indexer_initialized=0
fractal_indexer_storage_started=0
restore_summary_file="$(mktemp)"
fractald_info_file="$(mktemp)"
fractald_rpc_error_file="$(mktemp)"
trap 'rm -f "${restore_summary_file:-}" "${fractald_info_file:-}" "${fractald_rpc_error_file:-}"' EXIT

initialize_fractal_indexer() {
  if [ "$fractal_indexer_initialized" -eq 1 ]; then
    return
  fi

  log "Initializing fractal-indexer"
  (
    cd "${REPO_ROOT}/fractal-indexer"
    if [ "$use_snapshot" -eq 1 ]; then
      bash ./scripts/init.sh
    elif [ "$skip_init_db" -eq 1 ]; then
      warn "Skipping fractal-indexer DB initialization because --skip-init-db was provided"
      bash ./scripts/init.sh
    else
      bash ./scripts/init.sh db
    fi
  )
  fractal_indexer_initialized=1
}

start_fractal_indexer_storage() {
  if [ "$fractal_indexer_storage_started" -eq 1 ]; then
    return
  fi

  log "Starting fractal-indexer storage services"
  run_compose "${REPO_ROOT}/fractal-indexer" up -d clickhouse pika pika-brc20
  wait_compose_service_ready "${REPO_ROOT}/fractal-indexer" clickhouse 120 10
  wait_compose_service_ready "${REPO_ROOT}/fractal-indexer" pika 120 10
  wait_compose_service_ready "${REPO_ROOT}/fractal-indexer" pika-brc20 120 10
  fractal_indexer_storage_started=1
}

wait_compose_service_ready() {
  local dir="$1"
  local service="$2"
  local attempts="$3"
  local delay="$4"
  local container_id status
  local attempt

  log "Waiting for ${service} to become healthy"
  for attempt in $(seq 1 "$attempts"); do
    container_id="$(run_compose "$dir" ps -q "$service" 2>/dev/null || true)"
    if [ -n "$container_id" ]; then
      status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
      if [ "$status" = "healthy" ] || [ "$status" = "running" ]; then
        log "${service} is ${status}"
        return
      fi
    else
      status="missing"
    fi

    if [ "$attempt" -eq "$attempts" ]; then
      warn "${service} did not become healthy; last status: ${status}"
      if [ -n "$container_id" ]; then
        docker logs --tail=80 "$container_id" >&2 || true
      fi
      die "${service} did not become healthy"
    fi

    sleep "$delay"
  done
}

fetch_fractald_info() {
  run_compose "${REPO_ROOT}/fractald" exec -T fractald bitcoin-cli --conf=/conf/bitcoin.conf getblockchaininfo >"$fractald_info_file" 2>"${fractald_rpc_error_file:-/dev/null}"
}

fractald_blocks_from_info() {
  jq -r '(.blocks // 0) | tonumber' "$fractald_info_file"
}

fractald_pruneheight_from_info() {
  jq -r '(.pruneheight // 0) | tonumber' "$fractald_info_file"
}

wait_for_fractald_rpc() {
  local attempt

  log "Waiting for fractald RPC"
  for attempt in $(seq 1 120); do
    if fetch_fractald_info; then
      log "fractald RPC response:"
      sed 's/^/  /' "$fractald_info_file"
      if [ -n "${fractald_rpc_error_file:-}" ] && [ -s "$fractald_rpc_error_file" ]; then
        warn "fractald RPC stderr:"
        sed 's/^/  /' "$fractald_rpc_error_file"
      fi
      return
    fi
    sleep 5
  done

  die "fractald RPC did not become available"
}

wait_for_fractald_height() {
  local target_height="$1"
  local reason="$2"
  local attempt height last_height=""

  log "Waiting for fractald height >= ${target_height} before ${reason}"
  for attempt in $(seq 1 "$FRACTALD_INIT_HEIGHT_CHECK_ATTEMPTS"); do
    if fetch_fractald_info; then
      height="$(fractald_blocks_from_info)"
      if [ "$height" -ge "$target_height" ]; then
        log "fractald height ${height} reached target ${target_height}"
        return
      fi

      if [ "$height" != "$last_height" ] || [ $((attempt % 6)) -eq 1 ]; then
        log "fractald height ${height}/${target_height}; waiting for node sync"
        last_height="$height"
      fi
    else
      warn "fractald RPC unavailable while waiting for height ${target_height}"
      if [ -n "${fractald_rpc_error_file:-}" ] && [ -s "$fractald_rpc_error_file" ]; then
        sed 's/^/  /' "$fractald_rpc_error_file" >&2
      fi
    fi

    if [ "$attempt" -lt "$FRACTALD_INIT_HEIGHT_CHECK_ATTEMPTS" ]; then
      sleep "$FRACTALD_INIT_HEIGHT_CHECK_DELAY_SECONDS"
    fi
  done

  die "fractald height did not reach ${target_height}; cannot safely run fractal-indexer init.sh db"
}

wait_for_fractal_indexer_api() {
  local url="http://127.0.0.1:8000/brc20/bestheight"
  local attempt response="" height

  log "Waiting for fractal-indexer API bestheight"
  for attempt in $(seq 1 "$FRACTAL_INDEXER_API_CHECK_ATTEMPTS"); do
    response="$(curl -fsS --max-time 5 "$url" 2>/dev/null || true)"
    if printf '%s' "$response" | jq -e '.data.height != null' >/dev/null 2>&1; then
      height="$(printf '%s' "$response" | jq -r '.data.height')"
      log "fractal-indexer API bestheight is available at height ${height}"
      return
    fi

    if [ $((attempt % 12)) -eq 1 ]; then
      log "fractal-indexer API bestheight unavailable; waiting"
    fi

    if [ "$attempt" -lt "$FRACTAL_INDEXER_API_CHECK_ATTEMPTS" ]; then
      sleep "$FRACTAL_INDEXER_API_CHECK_DELAY_SECONDS"
    fi
  done

  warn "Last fractal-indexer API bestheight response:"
  if [ -n "$response" ]; then
    printf '%s\n' "$response" | sed 's/^/  /' >&2
  else
    warn "  empty response"
  fi
  die "fractal-indexer API bestheight did not become available"
}

if [ "$use_snapshot" -eq 1 ]; then
  log "Connecting Kopia repository as read-only"
  kopia_connect_s3 readonly

  log "Restoring snapshots"
  restore_dataset fractald-blocks "${REPO_ROOT}/fractald/data/blocks"
  restore_dataset fractald-chainstate "${REPO_ROOT}/fractald/data/chainstate"
  restore_dataset fractal-indexer-data "${REPO_ROOT}/fractal-indexer/data"

  if [ "$download_only" -eq 1 ]; then
    cat <<EOF

Restored snapshots:
$(cat "$restore_summary_file")

Selected snapshot height: ${snapshot_height}

Download-only mode: skipped config initialization and service startup.
EOF
    exit 0
  fi

  initialize_fractal_indexer
  start_fractal_indexer_storage
fi

load_fractald_rpc_credentials() {
  local config="${REPO_ROOT}/fractald/conf/bitcoin.conf"

  rpc_user="$(sed -n 's/^[[:space:]]*rpcuser[[:space:]]*=[[:space:]]*//p' "$config" | head -n 1)"
  rpc_password="$(sed -n 's/^[[:space:]]*rpcpassword[[:space:]]*=[[:space:]]*//p' "$config" | head -n 1)"

  if [ -z "$rpc_user" ] || [ -z "$rpc_password" ]; then
    die "${config} exists but rpcuser or rpcpassword is missing"
  fi
}

rpc_user=""
rpc_password=""
fractald_config="${REPO_ROOT}/fractald/conf/bitcoin.conf"
if [ -f "$fractald_config" ]; then
  log "Loading fractald RPC credentials from existing config"
  load_fractald_rpc_credentials
else
  rpc_user="fip101"
  rpc_password="$(generate_password)"
fi

log "Generating fractald config"
generate_fractald_config "$rpc_user" "$rpc_password" "$use_snapshot"

log "Initializing fractald directory ownership"
(
  cd "${REPO_ROOT}/fractald"
  bash ./scripts/init.sh
)

log "Starting fractald"
run_compose "${REPO_ROOT}/fractald" up -d

wait_for_fractald_rpc

node_pruneheight="$(fractald_pruneheight_from_info)"
log "fractald pruneheight: ${node_pruneheight}"

if [ "$use_snapshot" -eq 1 ] && [ "$node_pruneheight" -gt "$snapshot_height" ]; then
  die "fractald pruneheight (${node_pruneheight}) exceeds snapshot height (${snapshot_height})"
fi

if [ "$use_snapshot" -eq 0 ] && [ "$skip_init_db" -eq 0 ]; then
  wait_for_fractald_height "$FRACTAL_INDEXER_INIT_END_HEIGHT" "running fractal-indexer init.sh db"
fi

log "Generating fractal-indexer config"
generate_fractal_indexer_chain_config "$rpc_user" "$rpc_password"

initialize_fractal_indexer
start_fractal_indexer_storage

log "Starting fractal-indexer indexer and API"
run_compose "${REPO_ROOT}/fractal-indexer" up -d indexer api
wait_for_fractal_indexer_api

log "Final service status"
printf '\n[fractald]\n'
run_compose "${REPO_ROOT}/fractald" ps
printf '\n[fractal-indexer]\n'
run_compose "${REPO_ROOT}/fractal-indexer" ps

if [ "$use_snapshot" -eq 1 ]; then
  snapshot_summary="Restored snapshots:
$(cat "$restore_summary_file")

Selected snapshot height: ${snapshot_height}"
else
  snapshot_summary="Snapshot restore: skipped"
fi

cat <<EOF

${snapshot_summary}

Fractal indexer API: http://localhost:8000

Docker network: ${FRACTAL_NETWORK_NAME}
Public bind host: ${BIND_HOST:-127.0.0.1}
EOF
