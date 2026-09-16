#!/usr/bin/env python3
"""Relay Cube VMM guest-initiated vsock streams to the host trace forwarder."""

import asyncio
import os
import socket


SOCKET_PATH = "/run/cube-cri/agent-trace.sock"
FORWARDER_PORT = 10240


async def relay(reader, writer):
    upstream = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    upstream.setblocking(False)
    try:
        loop = asyncio.get_running_loop()
        await loop.sock_connect(upstream, (socket.VMADDR_CID_HOST, FORWARDER_PORT))
        while True:
            data = await reader.read(65536)
            if not data:
                break
            await loop.sock_sendall(upstream, data)
    finally:
        upstream.close()
        writer.close()
        await writer.wait_closed()


async def main():
    os.makedirs(os.path.dirname(SOCKET_PATH), exist_ok=True)
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass
    server = await asyncio.start_unix_server(relay, path=SOCKET_PATH)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
