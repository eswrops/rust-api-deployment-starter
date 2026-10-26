#!/usr/bin/env bash
# Builds the fault-instrumented server variant (bin/commit-test) and runs the
# commit-failure test against it.
#
# The instrumented binary is the unmodified release build linked with
# tests/commit_fault.c via GNU ld --wrap, so every sqlite3_open_v2 call in the
# server installs a commit hook controlled by marker files. --wrap is a GNU ld
# feature: the canonical run is the CI benchmark job (ubuntu-24.04); macOS
# cannot link it, so the script refuses there.
#
#   bash tests/commit_check.sh                                # fixture database
#   SEED_DB=/path/to/seed/feed.db bash tests/commit_check.sh  # challenge seed
#
# Needs a built release binary (bash build.sh) and the sqlite3 amalgamation
# header for compiling the shim; SQLITE3_INCLUDE_DIR overrides the download.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(uname -s)" != "Linux" ]; then
  echo "commit_check.sh needs GNU ld --wrap (Linux); run it in the CI benchmark job." >&2
  exit 1
fi

# Same toolchain discovery as build.sh (the deploy VM keeps rust in /opt).
export PATH="/opt/feed-api-rust/cargo/bin:$HOME/.cargo/bin:$PATH"
if [ -d /opt/feed-api-rust/rustup ]; then
  export RUSTUP_HOME=/opt/feed-api-rust/rustup
fi

mkdir -p bin .deps
sqlite_include="${SQLITE3_INCLUDE_DIR:-}"
if [ -z "$sqlite_include" ]; then
  amalgamation=.deps/sqlite-amalgamation-3530400
  if [ ! -f "$amalgamation/sqlite3.h" ]; then
    archive=.deps/sqlite.zip
    [ -f "$archive" ] || curl -fsSL --retry 3 \
      https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip -o "$archive"
    printf '%s  %s\n' \
      1e71ddf93849c6a6ecf58b827c0692073d2dd7ee40196158068f7b29f422e87d "$archive" | sha256sum -c -
    [ -d "$amalgamation" ] || unzip -q "$archive" -d .deps
  fi
  sqlite_include="$amalgamation"
fi
cc -O2 -I"$sqlite_include" -c tests/commit_fault.c -o .deps/commit_fault.o

cargo rustc --release --locked -- \
  -C "link-arg=$PWD/.deps/commit_fault.o" \
  -C link-arg=-Wl,--wrap=sqlite3_open_v2
cp target/release/feed-api bin/commit-test

python3 tests/commit_check.py
