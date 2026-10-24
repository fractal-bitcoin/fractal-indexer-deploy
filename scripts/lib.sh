#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${SNAPSHOT_SCHEMA_VERSION:=v1}"
: "${KOPIA_R2_BUCKET:=kopia-repo}"
: "${KOPIA_R2_ENDPOINT:=eccc9c966ad74b3b2b15c2961767d059.r2.cloudflarestorage.com}"
: "${KOPIA_REPOSITORY_PASSWORD:=fractalbitcoin}"
: "${KOPIA_REPOSITORY_PREFIX:=fractald-pruned}"
: "${KOPIA_USERNAME:=fractalbitcoin}"
: "${KOPIA_HOSTNAME:=fractalbitcoin-fip101}"
: "${UPLOAD_BASE_DIR:=/opt/fractal-indexer-deploy}"
: "${KOPIA_CACHE_DIRECTORY:=${REPO_ROOT}/.kopia-cache}"
FRACTAL_NETWORK_NAME="fractal-indexer-fip101-net"

load_default_readonly_r2_credentials() {
  : "${AWS_ACCESS_KEY_ID:=d10a4a18c0d604d803049c94a01dace5}"
  if [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    require_command base64
    AWS_SECRET_ACCESS_KEY="$(printf '%s' 'OTAyZTFiYmQ0NmUyOWQ3NTQxZTBhMzY5MmI0YTU2OGY3MmJmN2RiZmIyNzNiMmE0ZDkwMmI0ZmUzYjA5MGRmYg==' | base64 -d)"
  fi
  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
}

log_timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  printf '[%s] >>> %s\n' "$(log_timestamp)" "$*"
}

warn() {
  printf '[%s] WARN: %s\n' "$(log_timestamp)" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$(log_timestamp)" "$*" >&2
  exit 1
}

usage_error() {
  printf '[%s] ERROR: %s\n\n' "$(log_timestamp)" "$1" >&2
  usage >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    die "missing required environment variable: ${name}"
  fi
}

is_numeric() {
  case "$1" in
    ''|*[!0-9]*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

compose_cmd_array() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    return
  fi

  die "missing docker compose plugin"
}

compose_cmd() {
  compose_cmd_array
  printf '%s\n' "${COMPOSE_CMD[*]}"
}

run_compose() {
  local dir="$1"
  shift

  compose_cmd_array
  (
    cd "$dir"
    "${COMPOSE_CMD[@]}" "$@"
  )
}

ensure_fractal_network() {
  require_command docker

  if docker network inspect "$FRACTAL_NETWORK_NAME" >/dev/null 2>&1; then
    log "Docker network ${FRACTAL_NETWORK_NAME} already exists"
    return
  fi

  log "Creating Docker network ${FRACTAL_NETWORK_NAME}"
  docker network create "$FRACTAL_NETWORK_NAME" >/dev/null
}

compose_config_text() {
  local dir="$1"

  compose_cmd_array
  (
    cd "$dir"
    "${COMPOSE_CMD[@]}" config
  )
}

check_compose_public_ports() {
  local dir="$1"
  local name="$2"
  local sensitive_ports="$3"
  local config

  config="$(compose_config_text "$dir")"

  if printf '%s\n' "$config" | grep -Eq 'target: "?('"$sensitive_ports"')"?'; then
    die "${name} publishes a sensitive container port (${sensitive_ports}); keep RPC, ZMQ, database, and cache ports internal to ${FRACTAL_NETWORK_NAME}"
  fi

  if printf '%s\n' "$config" | grep -Eq 'host_ip: "?0\.0\.0\.0"?'; then
    warn "${name} has ports bound to 0.0.0.0; ensure this is intentional and protected by firewall/security groups"
  fi
}

check_port_publication_security() {
  log "Checking Docker Compose port exposure"
  check_compose_public_ports "${REPO_ROOT}/fractald" fractald '10330|10331|10332'
  check_compose_public_ports "${REPO_ROOT}/fractal-indexer" fractal-indexer '9000|9221|9222'
  log "Sensitive ports stay inside Docker network ${FRACTAL_NETWORK_NAME}; public endpoints bind to BIND_HOST=${BIND_HOST:-127.0.0.1}"
}

port_in_use() {
  local port="$1"

  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
    return
  fi

  if command -v ss >/dev/null 2>&1; then
    ss -ltn | awk '{print $4}' | grep -Eq "(^|:)${port}$"
    return
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -an | grep -E "[.:]${port}[[:space:]].*LISTEN" >/dev/null 2>&1
    return
  fi

  warn "cannot check port ${port}; lsof, ss, and netstat are unavailable"
  return 1
}

check_ports_free() {
  local port

  for port in "$@"; do
    if port_in_use "$port"; then
      die "port ${port} is already in use; services may already be running. If you need to redeploy, run scripts/cleanup.sh --stop first"
    fi
  done
}

ensure_empty_or_missing() {
  local path="$1"

  if [ -e "$path" ] && [ "$(find "$path" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]; then
    die "${path} already exists and is not empty; add --force to ignore this check"
  fi
}

generate_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
    return
  fi

  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48
  printf '\n'
}

kopia_connect_s3() {
  local mode="${1:-}"
  local readonly_args=()
  local override_args=()

  require_env AWS_ACCESS_KEY_ID
  require_env AWS_SECRET_ACCESS_KEY
  require_env KOPIA_REPOSITORY_PASSWORD

  mkdir -p "$KOPIA_CACHE_DIRECTORY"

  if [ "$mode" = "readonly" ]; then
    readonly_args=(--readonly)
  else
    override_args=(--override-username="$KOPIA_USERNAME" --override-hostname="$KOPIA_HOSTNAME")
  fi

  KOPIA_CHECK_FOR_UPDATES=false kopia repository connect s3 \
    --bucket="$KOPIA_R2_BUCKET" \
    --endpoint="$KOPIA_R2_ENDPOINT" \
    --prefix="$KOPIA_REPOSITORY_PREFIX" \
    --password="$KOPIA_REPOSITORY_PASSWORD" \
    --cache-directory="$KOPIA_CACHE_DIRECTORY" \
    "${override_args[@]}" \
    "${readonly_args[@]}"
}

kopia_snapshot_json_by_tags() {
  local tag_args=()
  local tag

  for tag in "$@"; do
    tag_args+=(--tags="$tag")
  done

  kopia snapshot list --all --json "${tag_args[@]}"
}

kopia_complete_snapshot_json_by_tags() {
  local snapshots_json

  snapshots_json="$(kopia_snapshot_json_by_tags "$@")" || return "$?"
  printf '%s\n' "$snapshots_json" \
    | jq -cs '
      # Kopia may return incomplete checkpoint records with a usable root
      # object. Only complete records are safe to restore or mount.
      if length != 1 then error("expected one snapshot JSON document") else .[0] end
      | if type == "array" then .
        elif type == "object" then [.]
        else error("expected snapshot array or object") end
      | map(select(
          ((.rootEntry.obj // "") != "")
          and ((.incomplete // "") == "")
          and ((.rootEntry.incomplete // "") == "")
          and ((.rootEntry.summ.incomplete // "") == "")
          and ((.rootEntry.summ.numFailed // 0) == 0)
          and ((.rootEntry.summ.errors // []) | length == 0)
        ))
    '
}

kopia_snapshot_object_id() {
  local object_id
  local tags_display

  tags_display="$(IFS=,; printf '%s' "$*")"
  if ! object_id="$(kopia_complete_snapshot_json_by_tags "$@" \
    | jq -r '
      # When multiple complete snapshots match the same tag set, restore the
      # newest complete record.
      sort_by(.startTime // .endTime // "")
      | last
      | .rootEntry.obj // empty
    ')"; then
    die "failed to query or parse snapshots for tags: ${tags_display}"
  fi

  if [ -z "$object_id" ]; then
    die "complete snapshot not found for tags: ${tags_display}"
  fi

  printf '%s\n' "$object_id"
}

kopia_snapshot_source_path() {
  local source_path
  local tags_display

  tags_display="$(IFS=,; printf '%s' "$*")"
  if ! source_path="$(kopia_complete_snapshot_json_by_tags "$@" \
    | jq -r '
      map(select(.source.path != null))
      | sort_by(.startTime // .endTime // "")
      | last
      | .source.path // empty
    ')"; then
    die "failed to query or parse snapshots for tags: ${tags_display}"
  fi

  if [ -z "$source_path" ]; then
    die "snapshot source path not found for tags: ${tags_display}"
  fi

  printf '%s\n' "$source_path"
}

kopia_latest_complete_snapshot_selection() {
  local required_datasets_csv="fractald-blocks,fractald-chainstate,fractal-indexer-data"
  local selection

  if ! selection="$(kopia_complete_snapshot_json_by_tags "network:fractal" "role:snapshot" "dbschema:${SNAPSHOT_SCHEMA_VERSION}" \
    | jq -r --arg required "$required_datasets_csv" --arg schema "$SNAPSHOT_SCHEMA_VERSION" '
      # Tags have appeared in both object form, such as
      # {"tag:height":"1827202"}, and array/string form, such as
      # ["height:1827202"]. Support both forms to keep old snapshots readable.
      def tag_value($key):
        if (.tags // null) == null then
          empty
        elif (.tags | type) == "object" then
          .tags[$key] // .tags["tag:" + $key] // empty
        elif (.tags | type) == "array" then
          (.tags[]
            | if type == "string" then
                select(startswith($key + ":") or startswith("tag:" + $key + ":"))
                | sub("^tag:" + $key + ":"; "")
                | sub("^" + $key + ":"; "")
              elif type == "object" then
                .[$key] // .["tag:" + $key] // empty
              else
                empty
              end)
        else
          empty
        end;

      ($required | split(",")) as $required_datasets
      | map({
          height: (tag_value("height") | tostring),
          dataset: (tag_value("dataset") | tostring),
          schema: (tag_value("dbschema") | tostring),
          object: (.rootEntry.obj // empty),
          startTime: (.startTime // .endTime // "")
        })
      | map(select((.height | test("^[0-9]+$")) and (.dataset != "") and .schema == $schema))
      | group_by(.height)
      | map(
          . as $records
          | {
              height: .[0].height,
              roots: (reduce $required_datasets[] as $dataset
                ({};
                  .[$dataset] = (
                    [$records[] | select(.dataset == $dataset)]
                    | sort_by(.startTime)
                    | last
                    | (.object // "")
                  )
                ))
            }
        )
      | map(select(. as $candidate | all($required_datasets[]; $candidate.roots[.] != "")))
      | sort_by(.height | tonumber)
      | last
      | select(. != null)
      | [
          .height,
          .roots["fractald-blocks"],
          .roots["fractald-chainstate"],
          .roots["fractal-indexer-data"]
        ]
      | @tsv
    ')"; then
    die "failed to query or parse snapshots for dbschema:${SNAPSHOT_SCHEMA_VERSION}"
  fi

  if [ -z "$selection" ]; then
    die "no complete snapshot height found for dbschema:${SNAPSHOT_SCHEMA_VERSION} and required datasets: ${required_datasets_csv}"
  fi

  printf '%s\n' "$selection"
}

kopia_latest_complete_snapshot_height() {
  local selection

  selection="$(kopia_latest_complete_snapshot_selection)" || return "$?"
  printf '%s\n' "${selection%%$'\t'*}"
}

kopia_restore_snapshot_dataset() {
  local snapshot_height="$1"
  local dataset="$2"
  local target="$3"
  local delete_extra="${4:-0}"
  local object_id="${5:-}"
  local tags_display
  local restore_args=(--skip-existing --write-files-atomically)
  local tags=(
    "network:fractal"
    "role:snapshot"
    "dataset:${dataset}"
    "height:${snapshot_height}"
    "dbschema:${SNAPSHOT_SCHEMA_VERSION}"
  )

  tags_display="$(IFS=,; printf '%s' "${tags[*]}")"
  if [ -z "$object_id" ]; then
    log "Resolving ${dataset} (${tags_display})"
    object_id="$(kopia_snapshot_object_id "${tags[@]}")" || return "$?"
  else
    log "Using preselected complete snapshot root for ${dataset} (${object_id})"
  fi

  mkdir -p "$(dirname "$target")"
  if [ "$delete_extra" -eq 1 ]; then
    restore_args+=(--delete-extra)
  fi

  log "Restoring ${dataset} to ${target}"
  kopia snapshot restore "$object_id" "$target" "${restore_args[@]}"

  KOPIA_RESTORED_OBJECT_ID="$object_id"
}

sed_replacement_escape() {
  sed -e 's/[\/&]/\\&/g'
}

generate_from_template() {
  local template="$1"
  local target="$2"
  local sed_args=()
  local placeholder value

  shift 2

  while [ "$#" -gt 0 ]; do
    placeholder="$1"
    value="$(printf '%s' "$2" | sed_replacement_escape)"
    sed_args+=(-e "s/${placeholder}/${value}/g")
    shift 2
  done

  mkdir -p "$(dirname "$target")"
  sed "${sed_args[@]}" "$template" >"$target"
}

generate_fractald_config() {
  local user="$1"
  local password="$2"
  local keep_prune="${3:-1}"
  local template="${REPO_ROOT}/fractald/conf/bitcoin.conf.example"
  local target="${REPO_ROOT}/fractald/conf/bitcoin.conf"
  local sed_args=()

  sed_args+=(
    -e "s/{REPLACE_RPC_USER}/$(printf '%s' "$user" | sed_replacement_escape)/g"
    -e "s/{REPLACE_RPC_PASSWORD}/$(printf '%s' "$password" | sed_replacement_escape)/g"
  )

  if [ "$keep_prune" -eq 0 ]; then
    sed_args+=(-e '/^[[:space:]]*prune[[:space:]]*=/d')
  fi

  mkdir -p "$(dirname "$target")"
  sed "${sed_args[@]}" "$template" >"$target"
}

generate_fractal_indexer_chain_config() {
  local rpc_user="$1"
  local rpc_password="$2"
  local template="${REPO_ROOT}/fractal-indexer/conf/indexer/chain.yaml.example"
  local target="${REPO_ROOT}/fractal-indexer/conf/indexer/chain.yaml"

  generate_from_template "$template" "$target" \
    "{REPLACE_RPC_USER}" "$rpc_user" \
    "{REPLACE_RPC_PASSWORD}" "$rpc_password"
}

generate_proof_publisher_config() {
  local rpc_user="$1"
  local rpc_password="$2"
  local template="${REPO_ROOT}/proof-publisher/config.example.json"
  local target="${REPO_ROOT}/proof-publisher/config.json"

  generate_from_template "$template" "$target" \
    "REPLACE_RPC_USER" "$rpc_user" \
    "REPLACE_RPC_PASSWORD" "$rpc_password" \
    "REPLACE_PRIVATE_KEY_WIF" "${PROOF_PRIVATE_KEY_WIF:-REPLACE_PRIVATE_KEY_WIF}" \
    "REPLACE_CHANGE_ADDRESS" "${PROOF_CHANGE_ADDRESS:-REPLACE_CHANGE_ADDRESS}" \
    "REPLACE_REWARD_ADDRESS" "${PROOF_REWARD_ADDRESS:-REPLACE_REWARD_ADDRESS}" \
    "REPLACE_INDEXER_NAME" "${PROOF_INDEXER_NAME:-REPLACE_INDEXER_NAME}" \
    "REPLACE_EXISTING_INDEXER_ID_OR_EMPTY" "${PROOF_INDEXER_ID:-}" \
    "REPLACE_UNISAT_OPEN_API_KEY" "${PROOF_UNISAT_OPEN_API_KEY:-REPLACE_UNISAT_OPEN_API_KEY}"
}

proof_publisher_can_start() {
  [ -n "${PROOF_PRIVATE_KEY_WIF:-}" ] \
    && [ -n "${PROOF_CHANGE_ADDRESS:-}" ] \
    && [ -n "${PROOF_REWARD_ADDRESS:-}" ] \
    && [ -n "${PROOF_INDEXER_NAME:-}" ] \
    && [ -n "${PROOF_UNISAT_OPEN_API_KEY:-}" ]
}
