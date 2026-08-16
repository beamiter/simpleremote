.PHONY: build install check workspace-sync virtual-tree runtime-exec transport-bridge integration-events suite-check

build:
	cargo build --release --locked

install: build
	./install.sh

check:
	cargo fmt --all -- --check
	cargo clippy --all-targets --locked -- -D warnings
	cargo test --locked
	vim -Nu NONE -n -i NONE -es -S tests/defcompile.vim
	$(MAKE) workspace-sync
	$(MAKE) virtual-tree
	$(MAKE) runtime-exec
	$(MAKE) transport-bridge
	$(MAKE) integration-events

workspace-sync:
	PATH="$(CURDIR)/tests/fixtures:$$PATH" \
	SIMPLEREMOTE_TEST_ROOT="$(CURDIR)" \
	SIMPLEREMOTE_TEST_TARGET="fixture-target" \
	vim -Nu NONE -n -i NONE -es -S tests/workspace_sync.vim

virtual-tree:
	PATH="$(CURDIR)/tests/fixtures:$$PATH" \
	SIMPLEREMOTE_TEST_ROOT="$(CURDIR)" \
	SIMPLEREMOTE_TEST_TARGET="fixture-target" \
	vim -Nu NONE -n -i NONE -es -S tests/virtual_tree.vim

runtime-exec:
	cargo build --locked
	PATH="$(CURDIR)/tests/fixtures:$$PATH" \
	SIMPLEREMOTE_TEST_ROOT="$(CURDIR)" \
	SIMPLEREMOTE_TEST_TARGET="fixture-target" \
	vim -Nu NONE -n -i NONE -es -S tests/runtime_exec.vim

transport-bridge:
	cargo build --locked
	PATH="$(CURDIR)/tests/fixtures:$$PATH" \
	SIMPLEREMOTE_TEST_ROOT="$(CURDIR)" \
	SIMPLEREMOTE_TEST_TARGET="fixture-target" \
	vim -Nu NONE -n -i NONE -es -S tests/transport_bridge.vim

integration-events:
	cargo build --locked
	PATH="$(CURDIR)/tests/fixtures:$$PATH" \
	SIMPLEREMOTE_TEST_ROOT="$(CURDIR)" \
	SIMPLEREMOTE_TEST_TARGET="fixture-target" \
	vim -Nu NONE -n -i NONE -es -S tests/integration_events.vim

# Cross-plugin integration against the real siblings.  Deliberately outside
# `check`: that gate has to pass in a checkout holding this plugin alone,
# which is what CI runs.  Siblings that are not installed are skipped and
# named in the report.
suite-check:
	cargo build --locked
	PATH="$(CURDIR)/tests/fixtures:$$PATH" \
	SIMPLEREMOTE_TEST_ROOT="$(CURDIR)" \
	SIMPLEREMOTE_TEST_TARGET="fixture-target" \
	vim -Nu NONE -n -i NONE -es -S tests/suite_integration.vim
