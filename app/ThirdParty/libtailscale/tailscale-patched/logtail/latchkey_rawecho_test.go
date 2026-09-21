// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Latchkey modification (PLAN M8.3, revision R29): the RAW-STDERR echo in
// drainPending writes the raw line itself. Upstream wrote b, the whole upload
// batch accumulated so far -- unnoticed there because the echo went to
// io.Discard, but with the echo kept in a local tsnet.log every stray stderr
// line copied the pending batch into the file, which filled 1 MiB in minutes.

package logtail

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"tailscale.com/tstest"
)

func TestLatchkeyRawStderrEchoesTheLineNotTheBatch(t *testing.T) {
	buf := NewMemoryBuffer(100)
	var echo bytes.Buffer
	lg := &Logger{
		clock:  tstest.NewClock(tstest.ClockOpts{Start: time.Unix(123, 0)}),
		buffer: buf,
		stderr: &echo,
	}
	buf.Write([]byte(`{"logtail":{"client_time":"1970-01-01T00:02:03Z"},"text":"already structured"}` + "\n"))
	buf.Write([]byte("panic: from the last run\n"))
	buf.Write([]byte("goroutine 1 [running]:\n"))

	body, _, _ := lg.drainPending(false)

	got := echo.String()
	if strings.Contains(got, "already structured") || strings.Contains(got, `"logtail"`) {
		t.Errorf("the echo carried the upload batch:\n%s", got)
	}
	for _, want := range []string{
		"RAW-STDERR: panic: from the last run\n",
		"RAW-STDERR: goroutine 1 [running]:\n",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("the echo lacks %q:\n%s", want, got)
		}
	}
	if n := strings.Count(got, "RAW-STDERR: ***\n"); n != 2 {
		t.Errorf("the explanation is printed once (2 *** lines); got %d:\n%s", n, got)
	}
	// Unchanged: the raw lines are still encoded into the batch.
	for _, want := range []string{"already structured", "panic: from the last run", "goroutine 1 [running]:"} {
		if !strings.Contains(string(body), want) {
			t.Errorf("the batch lacks %q: %s", want, body)
		}
	}
}
