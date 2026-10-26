#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/list-kopia-snapshot-heights.sh [--all-schemas]

Lists uploaded Fractal snapshot heights, numerically sorted and deduplicated,
one per line. By default, only the current SNAPSHOT_SCHEMA_VERSION is listed.
Includes incomplete/checkpoint records and heights with missing datasets;
presence in this list does not mean a height is ready to restore.

Options:
  --all-schemas   Include records from every DB schema, including untagged ones.
  -h, --help      Show this help.

Uses the same read-only R2 credentials and repository settings as restore.
An empty repository produces no output and exits successfully.
EOF
}

tags=("network:fractal" "role:snapshot")
all_schemas=0
for arg in "$@"; do
  case "$arg" in
    --all-schemas) all_schemas=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown argument: $arg" ;;
  esac
done

if [ "$all_schemas" -eq 0 ]; then
  tags+=("dbschema:${SNAPSHOT_SCHEMA_VERSION}")
fi

require_command kopia
require_command jq
load_default_readonly_r2_credentials

log "Connecting Kopia repository as read-only" >&2
kopia_connect_s3 readonly >&2

# Capture the list first so a failed command cannot produce a successful-looking
# partial list of heights. Do not use the complete-record filter for inventory.
snapshots_json="$(kopia_snapshot_json_by_tags "${tags[@]}")"
printf '%s\n' "$snapshots_json" | jq -rs '
  def tag_value($key):
    (.tags // null) as $tags
    | if ($tags | type) == "object" then
        $tags[$key] // $tags["tag:" + $key] // empty
      elif ($tags | type) == "array" then
        $tags[]
        | if type == "string" then
            if startswith("tag:" + $key + ":") then ltrimstr("tag:" + $key + ":")
            elif startswith($key + ":") then ltrimstr($key + ":")
            else empty end
          elif type == "object" then
            .[$key] // .["tag:" + $key] // empty
          else empty end
      else empty end;

  if length != 1 then error("expected one snapshot JSON document") else .[0] end
  | if type == "array" then .
    elif type == "object" then [.]
    else error("expected snapshot array or object") end
  | [ .[] | tag_value("height") | tostring | select(test("^[0-9]+$")) | tonumber ]
  | unique
  | .[]
'
