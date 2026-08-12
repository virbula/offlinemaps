DART ?= dart
PMTILES_VERSION := 1.30.1
PMTILES := build/tools/pmtiles
PMTILES_LINUX_X64_SHA256 := 23a2a2222f658320b539ccd06ac3b9b3b803ecbdd39a6cb5249d2ce2e16e38ae

.DEFAULT_GOAL := check

.PHONY: deps
deps:
	$(DART) pub get --enforce-lockfile

.PHONY: tools
tools:
	@set -eu; \
		mkdir -p build/tools; \
		archive=build/tools/pmtiles.tar.gz; \
		curl --fail --location --proto '=https' --tlsv1.2 \
		  "https://github.com/protomaps/go-pmtiles/releases/download/v$(PMTILES_VERSION)/go-pmtiles_$(PMTILES_VERSION)_Linux_x86_64.tar.gz" \
		  --output "$$archive"; \
		echo "$(PMTILES_LINUX_X64_SHA256)  $$archive" | sha256sum --check --strict; \
		tar --extract --gzip --file "$$archive" --directory build/tools pmtiles; \
		rm "$$archive"; chmod 0755 "$(PMTILES)"; \
		"$(PMTILES)" version | grep -F "pmtiles $(PMTILES_VERSION),"

.PHONY: check
check: deps
	$(DART) format --output=none --set-exit-if-changed tool test
	$(DART) analyze
	$(DART) test
