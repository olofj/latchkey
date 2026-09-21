# Copyright (c) 2026 Olof Johansson
# SPDX-License-Identifier: BSD-3-Clause
"""TLS for the fakes' ThreadingHTTPServers, handshaking per connection.

Wrapping the LISTENING socket (ctx.wrap_socket(server.socket, server_side=True))
makes accept() perform the TLS handshake -- in the server's single accept loop,
with no timeout. A client that connects and never sends a ClientHello then
stalls every connection after it. The L2 harness makes exactly that client:
when a test kills the app, a tsnet peer's forward to a fake can stay open and
silent indefinitely. The discovery suite's relaunch test hung on one (R29
review, regression pass): the relaunched app connected, and the fake gateway
never read its request.

Here the listener accepts without a handshake, and each connection handshakes
in its own handler thread, within HANDSHAKE_TIMEOUT. Only the handshake is
timed: WebSocket and SSE connections stay open as long as the tests keep them.
"""

import socket

HANDSHAKE_TIMEOUT = 10  # seconds; a loopback handshake takes milliseconds


def wrap_listener(ctx, sock):
    """The listening socket, TLS-wrapped, with the handshake deferred."""
    return ctx.wrap_socket(sock, server_side=True, do_handshake_on_connect=False)


class HandshakeInThread:
    """Mixin for a BaseHTTPRequestHandler on a wrap_listener socket; list it
    first among the bases."""

    def setup(self):
        self.request.settimeout(HANDSHAKE_TIMEOUT)
        self.request.do_handshake()
        self.request.settimeout(None)
        super().setup()


def with_silent_client(port, request):
    """Holds a connection to port that never speaks while request() runs, and
    returns its result: a self-check that one such client stalls nobody."""
    idle = socket.create_connection(("127.0.0.1", port), timeout=5)
    try:
        return request()
    finally:
        idle.close()
