"""Idle keep-alive capacity: opens COUNT connections, health-checks each,
then re-verifies every one of them on the same socket and reports the
server's RSS, CPU usage, descriptor usage and platform.

This measures what the README projects about memory at 15k idle connections
instead of estimating it. The script raises its own descriptor limit, starts
its own server with enough headroom, and needs no orchestration:

    IDLE_COUNT=15000 python3 tests/idle_client.py

CI runs it with a small count (deterministic); the full 15,000-connection
memory benchmark stays a manual/scheduled run.
"""

from pathlib import Path
import asyncio
import json
import os
import platform
import resource
import subprocess
import tempfile

import harness

PORT = int(os.getenv("TEST_PORT", "19803"))
COUNT = int(os.getenv("IDLE_COUNT", "15000"))
HEADROOM = 2048
REQUEST = b"GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n"


def raise_nofile():
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    target = COUNT + HEADROOM
    if hard != resource.RLIM_INFINITY:
        target = min(target, hard)
    try:
        resource.setrlimit(resource.RLIMIT_NOFILE, (target, hard))
    except ValueError:
        return soft
    return target


def ps_fields(pid):
    """(rss KiB, cpu percent, process state) via ps (works on macOS and Linux)."""
    output = subprocess.run(
        ["ps", "-o", "rss=,%cpu=,state=", "-p", str(pid)],
        capture_output=True, text=True, check=True).stdout.split()
    return int(output[0]), float(output[1]), output[2]


def open_fds(pid):
    """Descriptor count: /proc on Linux, lsof (minus its header) elsewhere."""
    proc = Path(f"/proc/{pid}/fd")
    if proc.is_dir():
        return len(os.listdir(proc))
    output = subprocess.run(
        ["lsof", "-p", str(pid)],
        capture_output=True, text=True, check=True).stdout.splitlines()
    return max(len(output) - 1, 0)


async def health(reader, writer):
    writer.write(REQUEST)
    await writer.drain()
    header = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 10)
    assert header.split(b"\r\n")[0].split()[1] == b"200", header
    fields = dict(line.split(b":", 1) for line in header.lower().split(b"\r\n")[1:]
                  if b":" in line)
    assert fields.get(b"connection", b"").strip() != b"close", header
    body = await asyncio.wait_for(
        reader.readexactly(int(fields[b"content-length"])), 10)
    assert json.loads(body)["db"] == "ok", body


async def main():
    limit = raise_nofile()
    with tempfile.TemporaryDirectory(prefix="feed-api-idle-") as directory:
        harness.prepare_database(Path(directory))
        process = harness.spawn_server(
            harness.SERVER, Path(directory), PORT,
            rlimit_nofile=min(COUNT + HEADROOM, limit))
        connections = []
        failures = []
        try:
            harness.wait_for_health(PORT, process)
            semaphore = asyncio.Semaphore(256)

            async def connect():
                try:
                    async with semaphore:
                        reader, writer = await asyncio.wait_for(
                            asyncio.open_connection("127.0.0.1", PORT, limit=4096), 10)
                        connections.append((reader, writer))
                        await health(reader, writer)
                except Exception as error:
                    failures.append(repr(error))
                    raise

            async def verify(connection):
                async with semaphore:
                    await health(*connection)

            await asyncio.gather(*(connect() for _ in range(COUNT)))
            print(json.dumps({
                "ready": True,
                "connections": len(connections),
                "failed_attempts": len(failures),
            }), flush=True)
            await asyncio.gather(*(verify(connection) for connection in connections))
            rss_kib, cpu_percent, state = ps_fields(process.pid)
            print(json.dumps({
                "verified": len(connections),
                "same_sockets": True,
                "failed_attempts": len(failures),
                "server_rss_kib": rss_kib,
                "server_cpu_percent": cpu_percent,
                "server_state": state,
                "server_open_fds": open_fds(process.pid),
                "os": platform.platform(),
                "arch": platform.machine(),
            }), flush=True)
        finally:
            for _, writer in connections:
                writer.close()
            await asyncio.gather(
                *(writer.wait_closed() for _, writer in connections),
                return_exceptions=True)
            harness.stop_server(process)


asyncio.run(main())
print(f"PASS {COUNT} idle connections verified on their original sockets", flush=True)
