"""Shared helpers for the fault-injection and pressure test scripts.

Every script spawns its own server process on its own database copy and talks
HTTP with the standard library only, so they run identically locally and in
CI. Databases come from $SEED_DB (the canonical challenge seed) when set, or
from tests/fixtures otherwise — schema.sql is a verbatim copy of the upstream
schema, seed.sql loads 4 users / 21 posts / 4 likes.
"""

import base64
import hashlib
import hmac
import http.client
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import time

CRATE = Path(__file__).resolve().parents[1]
SERVER = Path(os.getenv("FEED_API_BIN", CRATE / "bin" / "server"))
SCHEMA = (CRATE / "tests" / "fixtures" / "schema.sql").read_text()
SEED = (CRATE / "tests" / "fixtures" / "seed.sql").read_text()
SECRET = os.getenv("JWT_SECRET", "twelve-dollar-challenge")


def token(user_id="1", username="commit test", lifetime=3600):
    """HS256 bearer token for a seeded user.

    `exp` carries a fractional offset (RFC 7519 §2 allows non-integer
    NumericDates), so every suite built on this harness exercises the server's
    fractional-exp path over real HTTP.
    """
    now = int(time.time())
    header = base64.urlsafe_b64encode(b'{"alg":"HS256"}').rstrip(b"=")
    payload = base64.urlsafe_b64encode(json.dumps({
        "sub": user_id,
        "username": username,
        "iat": now,
        "exp": now + lifetime + 0.5,
    }).encode()).rstrip(b"=")
    signed = header + b"." + payload
    signature = base64.urlsafe_b64encode(
        hmac.new(SECRET.encode(), signed, hashlib.sha256).digest()).rstrip(b"=")
    return (signed + b"." + signature).decode()


def prepare_database(directory, name="feed.db"):
    """Creates the database for a run and returns (path, next post id)."""
    path = directory / name
    seed_db = os.getenv("SEED_DB")
    if seed_db:
        shutil.copyfile(seed_db, path)
    else:
        connection = sqlite3.connect(path)
        connection.executescript(SCHEMA)
        connection.executescript(SEED)
        connection.commit()
        connection.close()
    connection = sqlite3.connect(path)
    next_id = connection.execute(
        "SELECT coalesce(max(id), 0) + 1 FROM posts").fetchone()[0]
    connection.close()
    return path, next_id


def spawn_server(binary, directory, port, extra_env=None, rlimit_nofile=None):
    """Starts the server in the foreground on a temp database copy.

    rlimit_nofile caps the child's descriptor budget (used by the pressure
    test to mimic the challenge's tight nofile conditions).
    """
    env = dict(
        os.environ,
        SQLITE_PATH=str(directory / "feed.db"),
        JWT_SECRET=SECRET,
        HOST="127.0.0.1",
        PORT=str(port),
        **(extra_env or {}),
    )

    def preexec():
        if rlimit_nofile is not None:
            import resource
            resource.setrlimit(
                resource.RLIMIT_NOFILE, (rlimit_nofile, rlimit_nofile))

    return subprocess.Popen(
        [str(binary)], env=env,
        preexec_fn=preexec if rlimit_nofile is not None else None)


def wait_for_health(port, process, attempts=100):
    for _ in range(attempts):
        assert process.poll() is None, "server exited during startup"
        try:
            status, _ = request(port, "GET", "/health", timeout=2)
            if status == 200:
                return
        except OSError:
            pass
        time.sleep(0.05)
    raise RuntimeError("server startup timed out")


def request(port, method, path, body=None, auth_token=None, timeout=15):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        headers = {"Content-Type": "application/json"}
        if auth_token:
            headers["Authorization"] = "Bearer " + auth_token
        connection.request(method, path,
                           None if body is None else json.dumps(body), headers)
        response = connection.getresponse()
        return response.status, json.loads(response.read())
    finally:
        connection.close()


def stop_server(process):
    process.kill()
    process.wait()
