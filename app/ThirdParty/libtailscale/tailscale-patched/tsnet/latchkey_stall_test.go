// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

package tsnet

import (
	"errors"
	"net"
	"os"
	"testing"
	"time"
)

// ask connects to ln, writes a byte, and reports whether one came back
// within the wait. The server side echoes whatever the listener hands it.
func ask(t *testing.T, addr string, wait time.Duration) (answered bool) {
	t.Helper()
	c, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatalf("dial %s: %v (a stalled listener must still accept)", addr, err)
	}
	defer c.Close()
	if _, err := c.Write([]byte{'?'}); err != nil {
		t.Fatalf("write: %v", err)
	}
	c.SetReadDeadline(time.Now().Add(wait))
	var b [1]byte
	_, err = c.Read(b[:])
	if errors.Is(err, os.ErrDeadlineExceeded) {
		return false
	}
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	return true
}

func echoing(t *testing.T, ln net.Listener) {
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				var b [1]byte
				if _, err := c.Read(b[:]); err == nil {
					c.Write(b[:])
				}
			}()
		}
	}()
}

// The F16 hook: once stalled, a connect succeeds and nothing answers; a new
// listener, as RestartLoopback makes, is not stalled.
func TestLatchkeyStalledLoopbackAcceptsAndNeverAnswers(t *testing.T) {
	tcp, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ln := &stallableListener{Listener: tcp}
	defer ln.Close()
	echoing(t, ln)

	if !ask(t, ln.Addr().String(), 2*time.Second) {
		t.Fatal("an unstalled listener must answer")
	}
	ln.stalled.Store(true)
	if ask(t, ln.Addr().String(), 500*time.Millisecond) {
		t.Fatal("a stalled listener answered")
	}

	tcp2, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	replacement := &stallableListener{Listener: tcp2}
	defer replacement.Close()
	echoing(t, replacement)
	if !ask(t, replacement.Addr().String(), 2*time.Second) {
		t.Fatal("the replacement listener must not inherit the stall")
	}
}

// Closing a stalled listener ends Accept, so the serving goroutines exit as
// they do for an ordinary one.
func TestLatchkeyStalledLoopbackStillCloses(t *testing.T) {
	tcp, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ln := &stallableListener{Listener: tcp}
	ln.stalled.Store(true)
	done := make(chan error, 1)
	go func() { _, err := ln.Accept(); done <- err }()
	ln.Close()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("Accept returned a connection from a closed listener")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Accept did not return after Close")
	}
}
