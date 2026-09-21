package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"testing"
	"time"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
	"tailscale.com/tstest/integration/testcontrol"
)

// awaitRunning starts s and drives it to Running against ctl, completing its
// login (RequireAuth) and approving its device (RequireMachineAuth) itself.
// For the harness's own peers and the self-test's probes -- never for the
// app's node, whose login and approval are what the tests exercise.
func awaitRunning(ctx context.Context, s *tsnet.Server, ctl *testcontrol.Server, baseURL string) (*ipnstate.Status, error) {
	if err := s.Start(); err != nil {
		return nil, err
	}
	lc, err := s.LocalClient()
	if err != nil {
		return nil, err
	}
	for {
		st, err := lc.StatusWithoutPeers(ctx)
		if err == nil {
			switch {
			case st.BackendState == "Running":
				return st, nil
			case st.AuthURL != "":
				ctl.CompleteAuth(st.AuthURL)
			case st.BackendState == "NeedsMachineAuth" && st.Self != nil:
				k := st.Self.PublicKey
				ctl.CompleteDeviceApproval(baseURL, baseURL+"/admin", &k)
			}
		}
		select {
		case <-ctx.Done():
			state := "unknown"
			if st != nil {
				state = st.BackendState
			}
			return nil, fmt.Errorf("%w (last state %s)", errTimeout, state)
		case <-time.After(100 * time.Millisecond):
		}
	}
}

// fakeTB satisfies testing.TB for integration.RunDERPAndSTUN outside `go
// test`. A failure there is fatal to the harness: it cannot run without DERP.
type fakeTB struct{ *testing.T }

func (fakeTB) Cleanup(func())            {}
func (fakeTB) Error(a ...any)            { log.Fatal(a...) }
func (fakeTB) Errorf(f string, a ...any) { log.Fatalf(f, a...) }
func (fakeTB) Fail()                     { log.Fatal("fail") }
func (fakeTB) FailNow()                  { log.Fatal("failnow") }
func (fakeTB) Failed() bool              { return false }
func (fakeTB) Fatal(a ...any)            { log.Fatal(a...) }
func (fakeTB) Fatalf(f string, a ...any) { log.Fatalf(f, a...) }
func (fakeTB) Helper()                   {}
func (fakeTB) Log(a ...any)              {}
func (fakeTB) Logf(string, ...any)       {}
func (fakeTB) Name() string              { return "tsnet-harness" }
func (fakeTB) Setenv(string, string)     {}
func (fakeTB) Skip(...any)               {}
func (fakeTB) SkipNow()                  {}
func (fakeTB) Skipf(string, ...any)      {}
func (fakeTB) Skipped() bool             { return false }
func (fakeTB) TempDir() string {
	d, err := os.MkdirTemp("", "tsnet-harness-tb-")
	if err != nil {
		log.Fatal(err)
	}
	return d
}
