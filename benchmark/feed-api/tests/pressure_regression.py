"""Connection-pressure regression: writes, reads, duplicate likes, abrupt
client disconnects and a fragmented upload must all complete while many idle
keep-alive connections are held open, and keep-alive must work normally again
once the pressure subsides.

The script starts its own server with RLIMIT_NOFILE=256 so the descriptor
budget is as tight as the challenge's pressure conditions. EXTRA_CONNECTIONS
idle sockets are then opened on top of the fillers to approach the server's
connection ceiling without crossing it, and a write must still succeed there.
When the server also retires keep-alive connections under pressure
(Connection: close — planned, not implemented yet), set EXPECT_RETIREMENT=1 to
additionally assert that at least one response carries it; without retirement
that count is only reported.
"""

from pathlib import Path
import http.client
import json
import os
import socket
import struct
import tempfile
import time

import harness

PORT = int(os.getenv("TEST_PORT", "19802"))
NOFILE = int(os.getenv("PRESSURE_NOFILE", "256"))
FILLERS = int(os.getenv("PRESSURE_FILLERS", "160"))
EXTRA_CONNECTIONS = int(os.getenv("PRESSURE_EXTRA", "30"))
DISCONNECTS = int(os.getenv("PRESSURE_DISCONNECTS", "20"))
WRITES = int(os.getenv("PRESSURE_WRITES", "32"))
EXPECT_RETIREMENT = os.getenv("EXPECT_RETIREMENT") == "1"
auth = harness.token()


def complete(port, method, path, body=None):
    """One request on a fresh connection; reports whether the server closed."""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        connection.request(method, path,
                           None if body is None else json.dumps(body),
                           {"Authorization": "Bearer " + auth,
                            "Content-Type": "application/json"})
        response = connection.getresponse()
        status = response.status
        closing = response.getheader("Connection", "").lower() == "close"
        payload = json.loads(response.read())
        return status, payload, closing
    finally:
        connection.close()


def hold_idle_connection():
    """Opens a keep-alive connection, health-checks it and leaves it open."""
    connection = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
    connection.request("GET", "/health")
    response = connection.getresponse()
    assert response.status == 200, response.status
    response.read()
    return connection


def abrupt_disconnect():
    """Starts a request and then kills the connection with an RST."""
    connection = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    try:
        connection.sendall(b"GET /health HTTP/1.1\r\nHost: localhost\r\n")
    finally:
        # SO_LINGER with a zero timeout turns close() into a hard RST instead
        # of a graceful FIN, i.e. exactly what a crashed client produces.
        connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                              struct.pack("ii", 1, 0))
        connection.close()


with tempfile.TemporaryDirectory(prefix="feed-api-pressure-") as directory:
    directory = Path(directory)
    harness.prepare_database(directory)
    process = harness.spawn_server(
        harness.SERVER, directory, PORT, rlimit_nofile=NOFILE)
    try:
        harness.wait_for_health(PORT, process)

        text = "fragmented under connection pressure " + "🙂" * 200
        payload = json.dumps({"body": text}, ensure_ascii=False).encode()
        partial = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
        partial.putrequest("POST", "/posts")
        partial.putheader("Authorization", "Bearer " + auth)
        partial.putheader("Content-Type", "application/json")
        partial.putheader("Content-Length", str(len(payload)))
        partial.endheaders()
        midpoint = len(payload) // 2
        partial.send(payload[:midpoint])

        fillers = []
        extras = []
        try:
            for _ in range(FILLERS):
                fillers.append(hold_idle_connection())
            time.sleep(0.3)

            retired = 0
            for index in range(WRITES):
                body_text = f"committed pressure write {index}"
                status, stored, closing = complete(PORT, "POST", "/posts", {"body": body_text})
                assert status == 201, (status, stored)
                retired += closing
                status, read, closing = complete(PORT, "GET", f'/posts/{stored["post"]["id"]}')
                assert status == 200 and read["post"]["body"] == body_text, (status, read)
                retired += closing
            if EXPECT_RETIREMENT:
                assert retired > 0, "expected Connection: close under pressure"
            else:
                print(f"note: {retired} retired responses (set EXPECT_RETIREMENT=1 "
                      "once the server retires keep-alive connections)", flush=True)

            # Duplicate likes under pressure: the second like is an idempotent
            # 200 and the count stays at one.
            status, stored, _ = complete(PORT, "POST", "/posts", {"body": "liked under pressure"})
            assert status == 201, (status, stored)
            liked_id = stored["post"]["id"]
            status, first, _ = complete(PORT, "POST", f"/posts/{liked_id}/like")
            assert (status, first["already_liked"]) == (201, False), (status, first)
            status, second, _ = complete(PORT, "POST", f"/posts/{liked_id}/like")
            assert (status, second["already_liked"]) == (200, True), (status, second)
            status, read, _ = complete(PORT, "GET", f"/posts/{liked_id}")
            assert read["post"]["like_count"] == 1, read

            # Crashed-client disconnects must not wedge the server.
            for _ in range(DISCONNECTS):
                abrupt_disconnect()
            assert harness.request(PORT, "GET", "/health")[0] == 200, \
                "server unhealthy after abrupt client disconnects"
            status, stored, _ = complete(PORT, "POST", "/posts", {"body": "after disconnects"})
            assert status == 201, (status, stored)

            # Approach the descriptor ceiling: with the fillers held, open
            # more sockets and confirm work still completes near the limit.
            for _ in range(EXTRA_CONNECTIONS):
                extras.append(hold_idle_connection())
            status, stored, _ = complete(PORT, "POST", "/posts", {"body": "near the limit"})
            assert status == 201, (status, stored)

            partial.send(payload[midpoint:])
            response = partial.getresponse()
            stored = json.loads(response.read())
            assert response.status == 201 and stored["post"]["body"] == text, stored
        finally:
            partial.close()
            for connection in fillers + extras:
                connection.close()
        time.sleep(0.3)

        try:
            connection = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
            connection.request("GET", "/health")
            response = connection.getresponse()
            assert response.status == 200, response.status
            assert response.getheader("Connection", "").lower() != "close"
            response.read()
            original = connection.sock
            connection.request("GET", "/feed")
            response = connection.getresponse()
            assert response.status == 200, response.status
            response.read()
            assert connection.sock is original, \
                "keep-alive did not recover after pressure subsided"
        finally:
            connection.close()
    finally:
        harness.stop_server(process)
    print(f"PASS fragmented upload, {WRITES} writes/readbacks, duplicate likes, "
          f"{DISCONNECTS} abrupt disconnects and keep-alive recovery with "
          f"{FILLERS}+{EXTRA_CONNECTIONS} idle connections (nofile={NOFILE})",
          flush=True)
