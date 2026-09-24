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
	w := newLocalLog(dir, true)
	s, ok := w.(*splitLog)
	if !ok {
		t.Fatalf("expected a file-backed writer, got %T", w)
	}
	l := s.tsnet
	l.max = 200 // small, to force rotation

	if _, err := w.Write([]byte("magicsock: first line\n")); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(dir + "/tsnet.log")
	got := string(b)
	if !strings.HasPrefix(got[strings.Index(got, " ")+1:], "latchkey: raw stderr (a Go panic from the last run) is kept") {
		t.Fatalf("the first line should say where raw stderr goes: %q", got)
	}
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
	w := newLocalLog("/nonexistent-dir-for-latchkey-test", true)
	if _, ok := w.(*splitLog); ok {
		t.Fatal("an unopenable log must fall back to io.Discard")
	}
}

// Raw stderr lines (logtail's RAW-STDERR re-emission) go to stderr.log,
// unprefixed, and never into tsnet.log -- under XCTest they outnumbered
// tsnet's own lines a hundred to one and pushed them out.
func TestLocalLogSplitsRawStderr(t *testing.T) {
	dir := t.TempDir()
	w := newLocalLog(dir, true)
	w.Write([]byte("magicsock: a tsnet line\n"))
	w.Write([]byte("RAW-STDERR: ***\n"))
	w.Write([]byte("RAW-STDERR: panic: from the last run\n"))
	w.Write([]byte("RAW-STDERR:\n"))
	w.Write([]byte("derp: another tsnet line\n"))

	ts, _ := os.ReadFile(dir + "/tsnet.log")
	raw, err := os.ReadFile(dir + "/stderr.log")
	if err != nil {
		t.Fatal("no stderr.log:", err)
	}
	if strings.Contains(string(ts), "RAW-STDERR") || strings.Contains(string(ts), "panic: from the last run") {
		t.Fatalf("a raw line reached tsnet.log:\n%s", ts)
	}
	if strings.Count(string(ts), "\n") != 3 || !strings.Contains(string(ts), " magicsock: a tsnet line\n") {
		t.Fatalf("tsnet.log should hold the header and exactly the two tsnet lines:\n%s", ts)
	}
	if strings.Contains(string(raw), "RAW-STDERR") || !strings.Contains(string(raw), "Z panic: from the last run\n") ||
		strings.Contains(string(raw), "magicsock") || strings.Count(string(raw), "\n") != 3 {
		t.Fatalf("stderr.log should hold the three raw lines, unprefixed and stamped:\n%s", raw)
	}
	if st, _ := os.Stat(dir + "/stderr.log"); st.Mode().Perm() != 0o600 {
		t.Fatalf("stderr.log is %v, want 0600", st.Mode().Perm())
	}
}

// With os_log mirrored to stderr (Xcode, XCTest), raw stderr is a copy of
// the unified log and is not kept; tsnet's lines still are.
func TestLocalLogDropsRawWhenOSLogIsMirrored(t *testing.T) {
	dir := t.TempDir()
	w := newLocalLog(dir, false)
	w.Write([]byte("RAW-STDERR: 2026-09-21 09:58:37.001160-0700 Latchkey[1:2] [Default] https://gw/?t=x\n"))
	w.Write([]byte("magicsock: a tsnet line\n"))
	if _, err := os.Stat(dir + "/stderr.log"); err == nil {
		t.Fatal("stderr.log must not be created when os_log is mirrored")
	}
	ts, _ := os.ReadFile(dir + "/tsnet.log")
	if strings.Contains(string(ts), "RAW-STDERR") || strings.Contains(string(ts), "gw/?t=") ||
		!strings.Contains(string(ts), "raw stderr not kept") || !strings.Contains(string(ts), " magicsock: a tsnet line\n") {
		t.Fatalf("tsnet.log: %s", ts)
	}
}

func TestOSLogMirroredReadsTheEnvironment(t *testing.T) {
	for v, want := range map[string]bool{"": false, "0": false, "NO": false, "false": false, "YES": true, "1": true, "enable": true} {
		t.Setenv("OS_ACTIVITY_DT_MODE", v)
		if got := osLogMirrored(); got != want {
			t.Errorf("OS_ACTIVITY_DT_MODE=%q: got %v, want %v", v, got, want)
		}
	}
}

// Nothing that can finish a login reaches the disk: tsnet's and control's
// real login-link lines, a raw stderr URL with userinfo and a token, and a
// code with punctuation after it or no scheme at all.
func TestLocalLogRedactsBeforeWriting(t *testing.T) {
	dir := t.TempDir()
	w := newLocalLog(dir, true)
	secrets := []string{"1a2b3c4d5e6f", "0123456789abcdef0123", "fk1.sessionsecret", "pw", "fragsecret", "9f8e7d6c5b4a"}
	w.Write([]byte("control: AuthURL is https://login.tailscale.com/a/1a2b3c4d5e6f\n"))
	w.Write([]byte("To start this tsnet server, restart with TS_AUTHKEY set, or go to: http://127.0.0.1:8490/auth/0123456789abcdef0123\n"))
	w.Write([]byte("RAW-STDERR: visit https://user:pw@gw.example.net/?token=fk1.sessionsecret#fragsecret now\n"))
	w.Write([]byte("see login.tailscale.com/a/9f8e7d6c5b4a.\n"))
	ts, _ := os.ReadFile(dir + "/tsnet.log")
	raw, _ := os.ReadFile(dir + "/stderr.log")
	for _, secret := range secrets {
		if strings.Contains(string(ts)+string(raw), secret) {
			t.Errorf("%q reached the disk:\n%s\n%s", secret, ts, raw)
		}
	}
	for _, want := range []string{"https://login.tailscale.com/a/…\n", "go to: http://127.0.0.1:8490/auth/…\n", "login.tailscale.com/a/….\n"} {
		if !strings.Contains(string(ts), want) {
			t.Errorf("tsnet.log lacks %q (what the line was should survive):\n%s", want, ts)
		}
	}
	if !strings.Contains(string(raw), "visit https://…@gw.example.net/?… now\n") {
		t.Errorf("stderr.log: %s", raw)
	}
}

// tsnet repeats the login line every 5 s while it waits: one line and a
// count, not a file full of them.
func TestLocalLogCollapsesRepeats(t *testing.T) {
	dir := t.TempDir()
	w := newLocalLog(dir, true)
	for i := 0; i < 5; i++ {
		w.Write([]byte("go to: http://127.0.0.1:8490/auth/0123456789abcdef0123\n"))
	}
	w.Write([]byte("magicsock: next\n"))
	ts, _ := os.ReadFile(dir + "/tsnet.log")
	if n := strings.Count(string(ts), "go to:"); n != 1 {
		t.Errorf("the repeated line was written %d times:\n%s", n, ts)
	}
	if !strings.Contains(string(ts), "(the line before repeated 4 more times)\n") || !strings.HasSuffix(string(ts), " magicsock: next\n") {
		t.Errorf("tsnet.log: %s", ts)
	}
}

// The mode comes from the launch: normally raw stderr (a Go panic) is kept;
// under Xcode or XCTest it is a mirror of the unified log and is not.
func TestLatchkeyLocalLogTakesTheModeFromTheLaunch(t *testing.T) {
	for _, c := range []struct {
		env    string
		kept   bool
		header string
	}{
		{"", true, "raw stderr (a Go panic from the last run) is kept in stderr.log"},
		{"YES", false, "raw stderr not kept: os_log is mirrored to it"},
	} {
		t.Setenv("OS_ACTIVITY_DT_MODE", c.env)
		dir := t.TempDir()
		w := latchkeyLocalLog(dir)
		w.Write([]byte("RAW-STDERR: panic: from the last run\n"))
		ts, _ := os.ReadFile(dir + "/tsnet.log")
		_, err := os.Stat(dir + "/stderr.log")
		if (err == nil) != c.kept || !strings.Contains(string(ts), c.header) {
			t.Errorf("OS_ACTIVITY_DT_MODE=%q: stderr.log kept=%v, tsnet.log %q", c.env, err == nil, ts)
		}
	}
}
