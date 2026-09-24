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
//     The <id> is hostile by default -- mixed case, hyphens, a length that
//     varies -- because its shape is control's to choose and a fixture that
//     always fitted the app's redaction rule proved nothing (authpath.go;
//     -auth-path hex restores upstream's 20 lower-case hex).
//
//   - A plain-HTTP API for the tests (default 127.0.0.1:8491):
//
//     GET  /state     control URL, mode, nodes, logins, loginLinks (every
//     login path control issued this generation: the literal
//     secrets a scan of the app's container must not find), journal
//     POST /reset     ?auth=1 (RequireAuth) &machine=1 (RequireMachineAuth)
//     &gw=0 (leave the gw peer out of this generation):
//     a fresh control plane and fresh peers, returning once the
//     peers are Running. Each test starts from one, so nodes from
//     an earlier test never appear as peers.
//     POST /approve   ?hostname=NAME: approve that node's device (the admin
//     action RequireMachineAuth waits for)
//     POST /expire    ?hostname=NAME&in=SECONDS: set that node's key expiry
//     to now+SECONDS -- a date to warn about, or (<= 0) an
//     expired key, the admin console's "Expire key" (R31)
//     POST /deauthorize ?hostname=NAME: revoke that node's device
//     approval; it waits at NeedsMachineAuth until /approve (R31)
//     POST /purgatory ?on=1|0 (also /reset?purgatory=1): the device-check
//     rehearsal's tailnet policy -- the harness's peers drop traffic
//     from any node whose IPv4 address is outside the fixture
//     "clients" range (a SYN dropped silently, so every connection
//     times out; the peers stay visible). A new node lands outside it.
//     POST /move      ?hostname=NAME&to=IPV4: give that node the address, as
//     the admin console does to a running node; its peers and the
//     node itself get the change in their netmaps. Refused: a
//     harness peer, an address in use (the node's own included) or
//     in testcontrol's own pool, a name that fits more than one
//     node (409) or none (404)
//     POST /peers     ?n=N (default 1, at most 200 a generation) &name=PREFIX
//     (default peer) &os=OS (default linux): add N synthetic peers,
//     PREFIX-00 upward -- entries in control's table with no node
//     behind them, so a probe to one stalls. What lets a suite
//     present a large tailnet, and a truncated sweep, without N
//     real nodes (F7 §6; synthetic.go). Returns their hostnames
//     POST /peer-os   ?hostname=NAME&os=OS: the OS that node reports, held
//     against its own Hostinfo re-sends until the next reset -- gw
//     as a NAS, which discovery declines (F7 §6)
//     POST /peer-owner ?hostname=NAME&user=ID: that node's owner, held the
//     same way -- gw as a colleague's. ID is non-zero: 0 reaches
//     the app as "unknown", which is not another owner
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
//	              [-dashboard 127.0.0.1:8443] [-state DIR] [-auth-path hostile|hex] [-v]
//	tsnet-harness -selftest -ca ca.pem     (host-side self-test; see selftest.go)
package main

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"maps"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"tailscale.com/envknob"
	"tailscale.com/net/netns"
	"tailscale.com/net/tsaddr"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
	"tailscale.com/tstest/integration"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

// MagicDNSSuffix is the fixture tailnet. Never the real one: on a host whose
// own Tailscale is up, a real tailnet name would route through the host's VPN
// and a leak would succeed instead of failing (R10).
const MagicDNSSuffix = "tail-scale.ts.net"

// clientsRange stands in for the real policy's kiro-clients range in the
// device-check rehearsal (DEVICE-CHECK.md §3-4): with purgatory on, the
// harness's peers accept traffic only from nodes inside it, and testcontrol
// hands every new node a 100.64.0.x address, outside it. A fixture range:
// never the real policy's 100.81.0.0/24 or 100.82.1.0/24, and never Quad100.
var clientsRange = netip.MustParsePrefix("100.99.1.0/24")

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
	authPath      string // shape of the login links control issues: hostile or hex (authpath.go)
}

// Mode is the control plane's login policy and peer set, set per reset.
type Mode struct {
	RequireAuth        bool `json:"requireAuth"`
	RequireMachineAuth bool `json:"requireMachineAuth"`
	NoGateway          bool `json:"noGateway"`
	// Purgatory: the harness's peers drop traffic from nodes outside
	// clientsRange (the device-check rehearsal). Set by /purgatory too.
	Purgatory bool `json:"purgatory"`
}

type loginEvent struct {
	Gen       int       `json:"generation"`
	Path      string    `json:"path"`
	Completed bool      `json:"completed"`
	At        time.Time `json:"at"`
}

// loginLink is a login path control issued to a node: the secret a scan of
// the app's container must not find (authpath.go).
type loginLink struct {
	Gen  int       `json:"generation"`
	Path string    `json:"path"`
	At   time.Time `json:"at"`
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
	key  key.NodePublic
}

type harness struct {
	opts    options
	derp    *tailcfg.DERPMap
	baseURL string

	// resetMu serialises resets; purgatoryMu serialises applyPurgatory (its
	// bookkeeping and its SetJailed calls as one step, so two passes cannot
	// commit in one order and jail in the other). Neither is ever held by a
	// testcontrol lock's holder, and mu, which guards the fields below it,
	// is never held across a testcontrol call.
	resetMu     sync.Mutex
	purgatoryMu sync.Mutex

	mu      sync.Mutex
	ready   bool
	gen     int
	mode    Mode
	ctl     *testcontrol.Server
	peers   []*peer
	logins  []loginEvent
	links   []loginLink
	journal []connEvent
	// The device-check rehearsal, per generation. jailed: for each node the
	// purgatory policy has been applied to, which harness peers drop its
	// traffic.
	jailed map[key.NodePublic]map[key.NodePublic]bool // node => peer => jailed
	// F7 §6 (synthetic.go), per generation: the synthetic peers by key and
	// the next slot to name one from; the overrides on real ones by hostname.
	synthetic  map[key.NodePublic]bool
	syntheticN int
	overrides  map[string]override
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
	flag.StringVar(&o.authPath, "auth-path", "hostile", "shape of the login links control issues: hostile (mixed case, hyphens, varying length) or hex (upstream's 20 lower-case hex)")
	flag.BoolVar(&selftest, "selftest", false, "run the host-side self-test and exit")
	flag.StringVar(&caFile, "ca", "", "test CA (PEM) the self-test trusts for the dashboard")
	flag.Parse()
	if o.authPath != "hostile" && o.authPath != "hex" {
		log.Fatalf("-auth-path %q: want hostile or hex", o.authPath)
	}

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
	// A login renews the key, as on a real control plane. testcontrol does
	// not: a re-login after /expire clones the old node, past expiry and all,
	// onto the new key, which stays expired. It also does not say which node
	// an auth path belongs to, so every expired key is renewed (the tests
	// have one app node). Renewed means no expiry, the harness default.
	//
	// BEFORE CompleteAuth (R31 review): completing the auth releases the
	// client's followup register, which retires the old key's entry; renewing
	// after it could race that delete and write the old entry back (UpdateNode
	// adds what is missing), leaving a ghost second app node. Before it, the
	// followup is still parked, so both entries are there to renew. A visit
	// to an unknown link renews too, harmlessly: only already-expired keys.
	if ctl != nil {
		h.updateExpired(func(n *tailcfg.Node) { n.KeyExpiry = time.Time{} })
	}
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
	h.peers, h.ctl, h.logins, h.links, h.journal = nil, nil, nil, nil, nil
	h.jailed = map[key.NodePublic]map[key.NodePublic]bool{}
	h.synthetic, h.syntheticN, h.overrides = map[key.NodePublic]bool{}, 0, map[string]override{}
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
		// The purgatory policy reaches a node that joins later (the app, in
		// the device-check rehearsal) from its first map request, and holds
		// that request until it has; the OS and owner overrides are
		// re-asserted on each one: see holdMapRequest. testcontrol calls
		// this outside its own lock, which SetJailed and UpdateNode take.
		HoldMapRequest: func(req *tailcfg.MapRequest) func() {
			h.holdMapRequest(gen, req)
			return nil
		},
		// The login links control issues are hostile by default (-auth-path,
		// authpath.go), and each is recorded for GET /state. testcontrol
		// calls this outside its own lock.
		AuthPath: func() string {
			p := h.newAuthPath()
			h.mu.Lock()
			h.links = append(h.links, loginLink{Gen: gen, Path: p, At: time.Now()})
			h.mu.Unlock()
			return p
		},
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
	log.Printf("reset: generation %d, requireAuth=%v requireMachineAuth=%v purgatory=%v", gen, m.RequireAuth, m.RequireMachineAuth, m.Purgatory)
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
	if st.Self != nil {
		p.key = st.Self.PublicKey
	}
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
	// KeyExpired: the key's expiry has passed -- /expire, or the node
	// logged out (R32: a real logout expires the key at control).
	KeyExpired bool `json:"keyExpired"`
	// Jailed: the harness's peers drop this node's traffic (purgatory, and
	// its address is outside clientsRange).
	Jailed bool `json:"jailed"`
	// OS and UserID as the node's peers see them: what /peer-os and
	// /peer-owner change, and what discovery filters on (R26). Synthetic:
	// a /peers node -- HarnessPeer too, because the UI tests take the one
	// node that is not the harness's for the app's.
	OS        string `json:"os"`
	UserID    int64  `json:"userID"`
	Synthetic bool   `json:"synthetic"`
}

type state struct {
	Ready      bool         `json:"ready"`
	Generation int          `json:"generation"`
	Control    string       `json:"control"`
	Mode       Mode         `json:"mode"`
	Nodes      []nodeInfo   `json:"nodes"`
	Logins     []loginEvent `json:"logins"`
	LoginLinks []loginLink  `json:"loginLinks"`
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
		LoginLinks: []loginLink{},
		Journal:    []connEvent{},
		Nodes:      []nodeInfo{},
	}
	// reset() clears these lists, but an old peer's straggler can append
	// after that; its generation gives it away.
	for _, e := range h.logins {
		if e.Gen == h.gen {
			st.Logins = append(st.Logins, e)
		}
	}
	for _, l := range h.links {
		if l.Gen == h.gen {
			st.LoginLinks = append(st.LoginLinks, l)
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
	jailed := map[key.NodePublic]bool{}
	for k, at := range h.jailed {
		for _, j := range at {
			jailed[k] = jailed[k] || j
		}
	}
	synthetic := maps.Clone(h.synthetic)
	h.mu.Unlock()
	if ctl != nil {
		for _, n := range ctl.AllNodes() {
			ni := nodeInfo{
				Name:              n.Name,
				Hostname:          n.Hostinfo.Hostname(),
				MachineAuthorized: n.MachineAuthorized,
				KeyExpired:        !n.KeyExpiry.IsZero() && n.KeyExpiry.Before(time.Now()),
				Jailed:            jailed[n.Key],
				OS:                n.Hostinfo.OS(),
				UserID:            int64(n.User),
				Synthetic:         synthetic[n.Key],
			}
			ni.HarnessPeer = ours[ni.Hostname] || ni.Synthetic
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

// expire sets the key expiry of hostname's node to now+in and pushes the
// netmap: the node sees the date (R31's warning), or, when it is past, that
// its key has expired and it must log in again.
func (h *harness) expire(hostname string, in time.Duration) int {
	return h.updateNodes(hostname, func(n *tailcfg.Node) { n.KeyExpiry = time.Now().Add(in).UTC() })
}

// deauthorize revokes hostname's device approval, as an admin can after the
// fact: the node drops to NeedsMachineAuth until /approve.
func (h *harness) deauthorize(hostname string) int {
	return h.updateNodes(hostname, func(n *tailcfg.Node) { n.MachineAuthorized = false })
}

func (h *harness) updateNodes(hostname string, change func(*tailcfg.Node)) int {
	return h.updateWhere(func(n *tailcfg.Node) bool { return n.Hostinfo.Hostname() == hostname }, change)
}

func (h *harness) updateExpired(change func(*tailcfg.Node)) int {
	now := time.Now()
	return h.updateWhere(func(n *tailcfg.Node) bool { return !n.KeyExpiry.IsZero() && n.KeyExpiry.Before(now) }, change)
}

func (h *harness) updateWhere(match func(*tailcfg.Node) bool, change func(*tailcfg.Node)) int {
	h.mu.Lock()
	ctl := h.ctl
	h.mu.Unlock()
	if ctl == nil {
		return 0
	}
	n := 0
	for _, node := range ctl.AllNodes() { // clones
		if !match(node) {
			continue
		}
		change(node)
		ctl.UpdateNode(node)
		n++
	}
	return n
}

// --- The device-check rehearsal (DEVICE-CHECK.md §3-4) ---

// controlPool is where testcontrol assigns a new node's address from
// (serveRegister: 100.64.<id>>8.<id>). /move refuses an address in it: a
// node joining later could be handed the same one.
var controlPool = netip.MustParsePrefix("100.64.0.0/16")

// holdMapRequest runs on each map request, before testcontrol serves it
// (see reset). First the OS and owner overrides are re-asserted
// (enforceOverrides: the request is about to overwrite the node's stored
// Hostinfo, so this is the one place they can hold). Then, with purgatory
// on, a node the policy has not been applied to yet -- one that just
// joined -- is jailed at every harness peer. Synchronous, and it has to
// be: the map request that carries a node's endpoints is what wakes its
// peers, and a jail applied afterwards (an earlier version's goroutine)
// left a window in which the peers saw the node unjailed. Bounded, so a
// reset can never wait on it: neither step makes a blocking call
// (SetJailed's and UpdateNode's wake-ups are lossy sends) or takes a lock
// a testcontrol lock's holder takes.
func (h *harness) holdMapRequest(gen int, req *tailcfg.MapRequest) {
	h.enforceOverrides(gen, req)
	k := req.NodeKey
	h.mu.Lock()
	_, applied := h.jailed[k]
	ours := slices.ContainsFunc(h.peers, func(p *peer) bool { return p.key == k })
	skip := h.gen != gen || !h.mode.Purgatory || applied || ours
	h.mu.Unlock()
	if skip {
		return
	}
	h.applyPurgatory()
}

// setPurgatory switches the policy and applies it to every node now known.
func (h *harness) setPurgatory(on bool) {
	h.mu.Lock()
	h.mode.Purgatory = on
	h.mu.Unlock()
	h.applyPurgatory()
}

// applyPurgatory brings every node that is not a harness peer in line with
// the policy: purgatory on and its IPv4 address outside clientsRange means
// each harness peer jails it. SetJailed marks the node IsJailed in that
// peer's netmap, and the peer's data plane then runs the node's packets
// through a shields-up filter: its SYNs are dropped silently, so the sender
// times out -- what a packet filter with no grant does on the real tailnet.
// The peers stay in the node's own netmap, visible. SetJailed pushes netmaps
// to everyone each call, so it is called only for a change. One pass at a
// time (purgatoryMu): the bookkeeping decides what SetJailed is called with,
// and two passes interleaving between the two could leave the record and
// the control plane disagreeing.
func (h *harness) applyPurgatory() {
	h.purgatoryMu.Lock()
	defer h.purgatoryMu.Unlock()
	h.mu.Lock()
	ctl, peers, on, gen := h.ctl, h.peers, h.mode.Purgatory, h.gen
	// Synthetic peers are the harness's too: nothing behind them to jail,
	// and each SetJailed pushes netmaps to everyone.
	ours := maps.Clone(h.synthetic)
	h.mu.Unlock()
	if ctl == nil {
		return
	}
	for _, p := range peers {
		ours[p.key] = true
	}
	for _, n := range ctl.AllNodes() {
		if ours[n.Key] {
			continue
		}
		want := on && !inClientsRange(n)
		for _, p := range peers {
			h.mu.Lock()
			if h.gen != gen {
				h.mu.Unlock()
				return
			}
			at := h.jailed[n.Key]
			if at == nil {
				at = map[key.NodePublic]bool{}
				h.jailed[n.Key] = at
			}
			have, seen := at[p.key]
			at[p.key] = want
			h.mu.Unlock()
			if (seen && have == want) || (!seen && !want) {
				continue
			}
			ctl.SetJailed(p.key, n.Key, want)
		}
	}
}

func inClientsRange(n *tailcfg.Node) bool {
	for _, a := range n.Addresses {
		if a.Addr().Is4() && clientsRange.Contains(a.Addr()) {
			return true
		}
	}
	return false
}

// move gives hostname's node the IPv4 address to, as the admin console does
// to a running node. UpdateNode carries it to the peers and to the node
// itself: the vendored testcontrol builds a node's own netmap from its entry
// (upstream derived the address from the node's ID, so an earlier version
// pushed the node a raw netmap by hand -- which cost it every automatic one
// for the rest of the generation: a peer joining later, a re-login, were
// never seen). A re-login keeps the address: testcontrol clones the entry
// onto the new key. Then the purgatory policy is re-applied: a node moved
// into clientsRange is released. A refusal comes with its HTTP status.
func (h *harness) move(hostname string, to netip.Addr) (status int, err error) {
	if !to.Is4() || !tsaddr.CGNATRange().Contains(to) || to == tsaddr.TailscaleServiceIP() {
		return http.StatusBadRequest, fmt.Errorf("%s is not a tailnet IPv4 address", to)
	}
	if controlPool.Contains(to) {
		return http.StatusBadRequest, fmt.Errorf("%s is in testcontrol's own pool %s, where a later node could land", to, controlPool)
	}
	h.mu.Lock()
	ctl, peers := h.ctl, h.peers
	ours := maps.Clone(h.synthetic)
	h.mu.Unlock()
	if ctl == nil {
		return http.StatusServiceUnavailable, errors.New("control plane is resetting")
	}
	for _, p := range peers {
		ours[p.key] = true
	}
	var target *tailcfg.Node
	for _, n := range ctl.AllNodes() { // clones
		name := n.Hostinfo.Hostname()
		if slices.ContainsFunc(n.Addresses, func(p netip.Prefix) bool { return p.Addr() == to }) {
			if name == hostname {
				return http.StatusBadRequest, fmt.Errorf("%s already has %s", hostname, to)
			}
			return http.StatusBadRequest, fmt.Errorf("%s is already %s's address", to, name)
		}
		if name != hostname {
			continue
		}
		if ours[n.Key] {
			return http.StatusBadRequest, fmt.Errorf("%s is a harness peer", hostname)
		}
		if target != nil {
			return http.StatusConflict, fmt.Errorf("%s names more than one node", hostname)
		}
		target = n
	}
	if target == nil {
		return http.StatusNotFound, fmt.Errorf("no node named %s", hostname)
	}
	target.Addresses = replaceV4(target.Addresses, to)
	target.AllowedIPs = replaceV4(target.AllowedIPs, to)
	ctl.UpdateNode(target)
	h.applyPurgatory()
	return http.StatusOK, nil
}

// replaceV4 swaps the first IPv4 /32 in prefixes for to/32 (or adds it).
// The IPv6 address stays: on the real tailnet a move changes only the IPv4.
func replaceV4(prefixes []netip.Prefix, to netip.Addr) []netip.Prefix {
	out := slices.Clone(prefixes)
	for i, p := range out {
		if p.Addr().Is4() && p.IsSingleIP() {
			out[i] = netip.PrefixFrom(to, 32)
			return out
		}
	}
	return append(out, netip.PrefixFrom(to, 32))
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
			Purgatory:          r.URL.Query().Get("purgatory") == "1",
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
	mux.HandleFunc("POST /expire", func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("hostname")
		secs, err := strconv.Atoi(r.URL.Query().Get("in"))
		if name == "" || err != nil {
			reply(w, http.StatusBadRequest, map[string]any{"error": "hostname and in=SECONDS are required"})
			return
		}
		reply(w, http.StatusOK, map[string]any{"expired": h.expire(name, time.Duration(secs)*time.Second)})
	})
	mux.HandleFunc("POST /deauthorize", func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("hostname")
		if name == "" {
			reply(w, http.StatusBadRequest, map[string]any{"error": "hostname is required"})
			return
		}
		reply(w, http.StatusOK, map[string]any{"deauthorized": h.deauthorize(name)})
	})
	mux.HandleFunc("POST /purgatory", func(w http.ResponseWriter, r *http.Request) {
		on := r.URL.Query().Get("on")
		if on != "1" && on != "0" {
			reply(w, http.StatusBadRequest, map[string]any{"error": "on=1 or on=0 is required"})
			return
		}
		h.setPurgatory(on == "1")
		reply(w, http.StatusOK, map[string]any{"purgatory": on == "1"})
	})
	mux.HandleFunc("POST /move", func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("hostname")
		to, err := netip.ParseAddr(r.URL.Query().Get("to"))
		if name == "" || err != nil {
			reply(w, http.StatusBadRequest, map[string]any{"error": "hostname and to=IPV4 are required"})
			return
		}
		if status, err := h.move(name, to); err != nil {
			reply(w, status, map[string]any{"error": err.Error()})
			return
		}
		reply(w, http.StatusOK, map[string]any{"moved": 1})
	})
	mux.HandleFunc("POST /peers", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		n := 1
		if s := q.Get("n"); s != "" {
			v, err := strconv.Atoi(s)
			if err != nil || v < 1 || v > maxSynthetic {
				reply(w, http.StatusBadRequest, map[string]any{"error": fmt.Sprintf("n must be a number from 1 to %d", maxSynthetic)})
				return
			}
			n = v
		}
		prefix := cmp.Or(q.Get("name"), "peer")
		if !validLabel(prefix) {
			reply(w, http.StatusBadRequest, map[string]any{"error": "name must be a DNS label: lower-case letters, digits and hyphens, at most 60"})
			return
		}
		names, status, err := h.addPeers(n, prefix, cmp.Or(q.Get("os"), "linux"))
		if err != nil {
			reply(w, status, map[string]any{"error": err.Error()})
			return
		}
		reply(w, http.StatusOK, map[string]any{"added": len(names), "hostnames": names})
	})
	mux.HandleFunc("POST /peer-os", func(w http.ResponseWriter, r *http.Request) {
		name, os := r.URL.Query().Get("hostname"), r.URL.Query().Get("os")
		if name == "" || os == "" {
			reply(w, http.StatusBadRequest, map[string]any{"error": "hostname and os are required"})
			return
		}
		n, status, err := h.setPeerOS(name, os)
		if err != nil {
			reply(w, status, map[string]any{"error": err.Error()})
			return
		}
		reply(w, http.StatusOK, map[string]any{"updated": n})
	})
	mux.HandleFunc("POST /peer-owner", func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("hostname")
		user, err := strconv.ParseInt(r.URL.Query().Get("user"), 10, 64)
		if name == "" || err != nil || user < 0 {
			reply(w, http.StatusBadRequest, map[string]any{"error": "hostname and user=ID (a positive integer) are required"})
			return
		}
		if user == 0 {
			// The one value that would make a test worthless: exclusion()
			// reads 0 as owner unknown, which excludes nothing.
			reply(w, http.StatusBadRequest, map[string]any{"error": "user=0 is what the app reads as owner unknown, not as another owner"})
			return
		}
		n, status, err := h.setPeerOwner(name, tailcfg.UserID(user))
		if err != nil {
			reply(w, status, map[string]any{"error": err.Error()})
			return
		}
		reply(w, http.StatusOK, map[string]any{"updated": n})
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
