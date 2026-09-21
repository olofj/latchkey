// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Latchkey modification to the vendored libtailscale (PLAN M8.3, revisions
// R1 and R29, decision D1): keep a readable, local copy of tsnet's own logs.
//
// With uploads disabled (latchkey_nologs.go), the process logtail still
// drains its filch buffer -- into a no-op transport -- so every line tsnet
// logs (magicsock, DERP, control, the loopback listener) is consumed and
// gone within seconds. The app's log viewer showed only the app's own lines.
//
// logtail already echoes each line it logs to Config.Stderr, which upstream
// set to io.Discard. TsnetSetupLogs now points that echo here instead: a
// plain-text file under the app's Logs directory, one timestamped line per
// log line, capped at localLogMax bytes with one rotated predecessor, so at
// most twice that on disk. Only non-verbose lines are echoed (logtail's
// StderrLevel, 0), which is what a person debugging wants.
//
// logtail also re-emits, prefixed "RAW-STDERR: ", every line the process
// wrote to its raw stderr (which filch captures). Launched normally that is
// Go's own output -- a panic from the previous run -- and it goes to its own
// stderr.log, capped the same way, so it can never push tsnet's lines out.
// Launched by Xcode or XCTest, os_log is mirrored to stderr
// (OS_ACTIVITY_DT_MODE): raw stderr is then a copy of the unified log, every
// subsystem's messages -- thousands of lines a minute, other components' URLs
// among them -- and is not kept at all. The first line of each launch in
// tsnet.log says which.
//
// It never leaves the device: they are local files, the directory is
// excluded from backup (App/Workspace/BackupExclusion.swift), and the app
// redacts them again before display.

package main

import (
	"bytes"
	"io"
	"os"
	"strings"
	"sync"
	"time"
)

const localLogMax = 1 << 20 // 1 MiB per file

// rawStderrPrefix marks logtail's re-emission of a raw stderr line
// (logtail.go, drainPending).
const rawStderrPrefix = "RAW-STDERR:"

type localLog struct {
	mu   sync.Mutex
	path string
	f    *os.File
	size int64
	max  int64
}

// latchkeyLocalLog returns logtail's echo writer: tsnet's lines to
// root/tsnet.log, raw stderr lines to root/stderr.log. io.Discard if tsnet.log
// cannot be opened (logging must never stop the node); raw lines are dropped
// if stderr.log cannot be.
func latchkeyLocalLog(root string) io.Writer {
	return newLocalLog(root, !osLogMirrored())
}

func newLocalLog(root string, keepRaw bool) io.Writer {
	tsnet := openLocalLog(root + "/tsnet.log")
	if tsnet == nil {
		return io.Discard
	}
	s := &splitLog{tsnet: tsnet}
	if keepRaw {
		s.raw = openLocalLog(root + "/stderr.log")
		tsnet.Write([]byte("latchkey: raw stderr (a Go panic from the last run) is kept in stderr.log\n"))
	} else {
		tsnet.Write([]byte("latchkey: raw stderr not kept: os_log is mirrored to it (OS_ACTIVITY_DT_MODE)\n"))
	}
	return s
}

// osLogMirrored reports whether os_log also writes to stderr, as it does in
// launches by Xcode and XCTest.
func osLogMirrored() bool {
	switch strings.ToLower(os.Getenv("OS_ACTIVITY_DT_MODE")) {
	case "", "0", "no", "false":
		return false
	}
	return true
}

func openLocalLog(path string) *localLog {
	l := &localLog{path: path, max: localLogMax}
	if err := l.open(); err != nil {
		return nil
	}
	return l
}

// splitLog routes each echoed line (logtail writes one per call) by its
// prefix. The raw file drops the prefix: every line in it is raw.
type splitLog struct {
	tsnet *localLog
	raw   *localLog // nil: raw lines are dropped
}

func (s *splitLog) Write(p []byte) (int, error) {
	rest, isRaw := bytes.CutPrefix(p, []byte(rawStderrPrefix))
	if !isRaw {
		return s.tsnet.Write(p)
	}
	if s.raw != nil {
		s.raw.Write(bytes.TrimPrefix(rest, []byte(" ")))
	}
	return len(p), nil
}

func (l *localLog) open() error {
	f, err := os.OpenFile(l.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	l.f, l.size = f, st.Size()
	return nil
}

func (l *localLog) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.f == nil {
		return len(p), nil
	}
	line := make([]byte, 0, len(p)+32)
	line = time.Now().UTC().AppendFormat(line, "2006-01-02T15:04:05.000Z ")
	line = append(line, p...)
	if len(line) == 0 || line[len(line)-1] != '\n' {
		line = append(line, '\n')
	}
	if l.size+int64(len(line)) > l.max {
		l.rotate()
		if l.f == nil {
			return len(p), nil
		}
	}
	n, _ := l.f.Write(line)
	l.size += int64(n)
	return len(p), nil
}

// rotate keeps exactly one predecessor, <name>.1.
func (l *localLog) rotate() {
	l.f.Close()
	l.f = nil
	os.Rename(l.path, l.path+".1")
	if err := l.open(); err != nil {
		l.f = nil
	}
}
