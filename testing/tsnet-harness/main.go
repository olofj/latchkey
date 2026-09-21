// Command tsnet-harness is the L2 test harness (PLAN M3, revision R17): a fake
// Tailscale control plane on the host, with real tsnet peers, that the app's
// real embedded node can join from the simulator.
//
// It replaces M3's original plan to link libtailscale's tstestcontrol archive
// into the iOS test target, which cannot work: controlhttpserver is
// `//go:build !ios`, the XCTest target is macOS-only, and the shim's shadowed
// `control` variable means stop_control never stops. The simulator shares the
// host's loopback, so a host process serves the same purpose with none of that.
//
// What runs, all in this process:
//
//   - testcontrol.Server on a FIXED loopback port (default 127.0.0.1:8490), so
//     the app's -TestControlURL is a constant. MagicDNS is on, with the
//     suffix tail-scale.ts.net -- the same fixture tailnet name the offline
//     suite uses, and NXDOMAIN in public DNS, so a name that leaks past the
//     node fails instead of resolving.
//
//   - DERP and STUN on 127.0.0.1.
//
//   - Peers. "dash" forwards tailnet :443 to the fake dashboard
//     (dashboard.py, which terminates TLS with the test CA's leaf for
//     dash.tail-scale.ts.net), and journals every connection with its tailnet
//     source address -- the proof a load went through the tailnet. "plain"
//     serves nothing: a second peer that is not a gateway. Optional, for
//     gateway discovery (M5): "gw" (-gateway) forwards to the fake KiroCrew
//     gateway -- a peer that IS one -- and "slow" (-slow-peer) accepts
//     connections and never answers, to prove a probe cannot stall the
//     sweep.
//
//   - The login page testcontrol lacks. With RequireAuth the node's
//     BrowseToURL is <control>/auth/<id>; visiting it completes that login,
//     as a browser that already has an identity-provider session would.
//
//   - A plain-HTTP API for the tests (default 127.0.0.1:8491):
//
//     GET  /state     control URL, mode, nodes, logins, journal
//     POST /reset     ?auth=1 (RequireAuth) &machine=1 (RequireMachineAuth)
//     &gw=0 (leave the gw peer out of this generation):
//     a fresh control plane and fresh peers, returning once the
//     peers are Running. Each test starts from one, so nodes from
//     an earlier test never appear as peers.
//     POST /approve   ?hostname=NAME: approve that node's device (the admin
//     action RequireMachineAuth waits for)
//     GET  /healthz   200 once the first reset has completed
//
// The harness sets the same no-log-upload knob as the app (decision D1):
// tsnet otherwise starts a logtail uploader to log.tailscale.com for every
// node, test nodes included. It also turns the port mapper off, so harness
// nodes never probe or ask the LAN router for mappings.
//
// What is and is not loopback-only: the control plane, the API, DERP and the
// dashboard target are 127.0.0.1. STUN and each node's WireGuard UDP socket
// bind all interfaces, as Tailscale's own code does; every address they are
// told to talk to is loopback.
//
// Isolation between tests: a reset starts a new control plane, and events
// (journal, logins) are stamped with the reset they belong to, so a straggler
// from the previous test can never satisfy the next one. Nodes still attached
// to an old control plane keep talking to it, isolated; the tests terminate
// their app, and one that reconnected later would join the new tailnet as a
// second app node, which TailnetHarnessTests treats as a failure.
//
//	tsnet-harness [-control 127.0.0.1:8490] [-api 127.0.0.1:8491] \
//	              [-dashboard 127.0.0.1:8443] [-state DIR] [-v]
//	tsnet-harness -selftest -ca ca.pem     (host-side self-test; see selftest.go)
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"tailscale.com/envknob"
	"tailscale.com/net/netns"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
	"tailscale.com/tstest/integration"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/logger"
)

// MagicDNSSuffix is the fixture tailnet. Never the real one: on a host whose
// own Tailscale is up, a real tailnet name would route through the host's VPN
// and a leak would succeed instead of failing (R10).
const MagicDNSSuffix = "tail-scale.ts.net"

func init() {
	// D1: no node in this process uploads logs. Must run before any tsnet
	// server starts; envknob is read when the logger is built.
	envknob.SetNoLogsNoSupport()
	// No NAT-PMP/PCP/UPnP: the tailnet is all loopback (as Tailscale's own
	// integration tests set it).
	envknob.Setenv("TS_DISABLE_PORTMAPPER", "1")
}

type options struct {
	controlAddr   string
	apiAddr       string
	dashboardAddr string
	gatewayAddr   string // the fake KiroCrew gateway; empty: no gw peer
	slowPeer      bool
	stateDir      string
	verbose       bool
}

// Mode is the control plane's login policy and peer set, set per reset.
type Mode struct {
	RequireAuth        bool `json:"requireAuth"`
	RequireMachineAuth bool `json:"requireMachineAuth"`
	NoGateway          bool `json:"noGateway"`
}

type loginEvent struct {
	Gen       int       `json:"generation"`
	Path      string    `json:"path"`
	Completed bool      `json:"completed"`
	At        time.Time `json:"at"`
}

type connEvent struct {
	Gen   int       `json:"generation"`
	Peer  string    `json:"peer"`
	From  string    `json:"from"` // tailnet source address of the connection
	At    time.Time `json:"at"`
	Error string    `json:"error,omitempty"` // the forward target failed
}

type peer struct {
	name string
	srv  *tsnet.Server
	ips  []string
}

type harness struct {
	opts    options
	derp    *tailcfg.DERPMap
	baseURL string

	// resetMu serialises resets; mu guards the fields below it.
	resetMu sync.Mutex

	mu      sync.Mutex
	ready   bool
	gen     int
	mode    Mode
	ctl     *testcontrol.Server
	peers   []*peer
	logins  []loginEvent
	journal []connEvent
}

func main() {
	var o options
	var selftest bool
	var caFile string
	flag.StringVar(&o.controlAddr, "control", "127.0.0.1:8490", "control plane listen address (loopback)")
	flag.StringVar(&o.apiAddr, "api", "127.0.0.1:8491", "test API listen address (loopback)")
	flag.StringVar(&o.dashboardAddr, "dashboard", "127.0.0.1:8443", "where the dash peer forwards tailnet :443")
	flag.StringVar(&o.gatewayAddr, "gateway", "", "add a gw peer forwarding tailnet :443 here (the fake KiroCrew gateway)")
	flag.BoolVar(&o.slowPeer, "slow-peer", false, "add a peer that accepts on :443 and never answers")
	flag.StringVar(&o.stateDir, "state", "", "tsnet state root; each run gets a fresh subdirectory (default: the system temp dir)")
	flag.BoolVar(&o.verbose, "v", false, "log tsnet and control-plane output")
	flag.BoolVar(&selftest, "selftest", false, "run the host-side self-test and exit")
	flag.StringVar(&caFile, "ca", "", "test CA (PEM) the self-test trusts for the dashboard")
	flag.Parse()

	// A fresh directory per process under the state root: generations are
	// numbered from 1 each run, and a node that found an earlier run's state
	// would present a key the new control plane has never seen.
	if o.stateDir != "" {
		if err := os.MkdirAll(o.stateDir, 0o755); err != nil {
			log.Fatal(err)
		}
	}
	d, err := os.MkdirTemp(o.stateDir, "run-")
	if err != nil {
		log.Fatal(err)
	}
	o.stateDir = d
	addrs := []string{o.controlAddr, o.apiAddr, o.dashboardAddr}
	if o.gatewayAddr != "" {
		addrs = append(addrs, o.gatewayAddr)
	}
	for _, a := range addrs {
		if !isLoopback(a) {
			log.Fatalf("%s is not a loopback address; the control plane, the API and the dashboard target are loopback only", a)
		}
	}

	h, err := start(o)
	if err != nil {
		log.Fatal(err)
	}
	if selftest {
		if err := runSelftest(h, caFile); err != nil {
			log.Fatalf("SELFTEST FAILED: %v", err)
		}
		fmt.Println("selftest: ok")
		os.Exit(0)
	}
	select {}
}

// start brings up DERP/STUN, the control and API listeners, and the first
// (open-mode) control plane with its peers.
func start(o options) (*harness, error) {
	// As libtailscale's tstestcontrol shim does: netns would bind sockets to
	// the default-route interface, which is wrong for a loopback-only
	// tailnet (Corp#4520).
	netns.SetEnabled(false)

	h := &harness{opts: o, baseURL: "http://" + o.controlAddr}
	var tb fakeTB
	h.derp = integration.RunDERPAndSTUN(tb, h.logf("derp"), "127.0.0.1")

	ctlLn, err := net.Listen("tcp", o.controlAddr)
	if err != nil {
		return nil, fmt.Errorf("control listener: %w", err)
	}
	apiLn, err := net.Listen("tcp", o.apiAddr)
	if err != nil {
		return nil, fmt.Errorf("api listener: %w", err)
	}
	go func() { log.Fatal(http.Serve(ctlLn, http.HandlerFunc(h.serveControl))) }()
	go func() { log.Fatal(http.Serve(apiLn, h.apiMux())) }()

	if err := h.reset(Mode{}); err != nil {
		return nil, err
	}
	h.mu.Lock()
	h.ready = true
	h.mu.Unlock()
	fmt.Printf("tsnet-harness: control %s  api http://%s  dash -> %s  state %s\n",
		h.baseURL, o.apiAddr, o.dashboardAddr, o.stateDir)
	return h, nil
}

func (h *harness) logf(prefix string) logger.Logf {
	if !h.opts.verbose {
		return logger.Discard
	}
	return func(format string, args ...any) {
		log.Printf("["+prefix+"] "+format, args...)
	}
}

// serveControl is the control plane: the login page testcontrol lacks, and
// testcontrol's own routes. Anything else is a 404 here, because testcontrol
// answers an unhandled path with `go panic(...)`, and a stray GET / (or a
// favicon fetch) would take the whole harness down.
func (h *harness) serveControl(w http.ResponseWriter, r *http.Request) {
	p := r.URL.Path
	if strings.HasPrefix(p, "/auth/") {
		h.serveLogin(w, r)
		return
	}
	if !(p == "/key" || p == "/ts2021" || p == "/generate_204" ||
		strings.HasPrefix(p, "/machine/") || strings.HasPrefix(p, "/c2n/")) {
		http.NotFound(w, r)
		return
	}
	h.mu.Lock()
	ctl := h.ctl
	h.mu.Unlock()
	if ctl == nil {
		http.Error(w, "control plane is resetting", http.StatusServiceUnavailable)
		return
	}
	ctl.ServeHTTP(w, r)
}

// serveLogin completes the login that <control>/auth/<id> belongs to. Visiting
// it IS the login, as for a browser already signed in to the identity
// provider. Idempotent: testcontrol completes an auth path at most once.
func (h *harness) serveLogin(w http.ResponseWriter, r *http.Request) {
	h.mu.Lock()
	ctl, gen := h.ctl, h.gen
	h.mu.Unlock()
	ok := ctl != nil && ctl.CompleteAuth(r.URL.Path)
	h.mu.Lock()
	if h.gen != gen {
		// A reset raced this visit: the login belonged to a control plane
		// that no longer exists. Neither record it nor call it a success.
		ok = false
	} else {
		h.logins = append(h.logins, loginEvent{Gen: gen, Path: r.URL.Path, Completed: ok, At: time.Now()})
	}
	h.mu.Unlock()
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		io.WriteString(w, "<!doctype html><title>Test tailnet login</title><h1>Unknown or expired login link</h1>")
		return
	}
	io.WriteString(w, "<!doctype html><meta name=viewport content=\"width=device-width\">"+
		"<title>Test tailnet login</title><h1 id=done>Signed in to the test tailnet</h1>"+
		"<p>You can return to the app.</p>")
}

// reset replaces the control plane and its peers. Nodes registered with the
// old control plane (a previous test's app) are gone with it.
func (h *harness) reset(m Mode) error {
	h.resetMu.Lock()
	defer h.resetMu.Unlock()

	h.mu.Lock()
	old := h.peers
	h.peers, h.ctl, h.logins, h.journal = nil, nil, nil, nil
	h.gen++
	gen := h.gen
	h.mode = m
	h.mu.Unlock()
	for _, p := range old {
		p.srv.Close()
	}

	ctl := &testcontrol.Server{
		DERPMap:            h.derp,
		ExplicitBaseURL:    h.baseURL,
		MagicDNSDomain:     MagicDNSSuffix,
		DNSConfig:          &tailcfg.DNSConfig{Proxied: true},
		RequireAuth:        m.RequireAuth,
		RequireMachineAuth: m.RequireMachineAuth,
		// One owner for every node, as on a personal tailnet: discovery
		// (M5, R26) filters peers by owner.
		AllNodesSameUser: true,
		// Peers are reported Online, as the real control plane reports a
		// connected node. testcontrol's default leaves Online unset, and
		// discovery (R26) skips offline peers -- it found nothing (M5).
		AllOnline: true,
		Logf:      h.logf("control"),
	}
	h.mu.Lock()
	h.ctl = ctl
	h.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	var peers []*peer
	for _, spec := range h.peerSpecs(m) {
		p, err := h.startPeer(ctx, ctl, gen, spec.name, spec.forward)
		if err != nil {
			for _, q := range peers {
				q.srv.Close()
			}
			return fmt.Errorf("peer %s: %w", spec.name, err)
		}
		peers = append(peers, p)
	}
	h.mu.Lock()
	h.peers = peers
	h.mu.Unlock()
	log.Printf("reset: generation %d, requireAuth=%v requireMachineAuth=%v", gen, m.RequireAuth, m.RequireMachineAuth)
	return nil
}

type peerSpec struct {
	name    string
	forward string // relay tailnet :443 here; "hold" accepts and never answers; "" nothing
}

// peerSpecs lists this generation's peers.
func (h *harness) peerSpecs(m Mode) []peerSpec {
	specs := []peerSpec{{"dash", h.opts.dashboardAddr}, {"plain", ""}}
	if h.opts.gatewayAddr != "" && !m.NoGateway {
		specs = append(specs, peerSpec{"gw", h.opts.gatewayAddr})
	}
	if h.opts.slowPeer {
		specs = append(specs, peerSpec{"slow", "hold"})
	}
	return specs
}

// startPeer brings a harness-owned node to Running, doing its own login and
// device approval when the mode requires them.
func (h *harness) startPeer(ctx context.Context, ctl *testcontrol.Server, gen int, name, forward string) (*peer, error) {
	s := &tsnet.Server{
		Dir:        filepath.Join(h.opts.stateDir, fmt.Sprintf("gen%d", gen), name),
		Hostname:   name,
		ControlURL: h.baseURL,
		Ephemeral:  true,
		Logf:       h.logf(name),
		UserLogf:   h.logf(name),
	}
	st, err := awaitRunning(ctx, s, ctl, h.baseURL)
	if err != nil {
		s.Close()
		return nil, err
	}
	p := &peer{name: name, srv: s}
	for _, ip := range st.TailscaleIPs {
		p.ips = append(p.ips, ip.String())
	}
	if forward != "" {
		ln, err := s.Listen("tcp", ":443")
		if err != nil {
			s.Close()
			return nil, err
		}
		if forward == "hold" {
			go h.hold(gen, name, ln)
		} else {
			go h.forward(gen, name, ln, forward)
		}
	}
	return p, nil
}

// hold accepts connections and never answers: a peer that stalls every
// probe until the prober gives up. Each accept is journaled, so a test can
// prove the peer was probed (M5 review).
func (h *harness) hold(gen int, name string, ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		h.mu.Lock()
		if gen == h.gen {
			h.journal = append(h.journal, connEvent{Gen: gen, Peer: name, From: c.RemoteAddr().String(), At: time.Now()})
		}
		h.mu.Unlock()
		go func() {
			io.Copy(io.Discard, c)
			c.Close()
		}()
	}
}

// forward relays each tailnet connection to target, journaling its source
// under the generation this peer belongs to.
func (h *harness) forward(gen int, name string, ln net.Listener, target string) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go func() {
			defer c.Close()
			ev := connEvent{Gen: gen, Peer: name, From: c.RemoteAddr().String(), At: time.Now()}
			up, err := net.DialTimeout("tcp", target, 5*time.Second)
			if err != nil {
				ev.Error = err.Error()
			}
			h.mu.Lock()
			if ev.Gen == h.gen {
				h.journal = append(h.journal, ev)
			}
			h.mu.Unlock()
			if err != nil {
				return
			}
			defer up.Close()
			done := make(chan struct{}, 2)
			go func() { io.Copy(up, c); done <- struct{}{} }()
			go func() { io.Copy(c, up); done <- struct{}{} }()
			<-done
		}()
	}
}

type nodeInfo struct {
	Name              string   `json:"name"`
	Hostname          string   `json:"hostname"`
	Addresses         []string `json:"addresses"`
	MachineAuthorized bool     `json:"machineAuthorized"`
	HarnessPeer       bool     `json:"harnessPeer"`
}

type state struct {
	Ready      bool         `json:"ready"`
	Generation int          `json:"generation"`
	Control    string       `json:"control"`
	Mode       Mode         `json:"mode"`
	Nodes      []nodeInfo   `json:"nodes"`
	Logins     []loginEvent `json:"logins"`
	Journal    []connEvent  `json:"journal"`
}

func (h *harness) snapshot() state {
	h.mu.Lock()
	st := state{
		Ready:      h.ready,
		Generation: h.gen,
		Control:    h.baseURL,
		Mode:       h.mode,
		Logins:     []loginEvent{},
		Journal:    []connEvent{},
		Nodes:      []nodeInfo{},
	}
	// reset() clears both lists, but an old peer's straggler can append after
	// that; its generation gives it away.
	for _, e := range h.logins {
		if e.Gen == h.gen {
			st.Logins = append(st.Logins, e)
		}
	}
	for _, e := range h.journal {
		if e.Gen == h.gen {
			st.Journal = append(st.Journal, e)
		}
	}
	ctl := h.ctl
	ours := map[string]bool{}
	for _, p := range h.peers {
		ours[p.name] = true
	}
	h.mu.Unlock()
	if ctl != nil {
		for _, n := range ctl.AllNodes() {
			ni := nodeInfo{
				Name:              n.Name,
				Hostname:          n.Hostinfo.Hostname(),
				MachineAuthorized: n.MachineAuthorized,
			}
			ni.HarnessPeer = ours[ni.Hostname]
			for _, a := range n.Addresses {
				ni.Addresses = append(ni.Addresses, a.Addr().String())
			}
			st.Nodes = append(st.Nodes, ni)
		}
	}
	return st
}

// approve does what a tailnet admin does for a device awaiting approval.
func (h *harness) approve(hostname string) int {
	h.mu.Lock()
	ctl := h.ctl
	h.mu.Unlock()
	if ctl == nil {
		return 0
	}
	n := 0
	for _, node := range ctl.AllNodes() {
		if node.MachineAuthorized || node.Hostinfo.Hostname() != hostname {
			continue
		}
		k := node.Key
		// testcontrol's odd contract: the URL must be <base>/admin.
		if ctl.CompleteDeviceApproval(h.baseURL, h.baseURL+"/admin", &k) {
			n++
		}
	}
	return n
}

func (h *harness) apiMux() *http.ServeMux {
	mux := http.NewServeMux()
	reply := func(w http.ResponseWriter, status int, v any) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		enc := json.NewEncoder(w)
		enc.SetIndent("", " ")
		enc.Encode(v)
	}
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		if !h.snapshot().Ready {
			reply(w, http.StatusServiceUnavailable, map[string]any{"ready": false})
			return
		}
		reply(w, http.StatusOK, map[string]any{"ready": true})
	})
	mux.HandleFunc("GET /state", func(w http.ResponseWriter, r *http.Request) {
		reply(w, http.StatusOK, h.snapshot())
	})
	mux.HandleFunc("POST /reset", func(w http.ResponseWriter, r *http.Request) {
		m := Mode{
			RequireAuth:        r.URL.Query().Get("auth") == "1",
			RequireMachineAuth: r.URL.Query().Get("machine") == "1",
			NoGateway:          r.URL.Query().Get("gw") == "0",
		}
		if err := h.reset(m); err != nil {
			reply(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
			return
		}
		reply(w, http.StatusOK, h.snapshot())
	})
	mux.HandleFunc("POST /approve", func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("hostname")
		if name == "" {
			reply(w, http.StatusBadRequest, map[string]any{"error": "hostname is required"})
			return
		}
		reply(w, http.StatusOK, map[string]any{"approved": h.approve(name)})
	})
	return mux
}

func isLoopback(hostport string) bool {
	host, _, err := net.SplitHostPort(hostport)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

var errTimeout = errors.New("timed out waiting for Running")
