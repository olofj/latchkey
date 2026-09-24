// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Latchkey modification to the vendored libtailscale (revision R1,
// decision D1): never upload logs to Tailscale's hosted log service.
//
// Upstream sends two streams to log.tailscale.com: the process-wide logtail
// built by TsnetSetupLogs (which also captures Go's stderr, so panics are
// uploaded on the next launch), and — when that is not set up — a per-node
// logtail built by tsnet's startLogger. Both construct their HTTP client with
// logpolicy.TransportOptions.New(), which returns a no-op transport that
// reports success without dialling whenever TS_NO_LOGS_NO_SUPPORT is set. So
// one switch covers both streams, and anything added upstream that goes
// through the same constructor.
//
// It must be set from Go, here. The app cannot set it: this library is a
// statically linked c-archive, and Go copies the process environment when its
// runtime starts — at image load, before Swift's main runs — so a setenv from
// Swift is never seen by os.Getenv. envknob.Setenv updates Go's own copy.
//
// init() rather than TsnetSetupLogs: it runs before any logger, transport or
// Hostinfo exists, whatever order the embedding app calls things in.
//
// Consequences, all accepted with D1:
//   - Logs are still written to the local filch buffers under the app's Logs
//     directory, and drained into the no-op transport. They never leave the
//     device.
//   - Hostinfo reports NoLogsNoSupport, so the admin console shows this node
//     as having logging disabled, and Tailscale support cannot pull its logs.
//   - If the tailnet enables network flow logs (CapabilityDataPlaneAuditLogs),
//     ipnlocal refuses to run a no-logs node: it sets WantRunning=false and
//     raises a health warning. Olof's tailnet does not use flow logs; if that
//     changes, this is why the app stops connecting.
//
// Verified by scripts/check-no-log-upload.sh in the parent repository, which
// samples the app's sockets and fails on any connection to the log hosts.

package main

import "tailscale.com/envknob"

func init() {
	envknob.SetNoLogsNoSupport()
}
