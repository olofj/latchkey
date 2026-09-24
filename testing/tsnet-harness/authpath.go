// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

package main

import (
	"math/rand/v2"
	"strings"

	"tailscale.com/util/rands"
)

// The login link a node is sent is control's to shape: the client logs
// resp.AuthURL as received (controlclient/direct.go, "AuthURL is ...") and
// tsnet repeats it every 5 s while it waits ("go to: ..."). Upstream's
// testcontrol always issues /auth/ plus 20 lower-case hex characters, and
// every rule this project wrote for a login link matched exactly that shape
// -- the node log's /(a|auth)/[A-Za-z0-9]{8,}, and test-tailnet.sh's scan,
// /auth/[0-9a-f]{16,} -- so the end-to-end redaction check passed by
// construction, as the deny-list guard once did. By default the harness now
// issues links none of those rules match (hostileAuthPath); -auth-path hex
// restores upstream's shape. Every link issued is listed in GET /state as
// loginLinks, so a scan can look for the literal secrets rather than a
// shape of its own.

// hostileAuthPath returns a fresh login path with none of the regularities
// upstream's has: hyphen-separated groups of four, mixed case, letters
// beyond f, and 3 to 5 groups, so a segment of 14, 19 or 24 characters. A
// draw is checked (isHostileAuthSegment) and redrawn until it has every one
// of those properties, so a run of the suite can never be quietly gentle.
// The alphabet is URL-unreserved, so the path survives every parser as is.
func hostileAuthPath() string {
	const alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
	for {
		var b strings.Builder
		groups := 3 + rand.IntN(3)
		for g := range groups {
			if g > 0 {
				b.WriteByte('-')
			}
			for range 4 {
				b.WriteByte(alphabet[rand.IntN(len(alphabet))])
			}
		}
		if isHostileAuthSegment(b.String()) {
			return "/auth/" + b.String()
		}
	}
}

// isHostileAuthSegment reports whether seg defeats every shape assumption
// the project's login-link rules made: it has a hyphen and no run of 8 or
// more alphanumerics (the node log's old rule), an upper-case letter and a
// letter beyond f (the scan's lower-case hex), and a lower-case letter (so
// a rule written for upper case alone would not catch it either).
func isHostileAuthSegment(seg string) bool {
	var hyphen, upper, lower, beyondHex bool
	run := 0
	for _, c := range seg {
		if c == '-' {
			hyphen = true
			run = 0
			continue
		}
		switch {
		case 'A' <= c && c <= 'Z':
			upper = true
			beyondHex = beyondHex || c > 'F'
		case 'a' <= c && c <= 'z':
			lower = true
			beyondHex = beyondHex || c > 'f'
		}
		if run++; run >= 8 {
			return false
		}
	}
	return hyphen && upper && lower && beyondHex
}

// newAuthPath is testcontrol's AuthPath hook, per -auth-path.
func (h *harness) newAuthPath() string {
	if h.opts.authPath == "hex" {
		return "/auth/" + rands.HexString(20)
	}
	return hostileAuthPath()
}
