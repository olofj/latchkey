// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Latchkey modification to the vendored libtailscale (F16 stage 1): a test
// hook that makes the loopback listener silent.

package tsnet

import (
	"errors"
	"io"
	"net"
	"sync/atomic"
)

// stallableListener wraps the loopback LocalAPI/SOCKS listener so a test can
// make it accept and never answer (Latchkey F16). The mark belongs to this
// listener: RestartLoopback builds a new one, unmarked, which is what lets a
// test prove that the app's recovery, and nothing else, cleared the stall.
type stallableListener struct {
	net.Listener
	stalled atomic.Bool
}

// Accept hands the multiplexer only the connections that arrive while the
// listener is not stalled. A stalled one is accepted, so the client's connect
// succeeds, and then drained without a byte in reply until the client gives
// up and closes it. Drained rather than merely held so an abandoned request
// does not keep a descriptor open for the life of the process.
func (l *stallableListener) Accept() (net.Conn, error) {
	for {
		c, err := l.Listener.Accept()
		if err != nil || !l.stalled.Load() {
			return c, err
		}
		go func() {
			io.Copy(io.Discard, c)
			c.Close()
		}()
	}
}

// DebugStallLoopback makes the current loopback listener accept every new
// connection and never answer it, LocalAPI and SOCKS5 alike. TEST ONLY. This
// is the silent loopback no other hook produces: DebugDefunctLoopback refuses
// (-1004) at once, while a silent one costs every LocalAPI caller its full
// request timeout. Connections already accepted carry on. RestartLoopback
// replaces the listener and the stall goes with it.
func (s *Server) DebugStallLoopback() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	ln, ok := s.loopbackListener.(*stallableListener)
	if !ok {
		return errors.New("tsnet: loopback listener has not been started")
	}
	ln.stalled.Store(true)
	return nil
}
