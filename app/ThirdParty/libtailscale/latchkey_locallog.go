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
// It never leaves the device: it is a local file, the directory is excluded
// from backup (App/Workspace/BackupExclusion.swift), and the app redacts it
// again before display.

package main

import (
	"io"
	"os"
	"sync"
	"time"
)

const localLogMax = 1 << 20 // 1 MiB per file

type localLog struct {
	mu   sync.Mutex
	path string
	f    *os.File
	size int64
	max  int64
}

// latchkeyLocalLog returns the writer for root/tsnet.log, or io.Discard if it
// cannot be opened (logging must never stop the node).
func latchkeyLocalLog(root string) io.Writer {
	l := &localLog{path: root + "/tsnet.log", max: localLogMax}
	if err := l.open(); err != nil {
		return io.Discard
	}
	return l
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

// rotate keeps exactly one predecessor, tsnet.log.1.
func (l *localLog) rotate() {
	l.f.Close()
	l.f = nil
	os.Rename(l.path, l.path+".1")
	if err := l.open(); err != nil {
		l.f = nil
	}
}
