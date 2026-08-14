.PHONY: build install check workspace-sync virtual-tree

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
