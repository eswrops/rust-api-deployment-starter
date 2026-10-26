"""Commit-failure fault injection: a failed COMMIT must surface as 500 and
roll the write back, and no success response may be sent before the commit
finishes.

Run through tests/commit_check.sh, which builds bin/commit-test — the
unmodified release binary linked with tests/commit_fault.c so a commit hook
can hold or fail commits through marker files. Linux only (GNU ld --wrap).

The tests fail if the hook was not installed or not triggered: scenario A's
500 only happens when the hook fails the commit (and it consumes the `fail`
marker, which is asserted), and scenario B blocks on the hook's `entered`
marker before anything else.
"""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import os
import sqlite3
import tempfile
import time

import harness

PORT = int(os.getenv("TEST_PORT", "19801"))
BINARY = Path(os.getenv("COMMIT_TEST_BIN", harness.CRATE / "bin" / "commit-test"))
auth = harness.token()


def stored_bodies(path):
    """Bodies present in the posts table, read directly from SQLite."""
    connection = sqlite3.connect(path)
    try:
        return [row[0] for row in connection.execute("SELECT body FROM posts ORDER BY id")]
    finally:
        connection.close()


with tempfile.TemporaryDirectory(prefix="feed-api-commit-test-") as directory:
    directory = Path(directory)
    _, next_id = harness.prepare_database(directory)
    process = harness.spawn_server(
        BINARY, directory, PORT,
        extra_env={"COMMIT_TEST_DIR": str(directory)})
    try:
        harness.wait_for_health(PORT, process)

        (directory / "fail").touch()
        assert harness.request(PORT, "POST", "/posts", {"body": "rolled back"}, auth) == \
            (500, {"error": "internal server error"})
        assert not (directory / "fail").exists(), "commit hook never consumed the fail marker"
        assert "rolled back" not in stored_bodies(directory / "feed.db"), \
            "failed commit was not rolled back in SQLite"
        assert harness.request(PORT, "GET", f"/posts/{next_id}")[0] == 404
        assert harness.request(PORT, "GET", "/health")[0] == 200, \
            "server unusable after a failed commit"
        print("PASS failed commit returns 500 and rolls back the inserted post", flush=True)

        (directory / "hold").touch()
        with ThreadPoolExecutor(max_workers=1) as pool:
            response = pool.submit(
                harness.request, PORT, "POST", "/posts", {"body": "committed"}, auth)
            try:
                for _ in range(100):
                    if (directory / "entered").exists():
                        break
                    time.sleep(0.01)
                assert (directory / "entered").exists(), "commit hook was not reached"
                time.sleep(0.2)
                assert not response.done(), "response was sent before commit"
            finally:
                (directory / "hold").unlink(missing_ok=True)
            status, body = response.result(timeout=10)
        assert status == 201 and body["post"]["id"] == next_id, (status, body)
        assert "committed" in stored_bodies(directory / "feed.db"), \
            "post missing from SQLite despite the 201 response"
        assert harness.request(PORT, "GET", f"/posts/{next_id}")[1]["post"]["body"] == \
            "committed"
        print("PASS success waits for commit; committed data visible in SQLite and API",
              flush=True)
    finally:
        harness.stop_server(process)
