.PHONY: help bootstrap shim daemon extension test lint spike install-dev clean

SHIM_BIN := shim/target/release/agentstation-hook

help:
	@echo "Agent Station — see README.md. Current milestone: M0a (spike)."
	@echo ""
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "};{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

bootstrap:  ## Install toolchains and deps
	@./scripts/bootstrap.sh

spike:      ## M0a — the two-day question that gates the whole plan
	@./scripts/spike-m0a.sh

shim:       ## Build the release shim
	cd shim && cargo build --release
	@ls -lh $(SHIM_BIN)

daemon:     ## Build daemon + station CLI
	cd daemon && swift build -c release

extension:  ## Build the VS Code extension (stable API only)
	cd extension && npm run build

test:       ## Everything, including the latency guard
	cd shim && cargo test --release
	cd daemon && swift test
	cd extension && npm run typecheck && npm test

lint:
	cd shim && cargo clippy -- -D warnings && cargo fmt --check
	cd daemon && swift format lint -r Sources

install-dev: shim daemon  ## Wire a local dev install (writes to your agent configs — shows diffs first)
	./scripts/install-launchagent.sh
	./daemon/.build/release/station provider validate claude-code

clean:
	cd shim && cargo clean
	rm -rf daemon/.build extension/dist extension/node_modules
