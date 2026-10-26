#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: installs the pinned Rust toolchain.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential ca-certificates curl

# Toolchain lives under /opt so the unprivileged build/run users can use it.
# build.sh re-exposes it through PATH; $HOME/.cargo remains the writable
# CARGO_HOME for the registry cache.
export CARGO_HOME=/opt/feed-api-rust/cargo
export RUSTUP_HOME=/opt/feed-api-rust/rustup
installer="$(mktemp)"
trap 'rm -f "$installer"' EXIT
curl -fsSL --retry 3 https://sh.rustup.rs -o "$installer"
sh "$installer" -y --no-modify-path --profile minimal --default-toolchain 1.99.1
chmod -R a+rX /opt/feed-api-rust
