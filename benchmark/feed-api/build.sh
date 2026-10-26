#!/usr/bin/env bash
# Builds the release binary as a normal user. Dependencies are pinned by
# Cargo.lock and resolved with --locked; no prebuilt binaries are shipped.
set -euo pipefail
cd "$(dirname "$0")"

export PATH="/opt/feed-api-rust/cargo/bin:$HOME/.cargo/bin:$PATH"
if [ -d /opt/feed-api-rust/rustup ]; then
  export RUSTUP_HOME=/opt/feed-api-rust/rustup
fi

mkdir -p bin
cargo build --release --locked
cp target/release/feed-api bin/server
