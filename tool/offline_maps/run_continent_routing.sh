#!/bin/bash
set -euo pipefail

readonly RELEASE_TAG="routing-continents-2026.08.1"
readonly VERSION="2026.08.1"
readonly UPDATED_AT="2026-08-15T00:30:00.000Z"
readonly SOURCE_DATE_EPOCH="1786753800"
readonly IMAGE="ghcr.io/valhalla/valhalla:3.6.3@sha256:0cf1520c6a38b8a7e13a1931541e0ab6e9e42b64b4ca014293b6b8373d493160"
readonly RELEASE_PLAN_SHA="7725fa807a720a4df95593de799921e47a37ce09aa460d91acdab8675440d134"
readonly REPOSITORY="virbula/offlinemaps"
readonly PART_BYTES="1992294400"
readonly BUILD_CONCURRENCY="12"
readonly MAXIMUM_LOGICAL_BYTES="$((128 * 1024 * 1024 * 1024))"
readonly PAUSE_FREE_BYTES="$((25 * 1024 * 1024 * 1024))"
readonly RESUME_FREE_BYTES="$((40 * 1024 * 1024 * 1024))"
readonly SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/../.." && pwd)"
readonly WORK_ROOT="${CONTINENT_ROUTING_WORK_ROOT:-$REPOSITORY_ROOT/build/continent-routing}"
readonly CONTINENT_CODE="${CONTINENT_CODE:-}"
readonly CONTINENT_SEQUENCE=(AN OC SA AF AS NA EU)

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
file_bytes() { stat -f '%z' "$1"; }
file_sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
file_md5() { md5 -q "$1"; }
free_disk_bytes() { printf '%s\n' "$(( $(df -Pk "$WORK_ROOT" | awk 'NR==2 {print $4}') * 1024 ))"; }

release_json() {
  gh api "repos/$REPOSITORY/releases?per_page=100" |
    jq -ec --arg tag "$RELEASE_TAG" '[.[]|select(.tag_name==$tag)] | if length==1 then .[0] else error("release identity mismatch") end'
}

ensure_release() {
  local releases existing attempt
  mkdir -p "$WORK_ROOT"
  releases="$(gh api "repos/$REPOSITORY/releases?per_page=100")"
  existing="$(jq -c --arg tag "$RELEASE_TAG" '[.[]|select(.tag_name==$tag)]' <<< "$releases")"
  if [[ "$(jq 'length' <<< "$existing")" == 0 ]]; then
    gh release create "$RELEASE_TAG" --repo "$REPOSITORY" --target main --draft \
      --title "Continent routing graphs $VERSION" \
      --notes "Optional, user-selected offline Valhalla 3.6.3 routing graphs for every continent. This release does not modify or supersede the existing regional routing plan, routing catalog, or default downloads; full U.S./Canada and continent graphs remain explicit large-download choices. Assets are published only after deterministic source verification, full-tile traversal, representative boundary routing tests, multipart verification, and remote size checks."
    releases="$(gh api "repos/$REPOSITORY/releases?per_page=100")"
    existing="$(jq -c --arg tag "$RELEASE_TAG" '[.[]|select(.tag_name==$tag)]' <<< "$releases")"
  fi
  # GitHub's releases list can briefly return stale state immediately after
  # draft creation. Wait for the exact release to be observable as a draft.
  if [[ "$(jq -r '.[0].draft // false' <<< "$existing")" != true ]]; then
    for attempt in 1 2 3 4 5 6; do
      sleep 5
      releases="$(gh api "repos/$REPOSITORY/releases?per_page=100")"
      existing="$(jq -c --arg tag "$RELEASE_TAG" '[.[]|select(.tag_name==$tag)]' <<< "$releases")"
      [[ "$(jq -r '.[0].draft // false' <<< "$existing")" == true ]] && break
    done
  fi
  [[ "$(jq 'length' <<< "$existing")" == 1 ]]
  [[ "$(jq -r '.[0].tag_name' <<< "$existing")" == "$RELEASE_TAG" ]]
  [[ "$(jq -r '.[0].prerelease' <<< "$existing")" == false ]]
  if [[ "$(jq -r '.[0].draft' <<< "$existing")" != true && ! -f "$WORK_ROOT/release.complete" ]]; then
    log "Release is public without a local completion marker; refusing mutation."
    exit 2
  fi
}

continent_identity() {
  case "$1" in
    AN) printf '%s|%s\n' "Antarctica" "antarctica-continent" ;;
    OC) printf '%s|%s\n' "Australia and Oceania" "oceania-continent" ;;
    SA) printf '%s|%s\n' "South America" "south-america-continent" ;;
    AF) printf '%s|%s\n' "Africa" "africa-continent" ;;
    AS) printf '%s|%s\n' "Asia" "asia-continent" ;;
    NA) printf '%s|%s\n' "North America" "north-america-continent" ;;
    EU) printf '%s|%s\n' "Europe" "europe-continent" ;;
    *) return 2 ;;
  esac
}

configure_continent() {
  case "$CONTINENT_CODE" in
    AN)
      CONTINENT_NAME="Antarctica"; GRAPH_ID="antarctica-continent"; EXPECTED_REGION_COUNT="0"; MINIMUM_BUILD_FREE_BYTES="$((40 * 1024 * 1024 * 1024))"
      SOURCE_SPECS=$'https://download.geofabrik.de/antarctica-260814.osm.pbf|33091136|5c128c595a1b697caae215ff278d6777'
      ROUTE_CASES=$'mcmurdo-scott|pedestrian|-77.8463|166.6682|-77.8492|166.7681'
      ;;
    OC)
      CONTINENT_NAME="Australia and Oceania"; GRAPH_ID="oceania-continent"; EXPECTED_REGION_COUNT="39"; MINIMUM_BUILD_FREE_BYTES="$((60 * 1024 * 1024 * 1024))"
      SOURCE_SPECS=$'https://download.geofabrik.de/australia-oceania-260814.osm.pbf|1557199151|5f04af88d6857a72a89a82020954d8fe'
      ROUTE_CASES=$'nsw-vic|auto|-36.0737|146.9135|-36.1215|146.8881'
      ;;
    SA)
      CONTINENT_NAME="South America"; GRAPH_ID="south-america-continent"; EXPECTED_REGION_COUNT="41"; MINIMUM_BUILD_FREE_BYTES="$((80 * 1024 * 1024 * 1024))"
      SOURCE_SPECS=$'https://download.geofabrik.de/south-america-260814.osm.pbf|4093998642|c456aa5f517ffd7c801a31f237a757eb'
      ROUTE_CASES=$'br-py|auto|-25.5162|-54.5854|-25.5097|-54.6111\npe-cl|auto|-18.0135|-70.2504|-18.4783|-70.3126'
      ;;
    AF)
      CONTINENT_NAME="Africa"; GRAPH_ID="africa-continent"; EXPECTED_REGION_COUNT="71"; MINIMUM_BUILD_FREE_BYTES="$((100 * 1024 * 1024 * 1024))"
      SOURCE_SPECS=$'https://download.geofabrik.de/africa-260814.osm.pbf|7899468334|e5fe8d64e13ba4d3f68a119dd9bd64fa'
      ROUTE_CASES=$'gh-tg|auto|6.1194|1.1903|6.1375|1.2123\nza-sz|auto|-25.9692|31.2453|-26.3054|31.1367'
      ;;
    AS)
      CONTINENT_NAME="Asia"; GRAPH_ID="asia-continent"; EXPECTED_REGION_COUNT="153"; MINIMUM_BUILD_FREE_BYTES="$((150 * 1024 * 1024 * 1024))"
      SOURCE_SPECS=$'https://download.geofabrik.de/asia-260814.osm.pbf|16166183028|27a2625e8dbc2638e68d65e3ee7ae238'
      ROUTE_CASES=$'my-sg|auto|1.4560|103.7640|1.3521|103.8198\nth-kh|auto|13.6892|102.5028|13.6562|102.5625'
      ;;
    NA)
      CONTINENT_NAME="North America"; GRAPH_ID="north-america-continent"; EXPECTED_REGION_COUNT="104"; MINIMUM_BUILD_FREE_BYTES="$((180 * 1024 * 1024 * 1024))"
      SOURCE_SPECS=$'https://download.geofabrik.de/north-america-260814.osm.pbf|19265309961|692fa2bbdea75c9d0ffd0b1dd6d0b15c\nhttps://download.geofabrik.de/central-america-260814.osm.pbf|786559652|d57073a4720b01ee55523008d2313465'
      ROUTE_CASES=$'ca-us|auto|49.2827|-123.1207|47.6062|-122.3321\nus-mx|auto|32.7157|-117.1611|32.5149|-117.0382\nmx-gt|auto|14.9222|-92.2600|14.6407|-92.1420'
      ;;
    EU)
      CONTINENT_NAME="Europe"; GRAPH_ID="europe-continent"; EXPECTED_REGION_COUNT="145"; MINIMUM_BUILD_FREE_BYTES="$((180 * 1024 * 1024 * 1024))"
      SOURCE_SPECS=$'https://download.geofabrik.de/europe-260814.osm.pbf|34799173976|71ea263008932568d0f15f1005b2c263'
      ROUTE_CASES=$'fr-be|auto|50.8503|4.3517|48.8566|2.3522\nde-cz|auto|52.5200|13.4050|50.0755|14.4378\nes-pt|auto|38.8794|-6.9707|38.8815|-7.1628'
      ;;
    *)
      printf 'Unsupported continent code: %s\n' "$CONTINENT_CODE" >&2
      exit 2
      ;;
  esac
  readonly CONTINENT_NAME GRAPH_ID EXPECTED_REGION_COUNT MINIMUM_BUILD_FREE_BYTES SOURCE_SPECS ROUTE_CASES
  readonly ROOT="$WORK_ROOT/$GRAPH_ID"
  readonly CONTROL="$ROOT/control"
  readonly SOURCE_DIR="$ROOT/source"
  readonly WORK="$ROOT/work"
  readonly OUTPUT="$ROOT/output"
  readonly PARTS="$ROOT/parts"
  readonly LOG="$ROOT/$GRAPH_ID.log"
  readonly ARCHIVE="$OUTPUT/$GRAPH_ID-routing-$VERSION.vtiles.tar"
  readonly DESCRIPTOR="$OUTPUT/$GRAPH_ID-routing-$VERSION.vtiles.descriptor.json"
  readonly PLAN="$CONTROL/$GRAPH_ID-plan.json"
  readonly REGION_PLAN="$CONTROL/routing-plan.json"
  readonly SOURCE_FILES="$CONTROL/$GRAPH_ID-sources.json"
  readonly TILE_REPORT="$CONTROL/$GRAPH_ID-tile-validation.txt"
  readonly ROUTE_REPORT="$CONTROL/$GRAPH_ID-boundary-routes.txt"
}

write_plan() {
  mkdir -p "$CONTROL"
  if [[ ! -f "$REGION_PLAN" ]] || [[ "$(file_sha256 "$REGION_PLAN")" != "$RELEASE_PLAN_SHA" ]]; then
    gh release download "routing-2026.08.1" --repo "$REPOSITORY" \
      --pattern routing-plan.json --dir "$CONTROL" --clobber
  fi
  [[ "$(file_sha256 "$REGION_PLAN")" == "$RELEASE_PLAN_SHA" ]]
  local sources='[]' url bytes md5
  while IFS='|' read -r url bytes md5; do
    sources="$(jq -c --arg url "$url" --arg md5 "$md5" --argjson bytes "$bytes" '.+[{url:$url,exactBytes:$bytes,md5:$md5}]' <<< "$sources")"
  done <<< "$SOURCE_SPECS"
  if [[ "$CONTINENT_CODE" == AN ]]; then
    jq -n --arg tag "$RELEASE_TAG" --arg graph "$GRAPH_ID" --arg continent "$CONTINENT_CODE" \
      --arg name "$CONTINENT_NAME" --arg version "$VERSION" --arg updated "$UPDATED_AT" \
      --arg image "$IMAGE" --argjson concurrency "$BUILD_CONCURRENCY" --argjson sources "$sources" \
      '{schemaVersion:1,releaseTag:$tag,graphId:$graph,continentCode:$continent,
        continentName:$name,version:$version,updatedAt:$updated,
        bundleType:"continent-routing",selectionMode:"optional",default:false,
        supersedesExistingRouting:false,catalogIntegrated:false,
        builder:{engine:"valhalla",version:"3.6.3",image:$image,concurrency:$concurrency},
        sources:$sources,regionIds:[],bounds:{west:-180,south:-90,east:180,north:-60}}' > "$PLAN.tmp"
  else
    jq --arg tag "$RELEASE_TAG" --arg graph "$GRAPH_ID" --arg continent "$CONTINENT_CODE" \
      --arg name "$CONTINENT_NAME" --arg version "$VERSION" --arg updated "$UPDATED_AT" \
      --arg image "$IMAGE" --argjson concurrency "$BUILD_CONCURRENCY" --argjson sources "$sources" \
      '[.regions[]|select(.continent==$continent)] as $regions |
       {schemaVersion:1,releaseTag:$tag,graphId:$graph,continentCode:$continent,
        continentName:$name,version:$version,updatedAt:$updated,
        bundleType:"continent-routing",selectionMode:"optional",default:false,
        supersedesExistingRouting:false,catalogIntegrated:false,
        builder:{engine:"valhalla",version:"3.6.3",image:$image,concurrency:$concurrency},
        sources:$sources,regionIds:([$regions[].id]|sort),
        bounds:{west:([$regions[].extract.bounds.west]|min),south:([$regions[].extract.bounds.south]|min),
                east:([$regions[].extract.bounds.east]|max),north:([$regions[].extract.bounds.north]|max)}}' \
      "$REGION_PLAN" > "$PLAN.tmp"
  fi
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
  free_disk="$(free_disk_bytes)"
  [[ "$memory" -ge $((64 * 1024 * 1024 * 1024)) ]]
  [[ "$docker_memory" -ge $((60 * 1024 * 1024 * 1024)) ]]
  [[ "$free_disk" -ge "$MINIMUM_BUILD_FREE_BYTES" ]]
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then docker pull --platform linux/amd64 "$IMAGE"; fi
  log "Capacity accepted: hostMemory=$memory dockerMemory=$docker_memory freeDisk=$free_disk minimum=$MINIMUM_BUILD_FREE_BYTES."
}

require_sources() {
  mkdir -p "$SOURCE_DIR"
  printf '[]\n' > "$SOURCE_FILES.tmp"
  local url expected_bytes expected_md5 source temporary actual_sha
  while IFS='|' read -r url expected_bytes expected_md5; do
    source="$SOURCE_DIR/$(basename "$url")"
    if [[ ! -f "$source" ]] || [[ "$(file_bytes "$source")" != "$expected_bytes" ]] || [[ "$(file_md5 "$source")" != "$expected_md5" ]]; then
      temporary="$source.download"
      log "Downloading pinned $(basename "$url") ($expected_bytes bytes)."
      curl --fail --location --retry 8 --retry-all-errors --continue-at - --output "$temporary" "$url"
      [[ "$(file_bytes "$temporary")" == "$expected_bytes" ]]
      [[ "$(file_md5 "$temporary")" == "$expected_md5" ]]
      mv "$temporary" "$source"
    fi
    actual_sha="$(file_sha256 "$source")"
    jq --arg file "$(basename "$source")" --arg url "$url" --arg md5 "$expected_md5" \
      --arg sha "$actual_sha" --argjson bytes "$expected_bytes" \
      '.+[{file:$file,url:$url,exactBytes:$bytes,md5:$md5,sha256:$sha}]' \
      "$SOURCE_FILES.tmp" > "$SOURCE_FILES.next"
    mv "$SOURCE_FILES.next" "$SOURCE_FILES.tmp"
    log "Verified $(basename "$source") size, MD5, and SHA-256."
  done <<< "$SOURCE_SPECS"
  mv "$SOURCE_FILES.tmp" "$SOURCE_FILES"
}

monitor_container_disk() {
  local container_name="$1" marker="$2" paused=false free
  while true; do
    free="$(free_disk_bytes)"
    printf '%s freeDiskBytes=%s container=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$free" "$container_name" >> "$CONTROL/disk-usage.log"
    if [[ "$free" -lt "$PAUSE_FREE_BYTES" && "$paused" == false ]] && docker inspect "$container_name" >/dev/null 2>&1; then
      docker pause "$container_name"
      paused=true
      touch "$marker"
      log "DISK WARNING: paused $container_name with only $free bytes free; free space to at least $RESUME_FREE_BYTES bytes."
    elif [[ "$paused" == true && "$free" -ge "$RESUME_FREE_BYTES" ]]; then
      docker unpause "$container_name"
      paused=false
      log "Disk recovered to $free bytes; resumed $container_name."
    fi
    sleep 60
  done
}

build_graph() {
  if [[ -f "$ARCHIVE" && -f "$CONTROL/build.complete" ]]; then log "Reusing completed archive."; return; fi
  mkdir -p "$WORK" "$OUTPUT"
  [[ ! -e "$ARCHIVE" ]]
  local container_name="virbula-$GRAPH_ID-2026-08-1" url expected_bytes expected_md5 source index monitor_pid status
  local docker_args=(run --platform linux/amd64 --rm --network=none --name "$container_name" \
    --volume "$WORK:/work" --volume "$OUTPUT:/output" \
    --env "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" --env "ARCHIVE_NAME=$(basename "$ARCHIVE")" \
    --env "VALHALLA_BUILD_CONCURRENCY=$BUILD_CONCURRENCY")
  index=1
  while IFS='|' read -r url expected_bytes expected_md5; do
    source="$SOURCE_DIR/$(basename "$url")"
    docker_args+=(--volume "$source:/input/$(printf '%03d' "$index")-$(basename "$source"):ro")
    index="$((index + 1))"
  done <<< "$SOURCE_SPECS"
  log "Starting 12-core connected $CONTINENT_NAME Valhalla build with $((index - 1)) source extract(s)."
  monitor_container_disk "$container_name" "$CONTROL/disk-space.low" &
  monitor_pid="$!"
  set +e
  docker "${docker_args[@]}" --entrypoint /bin/bash "$IMAGE" -euo pipefail -c '
    trap "chmod -R a+rwX /work /output || true" EXIT
    mkdir -p /work/tiles
    mapfile -t inputs < <(find /input -maxdepth 1 -type f -name "*.osm.pbf" -print | LC_ALL=C sort)
    test "${#inputs[@]}" -ge 1
    valhalla_build_config --mjolnir-tile-dir /work/tiles \
      --mjolnir-tile-extract "/output/$ARCHIVE_NAME" \
      --mjolnir-admin /work/admins.sqlite \
      --mjolnir-concurrency "$VALHALLA_BUILD_CONCURRENCY" > /work/valhalla.json
    valhalla_build_admins -c /work/valhalla.json "${inputs[@]}"
    test -s /work/admins.sqlite
    valhalla_build_tiles -c /work/valhalla.json "${inputs[@]}"
    find /work/tiles -type f -name "*.gph" -printf "%P\n" | LC_ALL=C sort > /work/tile-list.txt
    test -s /work/tile-list.txt
    tar --create --file "/output/$ARCHIVE_NAME" --directory /work/tiles \
      --no-recursion --owner=0 --group=0 --numeric-owner \
      --mtime="@$SOURCE_DATE_EPOCH" --format=gnu --remove-files \
      --files-from /work/tile-list.txt
    test -s "/output/$ARCHIVE_NAME"
  '
  status="$?"
  set -e
  kill "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true
  [[ "$status" == 0 ]]
  local bytes
  bytes="$(file_bytes "$ARCHIVE")"
  [[ "$bytes" -gt 0 && "$bytes" -le "$MAXIMUM_LOGICAL_BYTES" ]]
  tar --list --file "$ARCHIVE" | awk '/^[0-3]\/[-0-9][0-9][0-9]\/[-0-9][0-9][0-9]\.gph$/ {found=1} END {exit found?0:1}'
  file_sha256 "$ARCHIVE" > "$ARCHIVE.sha256"
  touch "$CONTROL/build.complete"
  log "Graph archive built: $bytes bytes; freeDisk=$(free_disk_bytes)."
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
        IFS="|" read -r name costing lat1 lon1 lat2 lon2 <<< "$route"
        curl --fail --silent --show-error --header "Content-Type: application/json" \
          --data "{\"locations\":[{\"lat\":$lat1,\"lon\":$lon1},{\"lat\":$lat2,\"lon\":$lon2}],\"costing\":\"$costing\",\"directions_options\":{\"units\":\"kilometers\"}}" \
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
  local source_set_sha
  source_set_sha="$(jq -cS . "$SOURCE_FILES" | shasum -a 256 | awk '{print $1}')"
  jq -n --arg planSha "$(cat "$PLAN.sha256")" --arg graph "$GRAPH_ID" \
    --arg continent "$CONTINENT_CODE" --arg continentName "$CONTINENT_NAME" \
    --arg file "$(basename "$ARCHIVE")" --arg archiveSha "$(file_sha256 "$ARCHIVE")" \
    --arg sourceSetSha "$source_set_sha" --arg updated "$UPDATED_AT" --arg version "$VERSION" \
    --argjson archiveBytes "$(file_bytes "$ARCHIVE")" --slurpfile parts "$parts_json" \
    --slurpfile plan "$PLAN" --slurpfile sources "$SOURCE_FILES" \
    '{schemaVersion:3,routingPlanSha256:$planSha,graphId:$graph,continentCode:$continent,
      continentName:$continentName,regionIds:$plan[0].regionIds,
      bundleType:"continent-routing",selectionMode:"optional",default:false,
      supersedesExistingRouting:false,catalogIntegrated:false,
      routing:{format:"valhalla-tar",engine:"valhalla",engineVersion:"3.6.3",graphId:$graph,
      bounds:$plan[0].bounds,file:$file,exactBytes:$archiveBytes,sha256:$archiveSha,
      sourceSetSha256:$sourceSetSha,sourceInputs:$sources[0],parts:$parts[0],
      updatedAt:$updated,version:$version,modes:["driving","walking","bicycling"],
      attribution:"© OpenStreetMap contributors",attributionUrl:"https://www.openstreetmap.org/copyright",
      license:"ODbL-1.0",licenseUrl:"https://opendatacommons.org/licenses/odbl/1-0/",
      sourceProvider:"Geofabrik",sourceUrl:"https://download.geofabrik.de/"}}' > "$DESCRIPTOR"
  jq -e --argjson expected "$EXPECTED_REGION_COUNT" '.regionIds|length==$expected' "$DESCRIPTOR" >/dev/null
  touch "$CONTROL/split.complete"
  log "Archive split into $((part - 1)) verified parts; freeDisk=$(free_disk_bytes)."
}

upload_and_verify() {
  if [[ -f "$CONTROL/upload.complete" ]]; then log "Upload already verified."; return; fi
  local remote current_assets added_assets asset remote_bytes
  remote="$(release_json)"
  [[ "$(jq -r '.draft' <<< "$remote")" == true ]]
  current_assets="$(jq '.assets|length' <<< "$remote")"
  added_assets="$(( $(find "$PARTS" -type f | wc -l | tr -d ' ') + 4 ))"
  [[ "$((current_assets + added_assets))" -le 1000 ]]
  for asset in "$PARTS"/*.part[0-9][0-9][0-9] "$PLAN" "$TILE_REPORT" "$ROUTE_REPORT"; do
    for attempt in 1 2 3 4 5; do
      if gh release upload "$RELEASE_TAG" "$asset" --repo "$REPOSITORY" --clobber; then break; fi
      [[ "$attempt" -lt 5 ]]; sleep "$((attempt * 10))"
    done
  done
  gh release upload "$RELEASE_TAG" "$DESCRIPTOR" --repo "$REPOSITORY" --clobber
  release_json > "$CONTROL/remote-release.json"
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
  log "Reclaiming uploaded $CONTINENT_NAME build storage."
  local url expected_bytes expected_md5 source
  while IFS='|' read -r url expected_bytes expected_md5; do
    source="$SOURCE_DIR/$(basename "$url")"
    rm -f "$source" "$source.download"
  done <<< "$SOURCE_SPECS"
  rm -f "$ARCHIVE" "$ARCHIVE.sha256"
  rm -rf "$WORK" "$PARTS"
  touch "$CONTROL/cleanup.complete"
}

run_one_continent() {
  configure_continent
  mkdir -p "$ROOT" "$CONTROL" "$OUTPUT"
  if [[ -f "$CONTROL/cleanup.complete" && -f "$CONTROL/upload.complete" ]]; then
    log "$GRAPH_ID is already complete and cleaned."
    return
  fi
  if ! mkdir "$ROOT/.lock" 2>/dev/null; then log "$GRAPH_ID is already running."; exit 2; fi
  trap 'rmdir "$ROOT/.lock" 2>/dev/null || true' EXIT
  exec > >(tee -a "$LOG") 2>&1
  log "Starting $GRAPH_ID in $RELEASE_TAG."
  write_plan; preflight; require_sources; preflight; build_graph
  validate_graph; split_and_describe; upload_and_verify; cleanup_uploaded_build
  log "$GRAPH_ID completed successfully; freeDisk=$(free_disk_bytes)."
}

finalize_release() {
  local code identity continent_name graph_id root control descriptor descriptors='[]' remote_bytes
  for code in "${CONTINENT_SEQUENCE[@]}"; do
    identity="$(continent_identity "$code")"
    IFS='|' read -r continent_name graph_id <<< "$identity"
    root="$WORK_ROOT/$graph_id"
    control="$root/control"
    descriptor="$root/output/$graph_id-routing-$VERSION.vtiles.descriptor.json"
    [[ -f "$control/upload.complete" && -f "$control/cleanup.complete" && -s "$descriptor" ]]
    descriptors="$(jq -c --arg graph "$graph_id" --arg continent "$code" \
      --arg name "$continent_name" --arg file "$(basename "$descriptor")" \
      --arg sha "$(file_sha256 "$descriptor")" --argjson bytes "$(file_bytes "$descriptor")" \
      --arg url "https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/$(basename "$descriptor")" \
      '.+[{graphId:$graph,continentCode:$continent,continentName:$name,descriptorFile:$file,
           descriptorExactBytes:$bytes,descriptorSha256:$sha,descriptorUrl:$url}]' <<< "$descriptors")"
  done
  local index="$WORK_ROOT/continent-routing-index-$VERSION.json"
  jq -n --arg tag "$RELEASE_TAG" --arg version "$VERSION" --arg updated "$UPDATED_AT" \
    --argjson graphs "$descriptors" \
    '{schemaVersion:1,releaseTag:$tag,version:$version,updatedAt:$updated,
      bundleType:"continent-routing",selectionMode:"optional",default:false,
      supersedesExistingRouting:false,catalogIntegrated:false,graphs:$graphs}' > "$index"
  gh release upload "$RELEASE_TAG" "$index" --repo "$REPOSITORY" --clobber
  remote_bytes="$(release_json | jq -r --arg name "$(basename "$index")" '.assets[]|select(.name==$name)|.size')"
  [[ "$remote_bytes" == "$(file_bytes "$index")" ]]
  gh release edit "$RELEASE_TAG" --repo "$REPOSITORY" --draft=false --prerelease=false --latest=false
  [[ "$(release_json | jq -r '.draft')" == false ]]
  touch "$WORK_ROOT/release.complete"
  log "Published $RELEASE_TAG with all continent descriptors and final index."
}

main() {
  mkdir -p "$WORK_ROOT"
  ensure_release
  if [[ -n "$CONTINENT_CODE" ]]; then
    run_one_continent
    return
  fi
  for code in "${CONTINENT_SEQUENCE[@]}"; do
    env CONTINENT_CODE="$code" /bin/bash "$0"
  done
  finalize_release
}

main "$@"
