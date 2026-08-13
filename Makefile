.PHONY: build install check

build:
	cargo build --release --locked

install: build
	./install.sh

check:
	cargo fmt --all -- --check
	cargo clippy --all-targets --locked -- -D warnings
	cargo test --locked
	vim -Nu NONE -n -i NONE -es -S tests/defcompile.vim
