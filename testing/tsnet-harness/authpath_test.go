// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

package main

import (
	"context"
	"net/http/httptest"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"tailscale.com/net/netns"
	"tailscale.com/tsnet"
	"tailscale.com/tstest/integration"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/logger"
)

// Every hostile link defeats the rules the project once relied on, differs
// from the last, and survives URL parsing unchanged (CompleteAuth and the
// login page key on the path as the client presents it).
func TestHostileAuthPathDefeatsTheOldRules(t *testing.T) {
	oldNodeLogRule := regexp.MustCompile(`/(a|auth)/[A-Za-z0-9]{8,}`) // latchkey_locallog.go before its fix
	oldScanRule := regexp.MustCompile(`/auth/[0-9a-f]{16,}`)          // test-tailnet.sh's LINK_RE
	seen := map[string]bool{}
	lengths := map[int]bool{}
	for range 1000 {
		p := hostileAuthPath()
		seg, ok := strings.CutPrefix(p, "/auth/")
		if !ok {
			t.Fatalf("%q does not begin with /auth/", p)
		}
		if !isHostileAuthSegment(seg) {
			t.Fatalf("%q is not hostile", p)
		}
		if oldNodeLogRule.MatchString(p) || oldScanRule.MatchString(p) {
			t.Fatalf("%q matches a rule it is meant to defeat", p)
		}
		if u, err := url.Parse("http://127.0.0.1:8490" + p); err != nil || u.Path != p || u.String() != "http://127.0.0.1:8490"+p {
			t.Fatalf("%q does not survive URL parsing: %v %q", p, err, u)
		}
		if seen[p] {
			t.Fatalf("%q was issued twice", p)
		}
		seen[p] = true
		lengths[len(seg)] = true
	}
	for _, n := range []int{14, 19, 24} {
		if !lengths[n] {
			t.Errorf("no segment of %d characters in 1000 draws; got lengths %v", n, lengths)
		}
	}
	if len(lengths) != 3 {
		t.Errorf("unexpected lengths: %v", lengths)
	}
}

// isHostileAuthSegment is the check that makes hostileAuthPath fail-capable,
// so pin what it refuses: each of upstream's shape and the gentle variants.
func TestIsHostileAuthSegment(t *testing.T) {
	for seg, want := range map[string]bool{
		"0F1e-2d3C-4b5A-6g7H":  true,
		"0F1e-2d3C-4bgA":       true,
		"0123456789abcdef0123": false, // upstream: lower-case hex, one run
		"0f1e-2d3c-4b5a":       false, // lower-case hex, hyphenated
		"0F1E-2D3C-4B5G":       false, // upper case only
		"0f1e2d3cAbGh":         false, // no hyphen: an 8+ run
		"0F1e-2d3C-4b5A":       false, // hex letters only
		"":                     false,
	} {
		if got := isHostileAuthSegment(seg); got != want {
			t.Errorf("isHostileAuthSegment(%q) = %v, want %v", seg, got, want)
		}
	}
}

// End to end, in this process: testcontrol with the harness's AuthPath hook
// sends a real tsnet node a hostile link, the node reports it as its
// AuthURL (what it then logs), CompleteAuth accepts the path as the login
// page presents it, and the node reaches Running.
func TestHostileLoginLinkCompletesALogin(t *testing.T) {
	if testing.Short() {
		t.Skip("starts a tsnet node")
	}
	netns.SetEnabled(false)
	derp := integration.RunDERPAndSTUN(t, logger.Discard, "127.0.0.1")
	var mu sync.Mutex
	var issued []string
	ctl := &testcontrol.Server{
		DERPMap:          derp,
		RequireAuth:      true,
		AllNodesSameUser: true,
		Logf:             logger.Discard,
		AuthPath: func() string {
			p := hostileAuthPath()
			mu.Lock()
			issued = append(issued, p)
			mu.Unlock()
			return p
		},
	}
	ctl.HTTPTestServer = httptest.NewUnstartedServer(ctl)
	ctl.HTTPTestServer.Start()
	defer ctl.HTTPTestServer.Close()

	s := &tsnet.Server{
		Dir:        t.TempDir(),
		Hostname:   "probe-hostile",
		ControlURL: ctl.HTTPTestServer.URL,
		Ephemeral:  true,
		Logf:       logger.Discard,
		UserLogf:   logger.Discard,
	}
	defer s.Close()
	if err := s.Start(); err != nil {
		t.Fatal(err)
	}
	lc, err := s.LocalClient()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	var link string
	for link == "" {
		if st, err := lc.StatusWithoutPeers(ctx); err == nil && st.AuthURL != "" {
			link = st.AuthURL
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal("the node never got a login link")
		case <-time.After(100 * time.Millisecond):
		}
	}
	seg, ok := strings.CutPrefix(link, ctl.HTTPTestServer.URL+"/auth/")
	if !ok || !isHostileAuthSegment(seg) {
		t.Fatalf("the node was sent %q, want a hostile %s/auth/ link", link, ctl.HTTPTestServer.URL)
	}
	mu.Lock()
	recorded := slices.Contains(issued, "/auth/"+seg)
	mu.Unlock()
	if !recorded {
		t.Fatalf("%q was not issued through the hook; issued: %q", link, issued)
	}

	// As serveLogin does: the path, as the browser presents it.
	if !ctl.CompleteAuth("/auth/" + seg) {
		t.Fatalf("CompleteAuth refused %q", "/auth/"+seg)
	}
	for {
		st, err := lc.StatusWithoutPeers(ctx)
		if err == nil && st.BackendState == "Running" {
			return
		}
		select {
		case <-ctx.Done():
			t.Fatal("the node never reached Running after the hostile login")
		case <-time.After(100 * time.Millisecond):
		}
	}
}
