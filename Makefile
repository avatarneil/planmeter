.PHONY: build check-version test linux-build linux-test linux-smoke app signed-app release-macos run install install-mcp clean

build:
	swift build

check-version:
	./scripts/check-version.sh

test: check-version
	swift test

# Portable targets on Linux, in Docker (swift:6.2-noble). Build products stay
# in the planmeter-linux-build volume, separate from the macOS .build.
linux-build:
	./scripts/linux/run.sh build

linux-test:
	./scripts/linux/run.sh test

# Runs planmeterd in the container and exercises its control and remote APIs.
linux-smoke:
	./scripts/linux/run.sh smoke

app:
	./scripts/bundle.sh

signed-app:
	@test -n "$(SIGNING_IDENTITY)" || (echo 'Set SIGNING_IDENTITY to a Developer ID Application identity.' >&2; exit 1)
	SIGNING_IDENTITY="$(SIGNING_IDENTITY)" ./scripts/bundle.sh

release-macos:
	@test -n "$(SIGNING_IDENTITY)" || (echo 'Set SIGNING_IDENTITY to a Developer ID Application identity.' >&2; exit 1)
	SIGNING_IDENTITY="$(SIGNING_IDENTITY)" NOTARY_PROFILE="$(or $(NOTARY_PROFILE),planmeter-notary)" ./scripts/release-macos.sh

run: app
	open dist/PlanMeter.app

install: app
	-pkill -x PlanMeter
	rm -rf /Applications/PlanMeter.app
	cp -R dist/PlanMeter.app /Applications/PlanMeter.app
	@echo "Installed /Applications/PlanMeter.app"

install-mcp:
	./scripts/install-mcp.sh

clean:
	rm -rf .build dist
