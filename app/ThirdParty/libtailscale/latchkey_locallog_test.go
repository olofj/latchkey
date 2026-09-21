// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

package main

import (
	"os"
	"strings"
	"testing"
)

func TestLocalLogStampsAndRotates(t *testing.T) {
	dir := t.TempDir()
	w := latchkeyLocalLog(dir)
	l, ok := w.(*localLog)
	if !ok {
		t.Fatalf("expected a file-backed writer, got %T", w)
	}
	l.max = 200 // small, to force rotation

	if _, err := w.Write([]byte("magicsock: first line\n")); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(dir + "/tsnet.log")
	got := string(b)
	if !strings.HasSuffix(got, " magicsock: first line\n") || !strings.Contains(got, "T") || !strings.Contains(got, "Z ") {
		t.Fatalf("line not timestamped as expected: %q", got)
	}
	if st, _ := os.Stat(dir + "/tsnet.log"); st.Mode().Perm() != 0o600 {
		t.Fatalf("tsnet.log is %v, want 0600", st.Mode().Perm())
	}

	w.Write([]byte("no trailing newline"))
	b, _ = os.ReadFile(dir + "/tsnet.log")
	if !strings.HasSuffix(string(b), "no trailing newline\n") {
		t.Fatalf("a missing newline must be added: %q", b)
	}

	for i := 0; i < 20; i++ {
		w.Write([]byte("derp: filler line to force rotation\n"))
	}
	cur, err := os.Stat(dir + "/tsnet.log")
	if err != nil {
		t.Fatal(err)
	}
	old, err := os.Stat(dir + "/tsnet.log.1")
	if err != nil {
		t.Fatal("no rotated predecessor:", err)
	}
	if cur.Size() > l.max || old.Size() > l.max {
		t.Fatalf("files exceed the cap: %d, %d > %d", cur.Size(), old.Size(), l.max)
	}
	if _, err := os.Stat(dir + "/tsnet.log.2"); err == nil {
		t.Fatal("only one predecessor may be kept")
	}
}

func TestLocalLogUnopenableIsDiscard(t *testing.T) {
	w := latchkeyLocalLog("/nonexistent-dir-for-latchkey-test")
	if _, ok := w.(*localLog); ok {
		t.Fatal("an unopenable log must fall back to io.Discard")
	}
}
