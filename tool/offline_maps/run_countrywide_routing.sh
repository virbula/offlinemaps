#!/bin/bash
set -euo pipefail

readonly RELEASE_TAG="routing-2026.08.1"
readonly VERSION="2026.08.1"
readonly UPDATED_AT="2026-08-12T00:30:00.000Z"
readonly SOURCE_DATE_EPOCH="1786494600"
readonly IMAGE="ghcr.io/valhalla/valhalla:3.6.3@sha256:0cf1520c6a38b8a7e13a1931541e0ab6e9e42b64b4ca014293b6b8373d493160"
readonly RELEASE_PLAN_SHA="7725fa807a720a4df95593de799921e47a37ce09aa460d91acdab8675440d134"
readonly REPOSITORY="virbula/offlinemaps"
readonly PART_BYTES="1992294400"
readonly BUILD_CONCURRENCY="12"
readonly MINIMUM_BUILD_FREE_BYTES="$((120 * 1024 * 1024 * 1024))"
readonly MAXIMUM_LOGICAL_BYTES="$((64 * 1024 * 1024 * 1024))"
readonly SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/../.." && pwd)"
readonly WORK_ROOT="${COUNTRYWIDE_ROUTING_WORK_ROOT:-$REPOSITORY_ROOT/build/countrywide-routing}"
readonly COUNTRY_CODE="${COUNTRY_CODE:-US}"

case "$COUNTRY_CODE" in
  US)
    readonly COUNTRY_NAME="United States"
    readonly GRAPH_ID="us-countrywide"
    readonly SOURCE_URL="https://download.geofabrik.de/north-america/us-260811.osm.pbf"
    readonly SOURCE_BYTES="12077262565"
    readonly SOURCE_MD5="31b9933dd0d726ef6e7448a8d3b622ca"
    readonly EXPECTED_REGION_COUNT="51"
    readonly BOUNDS_WEST="-179.231086"
    readonly BOUNDS_SOUTH="18.86546"
    readonly BOUNDS_EAST="179.859681"
    readonly BOUNDS_NORTH="71.441059"
    readonly ROUTE_CASES=$'ca-nv|37.7749|-122.4194|39.5296|-119.8138\nny-nj|40.7128|-74.0060|40.7357|-74.1724\nmo-ks|39.0997|-94.5786|39.1141|-94.6275\ndc-va|38.9072|-77.0369|38.8816|-77.0910\nor-wa|45.5152|-122.6784|45.6387|-122.6615'
    ;;
  CA)
    readonly COUNTRY_NAME="Canada"
    readonly GRAPH_ID="canada-countrywide"
    readonly SOURCE_URL="https://download.geofabrik.de/north-america/canada-260811.osm.pbf"
    readonly SOURCE_BYTES="6411666312"
    readonly SOURCE_MD5="7ed560e57383b34456195050f15dc4ad"
    readonly EXPECTED_REGION_COUNT="13"
    readonly BOUNDS_WEST="-141.005548"
    readonly BOUNDS_SOUTH="41.676556"
    readonly BOUNDS_EAST="-52.619409"
    readonly BOUNDS_NORTH="83.116116"
    readonly ROUTE_CASES=$'on-qc|45.4215|-75.6972|45.4765|-75.7013\nab-sk|53.2784|-110.0050|53.2784|-109.9900\nns-nb|45.8167|-64.2167|45.8979|-64.3683'
    ;;
  *)
    printf 'Unsupported country code: %s\n' "$COUNTRY_CODE" >&2
    exit 2
    ;;
esac

readonly ROOT="$WORK_ROOT/$GRAPH_ID"
readonly CONTROL="$ROOT/control"
readonly SOURCE_DIR="$ROOT/source"
readonly WORK="$ROOT/work"
readonly OUTPUT="$ROOT/output"
readonly PARTS="$ROOT/parts"
readonly LOG="$ROOT/$GRAPH_ID.log"
readonly SOURCE="$SOURCE_DIR/$(basename "$SOURCE_URL")"
readonly ARCHIVE="$OUTPUT/$GRAPH_ID-routing-$VERSION.vtiles.tar"
readonly DESCRIPTOR="$OUTPUT/$GRAPH_ID-routing-$VERSION.vtiles.descriptor.json"
readonly PLAN="$CONTROL/$GRAPH_ID-plan.json"
readonly REGION_PLAN="$CONTROL/routing-plan.json"
readonly TILE_REPORT="$CONTROL/$GRAPH_ID-tile-validation.txt"
readonly ROUTE_REPORT="$CONTROL/$GRAPH_ID-cross-boundary-routes.txt"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
file_bytes() { stat -f '%z' "$1"; }
file_sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
file_md5() { md5 -q "$1"; }

write_plan() {
  mkdir -p "$CONTROL"
  if [[ ! -f "$REGION_PLAN" ]] || [[ "$(file_sha256 "$REGION_PLAN")" != "$RELEASE_PLAN_SHA" ]]; then
    gh release download "$RELEASE_TAG" --repo "$REPOSITORY" \
      --pattern routing-plan.json --dir "$CONTROL" --clobber
  fi
  [[ "$(file_sha256 "$REGION_PLAN")" == "$RELEASE_PLAN_SHA" ]]
  jq --arg tag "$RELEASE_TAG" --arg graph "$GRAPH_ID" \
     --arg version "$VERSION" --arg updated "$UPDATED_AT" \
     --arg image "$IMAGE" --arg country "$COUNTRY_CODE" \
     --arg sourceUrl "$SOURCE_URL" --arg sourceMd5 "$SOURCE_MD5" \
     --argjson concurrency "$BUILD_CONCURRENCY" \
     --argjson sourceBytes "$SOURCE_BYTES" \
     '{schemaVersion:1, releaseTag:$tag, graphId:$graph, version:$version,
       updatedAt:$updated,
       builder:{engine:"valhalla",version:"3.6.3",image:$image,concurrency:$concurrency},
       source:{provider:"Geofabrik",url:$sourceUrl,exactBytes:$sourceBytes,md5:$sourceMd5},
       regionIds:[.regions[]|select(.countryCode==$country)|.id]|sort}' \
     "$REGION_PLAN" > "$PLAN.tmp"
  [[ "$(jq '.regionIds|length' "$PLAN.tmp")" == "$EXPECTED_REGION_COUNT" ]]
  mv "$PLAN.tmp" "$PLAN"
  file_sha256 "$PLAN" > "$PLAN.sha256"
}

preflight() {
  command -v docker >/dev/null
  command -v gh >/dev/null
  command -v jq >/dev/null
  gh auth status --hostname github.com >/dev/null
  local memory docker_memory free_disk
  memory="$(sysctl -n hw.memsize)"
  docker_memory="$(docker info --format '{{.MemTotal}}')"
  free_disk="$(( $(df -Pk "$ROOT" | awk 'NR==2 {print $4}') * 1024 ))"
  [[ "$memory" -ge $((64 * 1024 * 1024 * 1024)) ]]
  [[ "$docker_memory" -ge $((60 * 1024 * 1024 * 1024)) ]]
  [[ "$free_disk" -ge "$MINIMUM_BUILD_FREE_BYTES" ]]
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then docker pull --platform linux/amd64 "$IMAGE"; fi
  log "Capacity accepted: hostMemory=$memory dockerMemory=$docker_memory freeDisk=$free_disk."
}

require_source() {
  mkdir -p "$SOURCE_DIR"
  if [[ -f "$SOURCE" ]] && [[ "$(file_bytes "$SOURCE")" == "$SOURCE_BYTES" ]] &&
     [[ "$(file_md5 "$SOURCE")" == "$SOURCE_MD5" ]]; then
    log "Reusing verified $COUNTRY_NAME source."
    return
  fi
  local temporary="$SOURCE.download"
  log "Downloading pinned $COUNTRY_NAME source ($SOURCE_BYTES bytes)."
  curl --fail --location --retry 8 --retry-all-errors --continue-at - \
    --output "$temporary" "$SOURCE_URL"
  [[ "$(file_bytes "$temporary")" == "$SOURCE_BYTES" ]]
  [[ "$(file_md5 "$temporary")" == "$SOURCE_MD5" ]]
  mv "$temporary" "$SOURCE"
  log "$COUNTRY_NAME source size and MD5 verified."
}

build_graph() {
  if [[ -f "$ARCHIVE" && -f "$CONTROL/build.complete" ]]; then log "Reusing completed archive."; return; fi
  mkdir -p "$WORK" "$OUTPUT"
  [[ ! -e "$ARCHIVE" ]]
  log "Starting 12-core connected $COUNTRY_NAME Valhalla build."
  docker run --platform linux/amd64 --rm --network=none \
    --name "virbula-$GRAPH_ID-2026-08-1" \
    --volume "$WORK:/work" --volume "$SOURCE:/input/country.osm.pbf:ro" \
    --volume "$OUTPUT:/output" --env "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
    --env "ARCHIVE_NAME=$(basename "$ARCHIVE")" \
    --env "VALHALLA_BUILD_CONCURRENCY=$BUILD_CONCURRENCY" \
    --entrypoint /bin/bash "$IMAGE" -euo pipefail -c '
      trap "chmod -R a+rwX /work /output || true" EXIT
      mkdir -p /work/tiles
      valhalla_build_config --mjolnir-tile-dir /work/tiles \
        --mjolnir-tile-extract "/output/$ARCHIVE_NAME" \
        --mjolnir-admin /work/admins.sqlite \
        --mjolnir-concurrency "$VALHALLA_BUILD_CONCURRENCY" > /work/valhalla.json
      valhalla_build_admins -c /work/valhalla.json /input/country.osm.pbf
      test -s /work/admins.sqlite
      valhalla_build_tiles -c /work/valhalla.json /input/country.osm.pbf
      find /work/tiles -type f -name "*.gph" -printf "%P\n" | LC_ALL=C sort > /work/tile-list.txt
      test -s /work/tile-list.txt
      tar --create --file "/output/$ARCHIVE_NAME" --directory /work/tiles \
        --no-recursion --owner=0 --group=0 --numeric-owner \
        --mtime="@$SOURCE_DATE_EPOCH" --format=gnu --remove-files \
        --files-from /work/tile-list.txt
      test -s "/output/$ARCHIVE_NAME"
    '
  local bytes
  bytes="$(file_bytes "$ARCHIVE")"
  [[ "$bytes" -gt 0 && "$bytes" -le "$MAXIMUM_LOGICAL_BYTES" ]]
  tar --list --file "$ARCHIVE" | grep -Eq '^[0-3]/[0-9]{3}/[0-9]{3}\.gph$'
  file_sha256 "$ARCHIVE" > "$ARCHIVE.sha256"
  touch "$CONTROL/build.complete"
  log "Graph archive built: $bytes bytes."
}

validate_graph() {
  if [[ -f "$CONTROL/validation.complete" ]]; then log "Reusing completed validation."; return; fi
  log "Traversing every graph tile with Valhalla 3.6.3."
  docker run --platform linux/amd64 --rm --network=none \
    --volume "$ARCHIVE:/work/routing.vtiles.tar:ro" \
    --entrypoint /bin/bash "$IMAGE" -euo pipefail -c '
      test "$(valhalla_build_statistics --version 2>&1)" = "3.6.3"
      mkdir -p /tmp/empty-tiles
      valhalla_build_config --mjolnir-tile-dir /tmp/empty-tiles \
        --mjolnir-tile-extract /work/routing.vtiles.tar \
        --mjolnir-data-processing-use-admin-db false > /tmp/valhalla.json
      cd /tmp
      valhalla_build_statistics --config /tmp/valhalla.json --concurrency 12
      test -s statistics.sqlite
      rows="$(python3 -c '\''import sqlite3;c=sqlite3.connect("statistics.sqlite");print(c.execute("select count(*) from tiledata").fetchone()[0])'\'')"
      test "$rows" -gt 0
      printf "validated tile rows: %s\n" "$rows"
    ' | tee "$TILE_REPORT"

  log "Testing representative cross-boundary routes."
  docker run --platform linux/amd64 --rm --network=none \
    --volume "$ARCHIVE:/work/routing.vtiles.tar:ro" --env "ROUTE_CASES=$ROUTE_CASES" \
    --entrypoint /bin/bash "$IMAGE" -euo pipefail -c '
      mkdir -p /tmp/empty-tiles
      valhalla_build_config --mjolnir-tile-dir /tmp/empty-tiles \
        --mjolnir-tile-extract /work/routing.vtiles.tar \
        --mjolnir-data-processing-use-admin-db false > /tmp/valhalla.json
      valhalla_service /tmp/valhalla.json 1 >/tmp/service.log 2>&1 &
      service_pid=$!; trap '\''kill "$service_pid" 2>/dev/null || true'\'' EXIT
      ready=false
      for _ in $(seq 1 120); do
        if curl --fail --silent http://127.0.0.1:8002/status >/dev/null; then ready=true; break; fi
        sleep 1
      done
      if [[ "$ready" != true ]]; then cat /tmp/service.log >&2; exit 1; fi
      while IFS= read -r route; do
        test -n "$route"
        IFS="|" read -r name lat1 lon1 lat2 lon2 <<< "$route"
        curl --fail --silent --show-error --header "Content-Type: application/json" \
          --data "{\"locations\":[{\"lat\":$lat1,\"lon\":$lon1},{\"lat\":$lat2,\"lon\":$lon2}],\"costing\":\"auto\",\"directions_options\":{\"units\":\"kilometers\"}}" \
          http://127.0.0.1:8002/route > "/tmp/$name.json"
        python3 - "$name" "/tmp/$name.json" <<'\''PY'\''
import json, sys
name, response_path = sys.argv[1:]
with open(response_path, encoding="utf-8") as response:
    payload = json.load(response)
trip = payload.get("trip", {})
if not trip.get("legs") or trip.get("summary", {}).get("length", 0) <= 0:
    raise SystemExit(f"{name} failed: {payload}")
print(f"{name}: {trip['\''summary'\'']['\''length'\'']} km")
PY
      done <<< "$ROUTE_CASES"
    ' | tee "$ROUTE_REPORT"
  touch "$CONTROL/validation.complete"
}

split_and_describe() {
  if [[ -f "$CONTROL/split.complete" ]]; then log "Reusing verified parts."; return; fi
  mkdir -p "$PARTS"
  [[ -z "$(find "$PARTS" -type f -print -quit)" ]]
  local total part skip part_file rebuilt_sha
  total="$(file_bytes "$ARCHIVE")"; part=1; skip=0
  while [[ "$skip" -lt "$total" ]]; do
    part_file="$PARTS/$(basename "$ARCHIVE").part$(printf '%03d' "$part")"
    dd if="$ARCHIVE" of="$part_file" bs=1048576 skip="$((skip / 1048576))" count=1900
    [[ "$(file_bytes "$part_file")" -le "$PART_BYTES" ]]
    skip="$((skip + $(file_bytes "$part_file")))"; part="$((part + 1))"
  done
  rebuilt_sha="$(cat "$PARTS"/*.part[0-9][0-9][0-9] | shasum -a 256 | awk '{print $1}')"
  [[ "$rebuilt_sha" == "$(file_sha256 "$ARCHIVE")" ]]
  local parts_json="$CONTROL/$GRAPH_ID-parts.json"
  printf '[]\n' > "$parts_json"
  for part_file in "$PARTS"/*.part[0-9][0-9][0-9]; do
    jq --arg file "$(basename "$part_file")" --arg sha "$(file_sha256 "$part_file")" \
      --arg url "https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/$(basename "$part_file")" \
      --argjson bytes "$(file_bytes "$part_file")" \
      '.+[{file:$file,exactBytes:$bytes,sha256:$sha,downloadUrl:$url}]' \
      "$parts_json" > "$parts_json.tmp"; mv "$parts_json.tmp" "$parts_json"
  done
  jq -n --arg planSha "$(cat "$PLAN.sha256")" --arg graph "$GRAPH_ID" \
    --arg file "$(basename "$ARCHIVE")" --arg archiveSha "$(file_sha256 "$ARCHIVE")" \
    --arg sourceSha "$(file_sha256 "$SOURCE")" --arg sourceUrl "$SOURCE_URL" \
    --arg sourceMd5 "$SOURCE_MD5" --arg updated "$UPDATED_AT" --arg version "$VERSION" \
    --argjson archiveBytes "$(file_bytes "$ARCHIVE")" --argjson sourceBytes "$SOURCE_BYTES" \
    --argjson west "$BOUNDS_WEST" --argjson south "$BOUNDS_SOUTH" \
    --argjson east "$BOUNDS_EAST" --argjson north "$BOUNDS_NORTH" \
    --slurpfile parts "$parts_json" --slurpfile plan "$PLAN" \
    '{schemaVersion:2,routingPlanSha256:$planSha,graphId:$graph,regionIds:$plan[0].regionIds,
      routing:{format:"valhalla-tar",engine:"valhalla",engineVersion:"3.6.3",graphId:$graph,
      bounds:{west:$west,south:$south,east:$east,north:$north},file:$file,
      exactBytes:$archiveBytes,sha256:$archiveSha,sourceSha256:$sourceSha,
      sourceInput:{url:$sourceUrl,exactBytes:$sourceBytes,md5:$sourceMd5},parts:$parts[0],
      updatedAt:$updated,version:$version,modes:["driving","walking","bicycling"],
      attribution:"© OpenStreetMap contributors",attributionUrl:"https://www.openstreetmap.org/copyright",
      license:"ODbL-1.0",licenseUrl:"https://opendatacommons.org/licenses/odbl/1-0/",
      sourceProvider:"Geofabrik",sourceUrl:"https://download.geofabrik.de/"}}' > "$DESCRIPTOR"
  jq -e --argjson expected "$EXPECTED_REGION_COUNT" '.regionIds|length==$expected' "$DESCRIPTOR" >/dev/null
  touch "$CONTROL/split.complete"
  log "Archive split into $((part - 1)) verified parts."
}

upload_and_verify() {
  if [[ -f "$CONTROL/upload.complete" ]]; then log "Upload already verified."; return; fi
  local current_assets added_assets asset remote_bytes
  current_assets="$(gh api "repos/$REPOSITORY/releases/tags/$RELEASE_TAG" --jq '.assets|length')"
  added_assets="$(( $(find "$PARTS" -type f | wc -l | tr -d ' ') + 4 ))"
  [[ "$((current_assets + added_assets))" -le 1000 ]]
  for asset in "$PARTS"/*.part[0-9][0-9][0-9] "$PLAN" "$TILE_REPORT" "$ROUTE_REPORT"; do
    for attempt in 1 2 3 4 5; do
      if gh release upload "$RELEASE_TAG" "$asset" --repo "$REPOSITORY" --clobber; then break; fi
      [[ "$attempt" -lt 5 ]]; sleep "$((attempt * 10))"
    done
  done
  gh release upload "$RELEASE_TAG" "$DESCRIPTOR" --repo "$REPOSITORY" --clobber
  gh api "repos/$REPOSITORY/releases/tags/$RELEASE_TAG" > "$CONTROL/remote-release.json"
  for asset in "$PARTS"/*.part[0-9][0-9][0-9] "$PLAN" "$TILE_REPORT" "$ROUTE_REPORT" "$DESCRIPTOR"; do
    remote_bytes="$(jq -r --arg name "$(basename "$asset")" '.assets[]|select(.name==$name)|.size' "$CONTROL/remote-release.json")"
    [[ "$remote_bytes" == "$(file_bytes "$asset")" ]]
  done
  touch "$CONTROL/upload.complete"
  log "All remote assets and descriptor completion marker verified."
}

cleanup_uploaded_build() {
  [[ -f "$CONTROL/upload.complete" ]]
  [[ "$(jq -r '.tag_name' "$CONTROL/remote-release.json")" == "$RELEASE_TAG" ]]
  log "Reclaiming uploaded $COUNTRY_NAME build storage."
  rm -f "$SOURCE" "$SOURCE.download" "$ARCHIVE" "$ARCHIVE.sha256"
  rm -rf "$WORK" "$PARTS"
  touch "$CONTROL/cleanup.complete"
}

main() {
  mkdir -p "$ROOT" "$CONTROL" "$OUTPUT"
  if ! mkdir "$ROOT/.lock" 2>/dev/null; then log "$GRAPH_ID is already running."; exit 2; fi
  trap 'rmdir "$ROOT/.lock" 2>/dev/null || true' EXIT
  exec > >(tee -a "$LOG") 2>&1
  log "Starting $GRAPH_ID in $RELEASE_TAG."
  write_plan; preflight; require_source; preflight; build_graph
  validate_graph; split_and_describe; upload_and_verify; cleanup_uploaded_build
  log "$GRAPH_ID completed successfully."
  if [[ "$COUNTRY_CODE" == "US" ]]; then
    log "US accepted; continuing with Canada."
    env COUNTRY_CODE=CA /bin/bash "$0"
  fi
}

main "$@"
