#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/upload-kopia-snapshots.sh [--role=<role>] <snapshot-height>

Required environment:
  KOPIA_R2_ACCESS_KEY_ID       Write-capable Cloudflare R2 access key
  KOPIA_R2_SECRET_ACCESS_KEY   Write-capable Cloudflare R2 secret key

Optional environment:
  KOPIA_R2_BUCKET              Default: kopia-repo
  KOPIA_R2_ENDPOINT            Default: eccc9c966ad74b3b2b15c2961767d059.r2.cloudflarestorage.com
  KOPIA_REPOSITORY_PASSWORD    Default: fractalbitcoin
  KOPIA_REPOSITORY_PREFIX      Default: fractald-pruned
  KOPIA_USERNAME               Default: fractalbitcoin
  KOPIA_HOSTNAME               Default: fractalbitcoin-fip101
  UPLOAD_BASE_DIR              Default: /opt/fractal-indexer-deploy
  SNAPSHOT_SCHEMA_VERSION      Default: v1
  --role=<role>                Snapshot role tag value. Default: snapshot
  ALLOW_PARTIAL_UPLOAD         Set to 1 to skip missing datasets

Upload requires a reachable Docker daemon and stopped source writers.
Containers are checked before and after each dataset upload; this does not
verify that the supplied height matches the node and indexer data.
EOF
}

snapshot_height=""
snapshot_role="snapshot"
original_args=("$@")

while [ "$#" -gt 0 ]; do
  case "$1" in
    --role=*)
      snapshot_role="${1#--role=}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      usage_error "unknown argument: $1"
      ;;
    *)
      if [ -n "$snapshot_height" ]; then
        usage_error "expected exactly one snapshot height argument"
      fi
      snapshot_height="$1"
      ;;
  esac
  shift
done

if [ -z "$snapshot_height" ]; then
  usage_error "missing snapshot height argument"
fi

if ! is_numeric "$snapshot_height"; then
  usage_error "snapshot height must be numeric"
fi

case "$snapshot_role" in
  ''|*[[:space:]]*)
    usage_error "snapshot role must be non-empty and must not contain whitespace"
    ;;
esac

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  require_command sudo
  log "Re-running script as root via sudo"
  exec sudo -E bash "$0" "${original_args[@]}"
fi

require_command kopia
require_command jq
require_command docker
require_env KOPIA_R2_ACCESS_KEY_ID
require_env KOPIA_R2_SECRET_ACCESS_KEY
require_env KOPIA_REPOSITORY_PASSWORD

datasets=$(
  cat <<EOF
fractald-blocks|${UPLOAD_BASE_DIR}/fractald/data/blocks
fractald-chainstate|${UPLOAD_BASE_DIR}/fractald/data/chainstate
fractal-indexer-data|${UPLOAD_BASE_DIR}/fractal-indexer/data
EOF
)

missing=0
while IFS='|' read -r dataset path; do
  [ -n "$dataset" ] || continue
  if [ ! -d "$path" ]; then
    warn "missing dataset ${dataset}: ${path}"
    missing=1
  fi
done <<EOF
$datasets
EOF

if [ "$missing" -ne 0 ] && [ "${ALLOW_PARTIAL_UPLOAD:-}" != "1" ]; then
  die "one or more dataset paths are missing; set ALLOW_PARTIAL_UPLOAD=1 to upload available datasets"
fi

# Inspect mounts as well as Compose labels so renamed and one-off containers
# using these datasets are also rejected. Docker failures must not pass silently.
assert_source_containers_stopped() {
  local container_ids containers_json source_paths blockers

  container_ids="$(docker ps -q)" || die "cannot inspect running containers"
  [ -n "$container_ids" ] || return 0
  # Docker IDs contain only hexadecimal characters; expand the newline list.
  containers_json="$(docker inspect $container_ids)" || die "cannot inspect container mounts"
  source_paths="$(while IFS='|' read -r dataset path; do
    [ -d "$path" ] || continue
    (cd "$path" && pwd -P) || exit 1
  done <<<"$datasets")" || die "cannot resolve source directories"

  blockers="$(printf '%s\n' "$containers_json" | jq -r --arg paths "$source_paths" '
    ($paths | split("\n") | map(select(length > 0))) as $sources
    | .[]
    | select(.State.Running == true)
    | select(
        ((.Config.Labels["com.docker.compose.service"] // "") as $service
          | ["fractald", "indexer", "api", "clickhouse", "pika", "pika-brc20"]
          | index($service) != null)
        or any(.Mounts[]?;
          (.Source | rtrimstr("/")) as $mount
          | any($sources[];
              . as $source
              | $source == $mount or ($source | startswith($mount + "/"))
              or ($mount | startswith($source + "/"))))
      )
    | .Name
  ')" || die "cannot parse container inspection results"
  [ -z "$blockers" ] || die "stop source containers before uploading: ${blockers}"
}

log "Checking that source containers are stopped"
assert_source_containers_stopped
warn "Container checks do not verify cross-database consistency or the supplied height. Keep all writers stopped throughout upload."

log "Connecting Kopia repository"
kopia_connect_s3

summary_file="$(mktemp)"
trap 'rm -f "$summary_file"' EXIT

while IFS='|' read -r dataset path; do
  [ -n "$dataset" ] || continue

  if [ ! -d "$path" ]; then
    warn "skipping missing dataset ${dataset}: ${path}"
    continue
  fi

  assert_source_containers_stopped

  tag_args=(
    --tags="height:${snapshot_height}"
    --tags="network:fractal"
    --tags="role:${snapshot_role}"
    --tags="dataset:${dataset}"
    --tags="dbschema:${SNAPSHOT_SCHEMA_VERSION}"
  )

  log "Uploading ${dataset} from ${path}"
  kopia snapshot create "$path" "${tag_args[@]}"

  assert_source_containers_stopped

  snapshot_id="$(kopia_snapshot_object_id "height:${snapshot_height}" "network:fractal" "role:${snapshot_role}" "dataset:${dataset}" "dbschema:${SNAPSHOT_SCHEMA_VERSION}")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$snapshot_height" "$snapshot_role" "$SNAPSHOT_SCHEMA_VERSION" "$dataset" "$snapshot_id" "$path" >>"$summary_file"
done <<EOF
$datasets
EOF

assert_source_containers_stopped

log "Publish summary"
printf 'height\trole\tdbschema\tdataset\tsnapshot_object\tpath\n'
cat "$summary_file"
