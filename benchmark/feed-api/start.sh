#!/usr/bin/env bash
# Runs the server in the foreground, configured only by the environment
# (HOST, PORT, SQLITE_PATH, JWT_SECRET — see the challenge SPEC.md).
set -euo pipefail
exec "$(dirname "$0")/bin/server"
