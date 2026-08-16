DART ?= dart
PMTILES_VERSION := 1.30.1
PMTILES ?= build/tools/pmtiles
PMTILES_DARWIN_ARM64_SHA256 := 36a675972c0032064c5f7bc7a39e47d7f3a8c618de216b76d3a403d10e176acf
PMTILES_DARWIN_X64_SHA256 := 60c84fc6213cb0f4ef39c6926bbc4dd2327e77b53d182f994c2e87e5c3cd9b4c
PMTILES_LINUX_ARM64_SHA256 := a1f9f42d8317ab1fadc25dd050e208547f32a3f99a4b90e7cb8fd6030f143d8e
PMTILES_LINUX_X64_SHA256 := 23a2a2222f658320b539ccd06ac3b9b3b803ecbdd39a6cb5249d2ce2e16e38ae
TIPPECANOE_VERSION := 2.77.0
TIPPECANOE_SOURCE_SHA256 := 4cb152a705250ab37f09d02610df376599c4423efbda96b65ad26f41a966d29e
TILE_JOIN ?= build/tools/tile-join
VALHALLA_VERSION := 3.6.3
VALHALLA_IMAGE := ghcr.io/valhalla/valhalla:$(VALHALLA_VERSION)@sha256:0cf1520c6a38b8a7e13a1931541e0ab6e9e42b64b4ca014293b6b8373d493160

OFFLINE_MAP_BUILD_CONFIG ?= config/offline-map-build.json
OFFLINE_MAP_BUILD_DIR ?= build/local
OFFLINE_MAP_CACHE_DIR ?= $(OFFLINE_MAP_BUILD_DIR)/cache
OFFLINE_MAP_GENERATED_DIR ?= $(OFFLINE_MAP_BUILD_DIR)/generated
OFFLINE_MAP_GENERATED_CONFIG ?= $(OFFLINE_MAP_GENERATED_DIR)/worldwide-manifest.json
OFFLINE_MAP_DISCOVERED_CONFIG ?= $(OFFLINE_MAP_GENERATED_DIR)/source-with-routing.json
OFFLINE_MAP_STAGING_DIR ?= $(OFFLINE_MAP_BUILD_DIR)/staging
OFFLINE_MAP_OUTPUT_DIR ?= $(OFFLINE_MAP_BUILD_DIR)/output
OFFLINE_MAP_TRACKED_METADATA_DIR ?= .
OFFLINE_MAP_BUILD_FLAGS ?=
OFFLINE_MAP_PUBLISH_FLAGS ?=
OFFLINE_MAP_PUBLISH_CONFIRM ?=
OFFLINE_ROUTING_PUBLISH_CONFIRM ?=
OFFLINE_ROUTING_FIXTURE_OUTPUT ?= build/fixtures/andorra-3.6.3.vtiles.tar
OFFLINE_ROUTING_GRAPH_ID ?=
OFFLINE_ROUTING_GRAPH_OUTPUT_DIR ?= $(OFFLINE_MAP_BUILD_DIR)/routing-graphs
OFFLINE_ROUTING_GRAPH_WORK_DIR ?= $(OFFLINE_MAP_BUILD_DIR)/routing-work

OFFLINE_MAP_METADATA_FILES := catalog.json offline-regions.generated.json provenance.json SHA256SUMS

.DEFAULT_GOAL := check

.PHONY: deps
deps:
	$(DART) pub get --enforce-lockfile

.PHONY: tools
tools:
	@set -eu; \
		current="$$([ -x "$(PMTILES)" ] && "$(PMTILES)" version 2>/dev/null || true)"; \
		if echo "$$current" | grep -q "^pmtiles $(PMTILES_VERSION),"; then exit 0; fi; \
		os="$$(uname -s)"; arch="$$(uname -m)"; \
		case "$$os/$$arch" in \
			Darwin/arm64) asset="go-pmtiles-$(PMTILES_VERSION)_Darwin_arm64.zip"; sha="$(PMTILES_DARWIN_ARM64_SHA256)"; kind=zip ;; \
			Darwin/x86_64) asset="go-pmtiles-$(PMTILES_VERSION)_Darwin_x86_64.zip"; sha="$(PMTILES_DARWIN_X64_SHA256)"; kind=zip ;; \
			Linux/aarch64|Linux/arm64) asset="go-pmtiles_$(PMTILES_VERSION)_Linux_arm64.tar.gz"; sha="$(PMTILES_LINUX_ARM64_SHA256)"; kind=tgz ;; \
			Linux/x86_64|Linux/amd64) asset="go-pmtiles_$(PMTILES_VERSION)_Linux_x86_64.tar.gz"; sha="$(PMTILES_LINUX_X64_SHA256)"; kind=tgz ;; \
			*) echo "ERROR: unsupported PMTiles platform $$os/$$arch"; exit 1 ;; \
		esac; \
		mkdir -p "$(dir $(PMTILES))"; \
		archive="$(PMTILES).download"; \
		curl --fail --location --proto '=https' --tlsv1.2 \
		  "https://github.com/protomaps/go-pmtiles/releases/download/v$(PMTILES_VERSION)/$$asset" \
		  --output "$$archive"; \
		if command -v shasum >/dev/null 2>&1; then actual="$$(shasum -a 256 "$$archive" | awk '{print $$1}')"; \
		else actual="$$(sha256sum "$$archive" | awk '{print $$1}')"; fi; \
		test "$$actual" = "$$sha" || { echo "ERROR: PMTiles CLI checksum mismatch."; exit 1; }; \
		if [ "$$kind" = zip ]; then command -v unzip >/dev/null; unzip -oq "$$archive" -d "$(dir $(PMTILES))"; \
		else tar --extract --gzip --file "$$archive" --directory "$(dir $(PMTILES))" pmtiles; fi; \
		rm "$$archive"; chmod 0755 "$(PMTILES)"; \
		"$(PMTILES)" version | grep -F "pmtiles $(PMTILES_VERSION),"

.PHONY: poi_tools
poi_tools: tools
	@set -eu; \
		stamp="$(TILE_JOIN).version"; \
		expected="$(TIPPECANOE_VERSION):$(TIPPECANOE_SOURCE_SHA256)"; \
		if [ -x "$(TILE_JOIN)" ] && [ -f "$$stamp" ] && [ "$$(tr -d '\n' < "$$stamp")" = "$$expected" ]; then exit 0; fi; \
		mkdir -p "$(dir $(TILE_JOIN))"; \
		archive="$(TILE_JOIN).source.tar.gz"; \
		source="$(TILE_JOIN).source"; \
		curl --fail --location --proto '=https' --tlsv1.2 \
		  "https://github.com/felt/tippecanoe/archive/refs/tags/$(TIPPECANOE_VERSION).tar.gz" \
		  --output "$$archive"; \
		if command -v shasum >/dev/null 2>&1; then actual="$$(shasum -a 256 "$$archive" | awk '{print $$1}')"; \
		else actual="$$(sha256sum "$$archive" | awk '{print $$1}')"; fi; \
		test "$$actual" = "$(TIPPECANOE_SOURCE_SHA256)" || { echo "ERROR: Tippecanoe source checksum mismatch."; exit 1; }; \
		rm -rf "$$source"; mkdir -p "$$source"; \
		tar --extract --gzip --file "$$archive" --directory "$$source" --strip-components=1; \
		$${MAKE:-make} -C "$$source" -j2 tile-join; \
		cp "$$source/tile-join" "$(TILE_JOIN).tmp"; chmod 0755 "$(TILE_JOIN).tmp"; \
		mv "$(TILE_JOIN).tmp" "$(TILE_JOIN)"; \
		printf '%s\n' "$$expected" > "$$stamp.tmp"; mv "$$stamp.tmp" "$$stamp"; \
		rm -rf "$$source" "$$archive"

.PHONY: check_offline_map_build_config
check_offline_map_build_config:
	@test -f "$(OFFLINE_MAP_BUILD_CONFIG)" || { \
		echo "ERROR: $(OFFLINE_MAP_BUILD_CONFIG) does not exist."; \
		exit 1; \
	}
	@! grep -q 'REPLACE_WITH_' "$(OFFLINE_MAP_BUILD_CONFIG)" || { \
		echo "ERROR: $(OFFLINE_MAP_BUILD_CONFIG) still contains placeholders."; \
		exit 1; \
	}

.PHONY: routing_tools
routing_tools:
	@command -v docker >/dev/null 2>&1 || { echo "ERROR: Docker is required for Valhalla routing builds."; exit 1; }
	@docker version >/dev/null 2>&1 || { echo "ERROR: Start the Docker daemon before building routing packs."; exit 1; }
	@image="$$(jq -er '.routingBuilder.image | select(type == "string")' "$(OFFLINE_MAP_BUILD_CONFIG)")"; \
		test "$$image" = "$(VALHALLA_IMAGE)" || { echo "ERROR: Makefile and manifest Valhalla pins differ."; exit 1; }; \
		if ! docker image inspect "$$image" >/dev/null 2>&1; then \
			for attempt in 1 2 3 4 5; do \
				docker pull --platform linux/amd64 "$$image" && break; \
				test "$$attempt" -lt 5 || exit 1; \
				sleep "$$((1 << (attempt - 1)))"; \
			done; \
		fi; \
		test "$$(docker image inspect "$$image" --format '{{.Os}}/{{.Architecture}}')" = linux/amd64

.PHONY: prepare_offline_map_tools
prepare_offline_map_tools: check_offline_map_build_config deps tools

.PHONY: build_offline_maps
build_offline_maps: prepare_offline_map_tools
	@routing_enabled="$$(jq -er '.routingDataset.enabled | select(type == "boolean")' "$(OFFLINE_MAP_BUILD_CONFIG)")"; \
		build_flags=" $(strip $(OFFLINE_MAP_BUILD_FLAGS)) "; \
		case "$$build_flags" in \
			*" --dry-run "*) requires_routing_tools=false ;; \
			*) requires_routing_tools=true ;; \
		esac; \
		if [ "$$routing_enabled" = true ] && [ "$$requires_routing_tools" = true ]; then \
			$(MAKE) routing_tools; \
		fi
	@echo "Offline-map source manifest:    $(OFFLINE_MAP_BUILD_CONFIG)"
	@echo "Offline-map generated manifest: $(OFFLINE_MAP_GENERATED_CONFIG)"
	@echo "Offline-map staging:            $(OFFLINE_MAP_STAGING_DIR)"
	@echo "Offline-map output:             $(OFFLINE_MAP_OUTPUT_DIR)"
	@echo "Offline-map cache:              $(OFFLINE_MAP_CACHE_DIR)"
	$(DART) run tool/offline_maps/discover_routing_sources.dart \
		--manifest "$(OFFLINE_MAP_BUILD_CONFIG)" \
		--output-manifest "$(OFFLINE_MAP_DISCOVERED_CONFIG)" \
		--cache-dir "$(OFFLINE_MAP_CACHE_DIR)/routing-sources"
	$(DART) run tool/offline_maps/generate_worldwide_regions.dart \
		--manifest "$(OFFLINE_MAP_DISCOVERED_CONFIG)" \
		--output-manifest "$(OFFLINE_MAP_GENERATED_CONFIG)" \
		--cache-dir "$(OFFLINE_MAP_CACHE_DIR)" \
		--builder-executable "$(PMTILES)"
	$(DART) run tool/offline_maps/build_all.dart \
		--manifest "$(OFFLINE_MAP_GENERATED_CONFIG)" \
		--staging-dir "$(OFFLINE_MAP_STAGING_DIR)" \
		--output-dir "$(OFFLINE_MAP_OUTPUT_DIR)" \
		--cache-dir "$(OFFLINE_MAP_CACHE_DIR)" $(OFFLINE_MAP_BUILD_FLAGS)
	@if [ -z "$(strip $(OFFLINE_MAP_BUILD_FLAGS))" ]; then \
		$(MAKE) sync_offline_map_metadata; \
	fi

.PHONY: build_offline_maps_with_routing
build_offline_maps_with_routing:
	@grep -q '"enabled": true' "$(OFFLINE_MAP_BUILD_CONFIG)" || { echo "ERROR: Enable routingDataset in $(OFFLINE_MAP_BUILD_CONFIG)."; exit 1; }
	$(MAKE) build_offline_maps
	@count="$$(sed -n 's/.*"routingAvailable": true.*/x/p' "$(OFFLINE_MAP_OUTPUT_DIR)/catalog.json" | wc -l | tr -d ' ')"; \
		test "$$count" -gt 0 || { echo "ERROR: Paired build produced zero routing packs."; exit 1; }

.PHONY: plan_offline_maps_with_routing
plan_offline_maps_with_routing:
	@grep -q '"enabled": true' "$(OFFLINE_MAP_BUILD_CONFIG)" || { echo "ERROR: Enable routingDataset in $(OFFLINE_MAP_BUILD_CONFIG)."; exit 1; }
	$(MAKE) build_offline_maps OFFLINE_MAP_BUILD_FLAGS=--dry-run

.PHONY: test_offline_routing_fixture
test_offline_routing_fixture: deps
	$(DART) test test/build_routing_test.dart test/build_all_test.dart

.PHONY: validate_offline_routing_container
validate_offline_routing_container: deps routing_tools
	$(DART) run tool/offline_maps/validate_routing_fixture.dart

.PHONY: build_offline_routing_fixture
build_offline_routing_fixture: deps routing_tools
	$(DART) run tool/offline_maps/validate_routing_fixture.dart \
		--output "$(OFFLINE_ROUTING_FIXTURE_OUTPUT)"

.PHONY: build_offline_routing_graph
build_offline_routing_graph: deps routing_tools
	@test -n "$(strip $(OFFLINE_ROUTING_GRAPH_ID))" || { \
		echo "ERROR: Set OFFLINE_ROUTING_GRAPH_ID to a graphId from $(OFFLINE_MAP_GENERATED_CONFIG)."; \
		exit 1; \
	}
	@test -f "$(OFFLINE_MAP_GENERATED_CONFIG)" || { \
		echo "ERROR: $(OFFLINE_MAP_GENERATED_CONFIG) does not exist. Run routing discovery and worldwide manifest generation first."; \
		exit 1; \
	}
	$(DART) run tool/offline_maps/build_routing_graph.dart \
		--manifest "$(OFFLINE_MAP_GENERATED_CONFIG)" \
		--graph-id "$(OFFLINE_ROUTING_GRAPH_ID)" \
		--output-dir "$(OFFLINE_ROUTING_GRAPH_OUTPUT_DIR)" \
		--cache-dir "$(OFFLINE_MAP_CACHE_DIR)/routing-source-$(OFFLINE_ROUTING_GRAPH_ID)" \
		--work-dir "$(OFFLINE_ROUTING_GRAPH_WORK_DIR)"

.PHONY: build_countrywide_routing
build_countrywide_routing: routing_tools
	./tool/offline_maps/run_countrywide_routing.sh

.PHONY: build_continent_routing
build_continent_routing: routing_tools
	./tool/offline_maps/run_continent_routing.sh

.PHONY: sync_offline_map_metadata
sync_offline_map_metadata:
	@set -eu; \
		if [ "$(abspath $(OFFLINE_MAP_OUTPUT_DIR))" = "$(abspath $(OFFLINE_MAP_TRACKED_METADATA_DIR))" ]; then exit 0; fi; \
		mkdir -p "$(OFFLINE_MAP_TRACKED_METADATA_DIR)"; \
		for name in $(OFFLINE_MAP_METADATA_FILES); do \
			source="$(OFFLINE_MAP_OUTPUT_DIR)/$$name"; \
			destination="$(OFFLINE_MAP_TRACKED_METADATA_DIR)/$$name"; \
			test -f "$$source" || { echo "ERROR: Missing generated metadata $$source."; exit 1; }; \
			temporary="$$destination.tmp"; \
			cp "$$source" "$$temporary"; \
			mv "$$temporary" "$$destination"; \
		done

.PHONY: plan_offline_maps
plan_offline_maps:
	$(MAKE) build_offline_maps OFFLINE_MAP_BUILD_FLAGS=--dry-run

.PHONY: validate_offline_maps
validate_offline_maps:
	$(MAKE) build_offline_maps OFFLINE_MAP_BUILD_FLAGS=--validate-only

.PHONY: validate_offline_map_release
validate_offline_map_release: deps
	@test -f "$(OFFLINE_MAP_GENERATED_CONFIG)" || { \
		echo "ERROR: Run make build_offline_maps first."; exit 1; \
	}
	@test -f "$(OFFLINE_MAP_OUTPUT_DIR)/catalog.json" || { \
		echo "ERROR: No completed local release bundle at $(OFFLINE_MAP_OUTPUT_DIR)."; exit 1; \
	}
	$(DART) run tool/offline_maps/publish_github.dart \
		--manifest "$(OFFLINE_MAP_GENERATED_CONFIG)" \
		--input-dir "$(OFFLINE_MAP_OUTPUT_DIR)" --dry-run

.PHONY: publish_offline_maps_github
publish_offline_maps_github: deps
	@command -v gh >/dev/null 2>&1 || { echo "ERROR: GitHub CLI (gh) is required."; exit 1; }
	@gh auth status --hostname github.com >/dev/null 2>&1 || { echo "ERROR: Sign in first with: gh auth login"; exit 1; }
	@test -f "$(OFFLINE_MAP_GENERATED_CONFIG)" || { \
		echo "ERROR: Run make build_offline_maps first."; exit 1; \
	}
	@test -f "$(OFFLINE_MAP_OUTPUT_DIR)/catalog.json" || { \
		echo "ERROR: No completed local release bundle at $(OFFLINE_MAP_OUTPUT_DIR)."; exit 1; \
	}
	@set -eu; \
		tag="$$(sed -n 's/.*"releaseTag": "\([^"]*\)".*/\1/p' "$(OFFLINE_MAP_GENERATED_CONFIG)" | head -n 1)"; \
		routing_tag="$$(sed -n 's/.*"releaseTag": "\(routing-[^"]*\)".*/\1/p' "$(OFFLINE_MAP_GENERATED_CONFIG)" | head -n 1)"; \
		echo "$$tag" | grep -Eq '^maps-[0-9]{4}\.[0-9]{2}\.[0-9]+$$'; \
		if printf '%s\n' "$(OFFLINE_MAP_PUBLISH_FLAGS)" | grep -Eq '(^|[[:space:]])--dry-run($$|[[:space:]])'; then :; \
		elif [ "$(OFFLINE_MAP_PUBLISH_CONFIRM)" != "$$tag" ]; then \
			echo "ERROR: Publishing mutates GitHub. Re-run with OFFLINE_MAP_PUBLISH_CONFIRM=$$tag"; \
			exit 1; \
		elif [ -n "$$routing_tag" ] && [ "$(OFFLINE_ROUTING_PUBLISH_CONFIRM)" != "$$routing_tag" ]; then \
			echo "ERROR: Paired routing publication also requires OFFLINE_ROUTING_PUBLISH_CONFIRM=$$routing_tag"; \
			exit 1; \
		fi
	$(DART) run tool/offline_maps/publish_github.dart \
		--manifest "$(OFFLINE_MAP_GENERATED_CONFIG)" \
		--input-dir "$(OFFLINE_MAP_OUTPUT_DIR)" $(OFFLINE_MAP_PUBLISH_FLAGS)

.PHONY: publish_offline_maps_with_routing_github
publish_offline_maps_with_routing_github: publish_offline_maps_github

.PHONY: check
check: deps
	$(DART) format --output=none --set-exit-if-changed tool test
	$(DART) analyze
	$(DART) test

.PHONY: test_poi_sidecars
test_poi_sidecars: deps poi_tools
	POI_INTEGRATION=true $(DART) test test/poi_sidecar_test.dart
