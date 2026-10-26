#!/usr/bin/env bash
# Shared helpers for the rust-api backup tooling. Sourced, not executed.
# Talks to Google Cloud Storage through the JSON API with a service-account
# JWT exchanged via curl + openssl — no Google SDK is installed on the VM.
# shellcheck shell=bash

GCS_TOKEN_URL="${GCS_TOKEN_URL:-https://oauth2.googleapis.com/token}"
GCS_API_BASE="${GCS_API_BASE:-https://storage.googleapis.com}"
# Request timeouts (seconds). Overridable so tests can exercise timeout
# behavior against a slow mock instead of waiting for a real 60 s stall.
GCS_HTTP_TIMEOUT="${GCS_HTTP_TIMEOUT:-60}"
GCS_UPLOAD_TIMEOUT="${GCS_UPLOAD_TIMEOUT:-180}"
GCS_SCOPE="https://www.googleapis.com/auth/devstorage.read_write"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# gcs_token KEY_FILE -> prints a cached access token (one per invocation)
gcs_token() {
  local key="$1" unsigned pem sig jwt token
  unsigned="$(python3 - "$key" "$GCS_SCOPE" <<'PY'
import base64, json, sys, time
key_path, scope = sys.argv[1], sys.argv[2]
key = json.load(open(key_path))
def enc(obj):
    return base64.urlsafe_b64encode(json.dumps(obj, separators=(",", ":")).encode()).rstrip(b"=").decode()
now = int(time.time())
claims = {"iss": key["client_email"], "scope": scope, "aud": "https://oauth2.googleapis.com/token",
          "iat": now, "exp": now + 3600}
print(enc({"alg": "RS256", "typ": "JWT"}) + "." + enc(claims))
PY
)" || return 1
  pem="$(mktemp)" || return 1
  chmod 600 "$pem"
  # bash honors the RETURN trap; other shells ignore it, so the file is also
  # removed explicitly after signing.
  trap 'rm -f "$pem"' RETURN 2>/dev/null || true
  python3 - "$key" "$pem" <<'PY' || { rm -f "$pem"; return 1; }
import json, sys
key = json.load(open(sys.argv[1]))
open(sys.argv[2], "w").write(key["private_key"])
PY
  sig="$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$pem" | b64url)" ||
    { rm -f "$pem"; return 1; }
  rm -f "$pem"
  jwt="$unsigned.$sig"
  token="$(curl -fsS --max-time 20 -X POST "$GCS_TOKEN_URL" \
    -d grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \
    -d assertion="$jwt" | jq -er .access_token)" || return 1
  printf '%s' "$token"
}

# gcs_upload KEY BUCKET NAME FILE [CONTENT_TYPE] -> 0 on HTTP 200
gcs_upload() {
  local key="$1" bucket="$2" name="$3" file="$4" ctype="${5:-application/octet-stream}" token code
  token="$(gcs_token "$key")" || return 1
  code="$(curl -sS --max-time "$GCS_UPLOAD_TIMEOUT" -o /tmp/gcs-upload-response.$$ -w '%{http_code}' \
    -X POST -H "Authorization: Bearer $token" -H "Content-Type: $ctype" \
    --data-binary @"$file" \
    "${GCS_API_BASE}/upload/storage/v1/b/$bucket/o?uploadType=media&name=$name" )" || { rm -f /tmp/gcs-upload-response.$$; return 1; }
  [ "$code" = "200" ] || { echo "gcs_upload $name -> HTTP $code: $(head -c 300 /tmp/gcs-upload-response.$$)" >&2; rm -f /tmp/gcs-upload-response.$$; return 1; }
  rm -f /tmp/gcs-upload-response.$$
}

# Object names must be percent-encoded inside the JSON API path ('/' in
# prefix-style names would otherwise become path segments).
gcs_encoded_name() { jq -rn --arg s "$1" '$s|@uri'; }

# gcs_download KEY BUCKET NAME OUT -> 0 on HTTP 200
gcs_download() {
  local key="$1" bucket="$2" name="$3" out="$4" token code encoded
  token="$(gcs_token "$key")" || return 1
  encoded="$(gcs_encoded_name "$name")"
  code="$(curl -sS --max-time "$GCS_HTTP_TIMEOUT" -o "$out" -w '%{http_code}' \
    -H "Authorization: Bearer $token" \
    "${GCS_API_BASE}/storage/v1/b/$bucket/o/$encoded?alt=media")" || return 1
  [ "$code" = "200" ] || { echo "gcs_download $name -> HTTP $code" >&2; return 1; }
}

# gcs_list KEY BUCKET PREFIX
#   -> newline-separated "updated|timeDeleted|generation|name"
#   (live objects have an empty timeDeleted; superseded versions carry one;
#   '|' separates fields because `read` collapses runs of IFS whitespace and
#   would destroy the empty timeDeleted field)
#
# Follows nextPageToken to the end of the listing: a truncated listing would
# silently exempt objects from retention and can hide the newest snapshot
# from the restore drill. Any HTTP, token or malformed-JSON failure returns
# non-zero with nothing (or only already-printed pages) on stdout, so
# callers can distinguish a complete listing from a partial one.
gcs_list() {
  local key="$1" bucket="$2" prefix="$3" token page page_token=""
  token="$(gcs_token "$key")" || return 1
  while :; do
    page="$(curl -fsS --max-time "$GCS_HTTP_TIMEOUT" -G -H "Authorization: Bearer $token" \
      --data-urlencode "prefix=$prefix" --data-urlencode "versions=true" --data-urlencode "maxResults=1000" \
      ${page_token:+--data-urlencode "pageToken=$page_token"} \
      "${GCS_API_BASE}/storage/v1/b/$bucket/o")" || {
        echo "gcs_list: listing gs://$bucket/$prefix failed" >&2
        return 1
      }
    # Validate the page shape before emitting items: a malformed response
    # must fail the call, not silently produce an empty listing. The token
    # probe and the item projection parse the same JSON twice on purpose —
    # the probe runs with an error-on-type guard the projection cannot use.
    page_token="$(jq -er 'if type == "object" then (.nextPageToken // "") else error("not an object") end' <<<"$page")" ||
      { echo "gcs_list: malformed listing response from gs://$bucket" >&2; return 1; }
    jq -r '.items[]? | [.updated, (.timeDeleted // ""), .generation, .name] | join("|")' <<<"$page"
    [ -n "$page_token" ] || return 0
  done
}

# gcs_delete KEY BUCKET NAME [GENERATION]
#   -> 0 on HTTP 204 (deleted) or 404 (already absent: safe retention race)
gcs_delete() {
  local key="$1" bucket="$2" name="$3" gen="${4:-}" token code url encoded
  token="$(gcs_token "$key")" || return 1
  encoded="$(gcs_encoded_name "$name")"
  url="${GCS_API_BASE}/storage/v1/b/$bucket/o/$encoded"
  [ -n "$gen" ] && url="$url?generation=$gen"
  code="$(curl -sS --max-time "$GCS_HTTP_TIMEOUT" -o /dev/null -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer $token" "$url")" || return 1
  { [ "$code" = "204" ] || [ "$code" = "404" ]; } || { echo "gcs_delete $name -> HTTP $code" >&2; return 1; }
}

# iso_days_ago DAYS -> UTC timestamp N days ago (for retention cutoffs)
iso_days_ago() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }

# sqlite_snapshot SRC_DB_URL OUT_DB -> 0 when the copy passes integrity_check
sqlite_snapshot() {
  local src="$1" out="$2"
  python3 - "$src" "$out" <<'PY' || return 1
import sqlite3, sys
src_path, out_path = sys.argv[1], sys.argv[2]
src = sqlite3.connect(f"file:{src_path}?mode=ro", uri=True)
dst = sqlite3.connect(out_path)
with dst:
    src.backup(dst)
src.close()
check = dst.execute("PRAGMA integrity_check").fetchone()[0]
migrations = dst.execute("SELECT count(*) FROM _sqlx_migrations").fetchone()[0]
dst.close()
if check != "ok":
    print(f"snapshot integrity_check: {check}", file=sys.stderr)
    sys.exit(1)
print(f"snapshot ok ({migrations} migrations recorded)")
PY
}
