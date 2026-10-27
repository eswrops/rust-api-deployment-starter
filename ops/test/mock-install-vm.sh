#!/usr/bin/env bash
# Mock-VM harness for ops/test/test-install-rust-api-activation.sh.
#
# Provides an isolated fake production VM driven entirely through PATH
# fakes: a `gcloud` that journals and executes `--command` payloads inside
# a sandbox directory (with VM paths rewritten into it), a `sudo` that
# models the sudoers rule and root behaviour, `systemctl`/`curl` fakes that
# model the service units and health endpoints, and small shims for `mv`,
# `stat` and `sha256sum` portability. No network, no gcloud binary, no
# production resource is ever contacted.
#
# Sourced, not executed. Expects bash; portable across Linux CI and macOS
# dev hosts.
#
# Feed API endpoint model (load-bearing for the endpoint regression test):
# the fake curl answers 200 ONLY for
#   http://127.0.0.1:8080/health/live   (rust-api, version = active release)
#   http://127.0.0.1:8080/health/ready  (rust-api)
#   http://127.0.0.1:8081/health        (feed-api; its ONLY health endpoint)
# Everything else — including 8081/health/live — is a 404, so an installer
# that probes the wrong feed-api path fails its own health gate.

mock_vm_init() { # mock_vm_init BASE
  MOCK_VM_BASE="$1"
  MOCK_VM_ROOT="$MOCK_VM_BASE/vm"
  MOCK_VM_STATE="$MOCK_VM_BASE/state"
  MOCK_VM_BIN="$MOCK_VM_BASE/bin"
  MOCK_VM_JOURNAL="$MOCK_VM_BASE/journal.log"
  rm -rf "$MOCK_VM_BASE"
  mkdir -p "$MOCK_VM_ROOT/usr/local/sbin" "$MOCK_VM_ROOT/opt/rust-api/releases" \
    "$MOCK_VM_ROOT/etc/sudoers.d" "$MOCK_VM_ROOT/home/operator" "$MOCK_VM_ROOT/tmp" \
    "$MOCK_VM_ROOT/run/lock" \
    "$MOCK_VM_STATE" "$MOCK_VM_BIN"
  : >"$MOCK_VM_JOURNAL"
  mock_vm_write_fakes
  PATH="$MOCK_VM_BIN:$PATH"
  export MOCK_VM_ROOT MOCK_VM_STATE MOCK_VM_BIN MOCK_VM_JOURNAL
}

mock_vm_write_fakes() {
  cat >"$MOCK_VM_BIN/gcloud" <<'SH'
#!/usr/bin/env bash
# Fake gcloud: journals and executes ssh payloads inside the mock VM root.
set -Eeuo pipefail
unexpected() { echo "mock-gcloud unexpectedly invoked: $*" >&2; exit 99; }
rewrite_vm_paths() {
  local s="$1"
  # Two phases with placeholders: sequential direct replacement would
  # re-match inside already-rewritten prefixes (e.g. /etc/sudoers inside
  # <root>/etc/sudoers.d). Applies to --command payloads AND stdin (the
  # installer ships heredoc payloads through `ssh ... --command=bash -s`).
  s="${s//\/etc\/sudoers.d//@ETC_SUDOERS_D@}"
  s="${s//\/etc\/sudoers/@ETC_SUDOERS@}"
  s="${s//\/usr\/local\/sbin/@USR_LOCAL_SBIN@}"
  s="${s//\/opt\/rust-api/@OPT_RUST_API@}"
  s="${s//\/tmp\/activate-probe.out/@TMP_PROBE@}"
  s="${s//@ETC_SUDOERS_D@/$MOCK_VM_ROOT/etc/sudoers.d}"
  s="${s//@ETC_SUDOERS@/$MOCK_VM_ROOT/etc/sudoers}"
  s="${s//@USR_LOCAL_SBIN@/$MOCK_VM_ROOT/usr/local/sbin}"
  s="${s//@OPT_RUST_API@/$MOCK_VM_ROOT/opt/rust-api}"
  s="${s//@TMP_PROBE@/$MOCK_VM_ROOT/tmp/activate-probe.out}"
  printf '%s' "$s"
}
case "${1:-}" in --project=*) ;; *) unexpected "$@" ;; esac
shift
[ "${1:-}" = "compute" ] || unexpected "$@"
shift
case "${1:-}" in
  ssh)
    shift
    cmd=""
    for a in "$@"; do
      case "$a" in --command=*) cmd="${a#--command=}" ;; esac
    done
    [ -n "$cmd" ] || unexpected "$@"
    printf '=== ssh ===\n%s\n=== end ===\n' "$cmd" >>"$MOCK_VM_JOURNAL"
    # The installer ships heredoc payloads as `ssh ... --command=bash -s`:
    # only then is stdin the script and needs the same path rewrite.
    stdin_data=""
    if [ "$cmd" = "bash -s" ]; then
      stdin_data="$(cat)"
      printf '=== ssh-stdin ===\n%s\n=== end ===\n' "$stdin_data" >>"$MOCK_VM_JOURNAL"
    fi
    HOME="$MOCK_VM_ROOT/home/operator"
    export HOME
    if [ -n "$stdin_data" ]; then
      rewrite_vm_paths "$stdin_data" | bash -c "$(rewrite_vm_paths "$cmd")"
    else
      bash -c "$(rewrite_vm_paths "$cmd")"
    fi
    ;;
  scp)
    shift
    src="${*: -2:1}"
    target="${*: -1}"
    case "$target" in *:*) name="${target##*:}" ;; *) unexpected "$@" ;; esac
    cp "$src" "$MOCK_VM_ROOT/home/operator/$name"
    printf '=== scp === %s -> home/operator/%s\n' "$src" "$name" >>"$MOCK_VM_JOURNAL"
    ;;
  *) unexpected "$@" ;;
esac
SH

  cat >"$MOCK_VM_BIN/sudo" <<'SH'
#!/usr/bin/env bash
# Fake sudo: models `deploy ALL=(root) NOPASSWD: /usr/local/sbin/rust-api-activate`,
# runs everything else as the invoking user with RUST_API_TEST_MODE=1 standing
# in for root (the EUID-gated ops scripts behave identically for the paths
# under test: argument validation exits 2 before anything host-specific).
set -Eeuo pipefail
user=""
args=("$@")
# Unwrap chained sudo (`sudo -u deploy sudo -n CMD`) and sudo flags. The
# array is the single source of truth — a helper function's shift() would
# only shift the function's own positionals.
while true; do
  n=${#args[@]}
  [ "$n" -gt 0 ] || break
  a="${args[0]}"
  case "$a" in
    sudo|/usr/bin/sudo) args=("${args[@]:1}") ;;
    -u)
      [ "$n" -ge 2 ] || { echo "sudo: -u needs an argument" >&2; exit 1; }
      user="${args[1]}"
      args=("${args[@]:2}")
      ;;
    -n|-n*|-E|-H|-i|-s) args=("${args[@]:1}") ;;
    --) args=("${args[@]:1}"); break ;;
    *) break ;;
  esac
done
[ "${#args[@]}" -gt 0 ] || { echo "sudo: no command given" >&2; exit 1; }
cmd="${args[0]}"
# Scenario injection: force the deploy-chain probe to exit with a chosen code.
if [ -f "$MOCK_VM_STATE/probe-exit" ] \
  && [ "${cmd##*/}" = "rust-api-activate" ] && [ "${#args[@]}" -eq 1 ]; then
  exit "$(cat "$MOCK_VM_STATE/probe-exit")"
fi
if [ "$user" = deploy ]; then
  [ "$cmd" = "$MOCK_VM_ROOT/usr/local/sbin/rust-api-activate" ] || {
    echo "sudo: deploy is not allowed to run $cmd" >&2
    exit 1
  }
fi
export RUST_API_TEST_MODE=1
# Redirect the ops scripts' production paths into the sandbox (test-only
# env; production sudoers env_reset strips these hooks).
export RUST_API_ROOT="$MOCK_VM_ROOT/opt/rust-api"
export RUST_API_LOCK_FILE="$MOCK_VM_ROOT/run/lock/rust-api-activate.lock"
base="${cmd##*/}"
# Scenario injection: replace the backfill tool with a scripted stub.
if [ "$base" = "rust-api-backfill-digests" ] && [ -f "$MOCK_VM_STATE/backfill-stub" ]; then
  stub="$(cat "$MOCK_VM_STATE/backfill-stub")"
  if [ "${#args[@]}" -gt 1 ]; then
    exec "$stub" "${args[@]:1}"
  else
    exec "$stub"
  fi
fi
if [ "$base" = install ]; then
  mode_val=""; iargs=(); pending=""
  for a in "${args[@]:1}"; do
    case "$pending" in
      mode) mode_val="$a"; iargs+=("$a"); pending=""; continue ;;
      drop) pending=""; continue ;;
    esac
    case "$a" in
      -m) pending="mode"; iargs+=("$a") ;;
      -o|-g) pending="drop" ;;   # ownership flags: modeled via sidecar files
      *) iargs+=("$a") ;;
    esac
  done
  /usr/bin/install ${iargs[@]+"${iargs[@]}"}
  rc=$?
  target="${iargs[${#iargs[@]}-1]}"
  printf 'root:root %s\n' "${mode_val#0}" >"$target.owner"
  exit "$rc"
fi
if [ "$base" = cp ]; then
  /bin/cp "${args[@]:1}"
  rc=$?
  src="${args[${#args[@]}-2]}"
  dst="${args[${#args[@]}-1]}"
  if [ -f "$src.owner" ]; then /bin/cp "$src.owner" "$dst.owner"; fi
  exit "$rc"
fi
exec ${args[@]+"${args[@]}"}
SH

  cat >"$MOCK_VM_BIN/systemctl" <<'SH'
#!/usr/bin/env bash
# Fake systemctl: unit activity from state files; every call journaled so
# the suite can prove the installer never restarts/stops services.
set -Eeuo pipefail
printf 'systemctl %s\n' "$*" >>"$MOCK_VM_JOURNAL"
case "${1:-}" in
  is-active)
    unit="${!#}"
    [ "$(cat "$MOCK_VM_STATE/service.$unit" 2>/dev/null)" = "active" ] || exit 3
    ;;
  *)
    printf 'MUTATION: systemctl %s\n' "$*" >>"$MOCK_VM_JOURNAL"
    ;;
esac
SH

  cat >"$MOCK_VM_BIN/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl with the two services' real endpoint models. See the harness
# header: feed-api answers ONLY /health.
set -Eeuo pipefail
fail=0
url=""
for a in "$@"; do
  case "$a" in
    --fail) fail=1 ;;
    --silent) ;;
    --max-time*) ;;
    http*) url="$a" ;;
  esac
done
body=""
case "$url" in
  http://127.0.0.1:8080/health/live)
    cur="$(readlink -f "$MOCK_VM_ROOT/opt/rust-api/current")"
    body="{\"status\":\"ok\",\"version\":\"${cur##*/}\"}"
    ;;
  http://127.0.0.1:8080/health/ready)
    body='{"status":"ok"}'
    ;;
  http://127.0.0.1:8081/health)
    body="$(cat "$MOCK_VM_STATE/feed-health" 2>/dev/null \
      || printf '{"status":"ok","db":"ok","uptime_s":9}')"
    ;;
  *)
    [ "$fail" -eq 1 ] && exit 22
    exit 22
    ;;
esac
printf '%s\n' "$body"
SH

  cat >"$MOCK_VM_BIN/mv" <<'SH'
#!/usr/bin/env bash
# Fake mv: GNU -T mapped onto BSD mv, ownership sidecars moved along.
set -Eeuo pipefail
if [ "${1:-}" = "-Tf" ]; then
  shift
  src="$1"
  dst="$2"
  /bin/mv -f "$src" "$dst"
  if [ -f "$src.owner" ]; then /bin/mv -f "$src.owner" "$dst.owner"; fi
  exit 0
fi
exec /bin/mv "$@"
SH

  cat >"$MOCK_VM_BIN/stat" <<'SH'
#!/usr/bin/env bash
# Fake stat: ownership sidecars first, then GNU stat, then BSD stat.
set -Eeuo pipefail
if [ "${1:-}" = "-c" ] && [ "${2:-}" = '%U:%G %a' ]; then
  if [ -f "$3.owner" ]; then
    cat "$3.owner"
    exit 0
  fi
  if /usr/bin/stat -c '%U:%G %a' "$3" 2>/dev/null; then
    exit 0
  fi
  exec /usr/bin/stat -f '%Su:%Sg %Lp' "$3"
fi
exec /usr/bin/stat "$@"
SH

  cat >"$MOCK_VM_BIN/sha256sum" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
if [ -x /usr/bin/sha256sum ]; then
  exec /usr/bin/sha256sum "$@"
fi
exec shasum -a 256 "$@"
SH
  chmod +x "$MOCK_VM_BIN/gcloud" "$MOCK_VM_BIN/sudo" "$MOCK_VM_BIN/systemctl" \
    "$MOCK_VM_BIN/curl" "$MOCK_VM_BIN/mv" "$MOCK_VM_BIN/stat" "$MOCK_VM_BIN/sha256sum"
}

mock_vm_fixture() { # mock_vm_fixture — a plausible production state
  # Two retained releases from the OLD activation generation (no .digest).
  mock_vm_old_release "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  mock_vm_old_release "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  ln -sfn "$MOCK_VM_ROOT/opt/rust-api/releases/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    "$MOCK_VM_ROOT/opt/rust-api/current"
  # Installed activation script: a PREVIOUS generation (differs from the
  # reviewed replacement) with modeled root ownership.
  cat >"$MOCK_VM_ROOT/usr/local/sbin/rust-api-activate" <<'SH'
#!/usr/bin/env bash
# fixture: pre-atomicity activation script generation
echo "activate (old generation) $*"
exit 0
SH
  chmod 0755 "$MOCK_VM_ROOT/usr/local/sbin/rust-api-activate"
  printf 'root:root 755\n' >"$MOCK_VM_ROOT/usr/local/sbin/rust-api-activate.owner"
  # sudoers rule exactly as documented.
  printf 'deploy ALL=(root) NOPASSWD: /usr/local/sbin/rust-api-activate\n' \
    >"$MOCK_VM_ROOT/etc/sudoers.d/deploy-activate"
  printf 'active\n' >"$MOCK_VM_STATE/service.rust-api"
  printf 'active\n' >"$MOCK_VM_STATE/service.feed-api"
}

mock_vm_old_release() { # mock_vm_old_release SHA — executable binary, NO .digest
  mkdir -p "$MOCK_VM_ROOT/opt/rust-api/releases/$1"
  printf '#!/bin/sh\n# rust-api %s\n' "$1" >"$MOCK_VM_ROOT/opt/rust-api/releases/$1/rust-api"
  chmod 0755 "$MOCK_VM_ROOT/opt/rust-api/releases/$1/rust-api"
}

mock_vm_clear_journal() { : >"$MOCK_VM_JOURNAL"; }

# run_installer INSTALLER_PATH ARGS... — sets $rc and $out; the installer
# runs with the mock VM on PATH and an explicit project id, so neither the
# real gcloud nor any production resource can be reached.
# shellcheck disable=SC2034  # rc/out are consumed by the caller
run_installer() {
  local installer="$1"
  shift
  set +e
  out="$(env \
    PATH="$MOCK_VM_BIN:$PATH" \
    GCP_PROJECT_ID="test-project" \
    MOCK_VM_ROOT="$MOCK_VM_ROOT" \
    MOCK_VM_STATE="$MOCK_VM_STATE" \
    MOCK_VM_BIN="$MOCK_VM_BIN" \
    MOCK_VM_JOURNAL="$MOCK_VM_JOURNAL" \
    bash "$installer" "$@" 2>&1)"
  rc=$?
  set -e
}
