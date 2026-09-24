package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
	"tailscale.com/types/key"
)

// runSelftest exercises the harness from the host, through its own API, with
// probe nodes standing in for the app: the same checks the UI tests rely on,
// runnable without a simulator (`make check`). Each check is written so it can
// fail: a probe that reached Running by itself in auth mode, or a page that
// loaded without the tailnet, is an error.
func runSelftest(h *harness, caFile string) error {
	if caFile == "" {
		return fmt.Errorf("-ca is required: the dashboard's TLS leaf is signed by the test CA")
	}
	api := "http://" + h.opts.apiAddr
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	// --- open mode: join, see the peers, load the dashboard over the tailnet.
	step("open mode: a node joins and reaches Running with no interaction")
	if _, err := apiPost(api + "/reset"); err != nil {
		return err
	}
	probe, st, err := h.probe(ctx, "probe-open", "Running")
	if err != nil {
		return err
	}
	defer probe.Close()
	ok("state %s, addresses %v", st.BackendState, st.TailscaleIPs)

	step("MagicDNS: the peers appear as <name>.%s", MagicDNSSuffix)
	lc, _ := probe.LocalClient()
	full, err := lc.Status(ctx)
	if err != nil {
		return err
	}
	if got := full.CurrentTailnet.MagicDNSSuffix; got != MagicDNSSuffix {
		return fmt.Errorf("MagicDNSSuffix = %q, want %q", got, MagicDNSSuffix)
	}
	var dashIP string
	seen := map[string]bool{}
	for _, p := range full.Peer {
		seen[p.DNSName] = true
		if p.HostName == "dash" && len(p.TailscaleIPs) > 0 {
			dashIP = p.TailscaleIPs[0].String()
		}
	}
	for _, want := range []string{"dash." + MagicDNSSuffix + ".", "plain." + MagicDNSSuffix + "."} {
		if !seen[want] {
			return fmt.Errorf("peer %s missing; peers: %v", want, keys(seen))
		}
	}
	// Discovery (R26) skips offline peers and filters by OS: the harness
	// must report its peers as a real control plane would.
	for _, p := range full.Peer {
		if !p.Online {
			return fmt.Errorf("peer %s is reported offline; discovery would skip it", p.HostName)
		}
		if p.OS == "" {
			return fmt.Errorf("peer %s reports no OS", p.HostName)
		}
	}
	ok("peers %v", keys(seen))

	step("the dashboard loads by MagicDNS name through the node's loopback SOCKS5")
	addr, cred, _, err := probe.Loopback()
	if err != nil {
		return err
	}
	proxy := "socks5h://tsnet:" + cred + "@" + addr
	body, err := curl("--cacert", caFile, "--proxy", proxy, "https://dash."+MagicDNSSuffix+"/")
	if err != nil {
		return fmt.Errorf("fetch through the tailnet: %w\n%s", err, body)
	}
	if !strings.Contains(body, "FAKE DASHBOARD") {
		return fmt.Errorf("unexpected page: %.200q", body)
	}
	probeIP := st.TailscaleIPs[0].String()
	if !journalHas(h, "dash", probeIP) {
		return fmt.Errorf("the dash peer did not journal a connection from %s", probeIP)
	}
	ok("page served, and the dash peer journaled the connection from %s", probeIP)

	step("negative: the same name does NOT load without the tailnet")
	if out, err := curl("--cacert", caFile, "https://dash."+MagicDNSSuffix+"/"); err == nil {
		return fmt.Errorf("dash.%s loaded WITHOUT the tailnet -- the fixture name resolves publicly:\n%.200s", MagicDNSSuffix, out)
	}
	ok("fails (NXDOMAIN), so a load that succeeds went through a node")

	step("R17: harness 100.64.x addresses live in userspace netstacks")
	route, _ := exec.Command("route", "-n", "get", dashIP).CombinedOutput()
	iface := ""
	for _, line := range strings.Split(string(route), "\n") {
		if f := strings.Fields(line); len(f) == 2 && f[0] == "interface:" {
			iface = f[1]
		}
	}
	// Dial dash by its tailnet ADDRESS (socks5://, not socks5h://, and a
	// pinned resolve), with full certificate verification, and require the
	// dash peer to journal it: the harness's own dash answered, whatever the
	// host's routing table says about that address.
	before := journalCount(h, "dash", probeIP)
	if out, err := curl("--cacert", caFile, "--proxy", "socks5://tsnet:"+cred+"@"+addr,
		"--resolve", "dash."+MagicDNSSuffix+":443:"+dashIP,
		"https://dash."+MagicDNSSuffix+"/healthz"); err != nil {
		return fmt.Errorf("dash by tailnet address %s through the node: %w\n%s", dashIP, err, out)
	}
	if journalCount(h, "dash", probeIP) <= before {
		return fmt.Errorf("the connection to %s was not journaled by the harness's dash peer", dashIP)
	}
	if strings.HasPrefix(iface, "utun") {
		ok("dash at %s reached through the node and journaled, while the host routes %s via %s (a VPN claiming 100.64/10): the netstack never consults host routes",
			dashIP, dashIP, iface)
	} else {
		ok("dash at %s reached through the node and journaled; no conflicting host route here (%q), so this run shows less than it does on a host running Tailscale",
			dashIP, iface)
	}
	probe.Close()

	// --- RequireAuth: the node waits at NeedsLogin until its login URL is visited.
	step("RequireAuth: a node stops at NeedsLogin with a <control>/auth/ URL")
	if _, err := apiPost(api + "/reset?auth=1"); err != nil {
		return err
	}
	p2, st2, err := h.probe(ctx, "probe-auth", "NeedsLogin")
	if err != nil {
		return err
	}
	defer p2.Close()
	if !strings.HasPrefix(st2.AuthURL, h.baseURL+"/auth/") {
		return fmt.Errorf("AuthURL = %q, want a %s/auth/ URL", st2.AuthURL, h.baseURL)
	}
	// The link's shape is the harness's to choose (-auth-path, authpath.go):
	// by default hostile to every rule the project wrote for one, so the
	// app's redaction is really tested. /state lists each link issued, so a
	// scan of the app's container can look for the literal secret.
	seg := strings.TrimPrefix(st2.AuthURL, h.baseURL+"/auth/")
	if h.opts.authPath == "hostile" && !isHostileAuthSegment(seg) {
		return fmt.Errorf("AuthURL = %q with -auth-path hostile, but the link would satisfy the old rules", st2.AuthURL)
	}
	listed := false
	for _, l := range h.snapshot().LoginLinks {
		listed = listed || l.Path == "/auth/"+seg
	}
	if !listed {
		return fmt.Errorf("/state does not list the issued login link %q", "/auth/"+seg)
	}
	if err := stays(ctx, p2, "NeedsLogin", 2*time.Second); err != nil {
		return err
	}
	ok("NeedsLogin with a %s login link, listed in /state; it stays there until the login page is visited", h.opts.authPath)

	step("visiting the login URL completes the login")
	resp, err := http.Get(st2.AuthURL)
	if err != nil {
		return err
	}
	page, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !strings.Contains(string(page), "Signed in") {
		return fmt.Errorf("login page: %d %.200q", resp.StatusCode, page)
	}
	if _, err := waitState(ctx, p2, "Running"); err != nil {
		return err
	}
	ok("Running after the visit")

	step("an unknown login link is a 404, not a login")
	resp, err = http.Get(h.baseURL + "/auth/not-a-real-path")
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode != 404 {
		return fmt.Errorf("unknown login link: %d, want 404", resp.StatusCode)
	}
	ok("404")

	// --- R31: key expiry, as the admin console's "Expire key" or a real
	// expiry date does it.
	step("/expire in the future: the node sees its key expiry (the app warns 14 days ahead)")
	if out, err := apiPost(api + "/expire?hostname=probe-auth&in=864000"); err != nil || !strings.Contains(string(out), `"expired": 1`) {
		return fmt.Errorf("expire: %v %s", err, out)
	}
	lc2, _ := p2.LocalClient()
	var exp time.Time
	for end := time.Now().Add(20 * time.Second); time.Now().Before(end); time.Sleep(200 * time.Millisecond) {
		if st, err := lc2.StatusWithoutPeers(ctx); err == nil && st.Self != nil && st.Self.KeyExpiry != nil {
			exp = *st.Self.KeyExpiry
			if d := time.Until(exp); d > 9*24*time.Hour && d < 11*24*time.Hour {
				break
			}
		}
	}
	if d := time.Until(exp); d < 9*24*time.Hour || d > 11*24*time.Hour {
		return fmt.Errorf("the node's KeyExpiry is %v, want about 10 days from now", exp)
	}
	ok("KeyExpiry %s", exp.Format(time.RFC3339))

	step("/expire in the past: the node drops to NeedsLogin; a new login brings it back")
	if _, err := apiPost(api + "/expire?hostname=probe-auth&in=-60"); err != nil {
		return err
	}
	if err := waitBackend(ctx, p2, "NeedsLogin"); err != nil {
		return fmt.Errorf("after an expired key: %w", err)
	}
	if err := lc2.StartLoginInteractive(ctx); err != nil {
		return err
	}
	st2b, err := waitState(ctx, p2, "NeedsLogin") // with its new login URL
	if err != nil {
		return err
	}
	if resp, err := http.Get(st2b.AuthURL); err != nil {
		return err
	} else {
		resp.Body.Close()
	}
	if _, err := waitState(ctx, p2, "Running"); err != nil {
		return fmt.Errorf("after the new login: %w", err)
	}
	ok("NeedsLogin, then Running after a new login")
	p2.Close()

	// --- RequireMachineAuth: the node waits until an admin approves it.
	step("RequireMachineAuth: a node waits at NeedsMachineAuth until approved")
	if _, err := apiPost(api + "/reset?machine=1"); err != nil {
		return err
	}
	p3, _, err := h.probe(ctx, "probe-machine", "NeedsMachineAuth")
	if err != nil {
		return err
	}
	defer p3.Close()
	if err := stays(ctx, p3, "NeedsMachineAuth", 2*time.Second); err != nil {
		return err
	}
	out, err := apiPost(api + "/approve?hostname=probe-machine")
	if err != nil {
		return err
	}
	var ap struct{ Approved int }
	json.Unmarshal(out, &ap)
	if ap.Approved != 1 {
		return fmt.Errorf("approve: %s", out)
	}
	if _, err := waitState(ctx, p3, "Running"); err != nil {
		return err
	}
	ok("Running after /approve")

	step("/deauthorize: a Running node drops back to NeedsMachineAuth; /approve restores it")
	if out, err := apiPost(api + "/deauthorize?hostname=probe-machine"); err != nil || !strings.Contains(string(out), `"deauthorized": 1`) {
		return fmt.Errorf("deauthorize: %v %s", err, out)
	}
	if err := waitBackend(ctx, p3, "NeedsMachineAuth"); err != nil {
		return fmt.Errorf("after /deauthorize: %w", err)
	}
	if out, err := apiPost(api + "/approve?hostname=probe-machine"); err != nil || !strings.Contains(string(out), `"approved": 1`) {
		return fmt.Errorf("re-approve: %v %s", err, out)
	}
	if _, err := waitState(ctx, p3, "Running"); err != nil {
		return err
	}
	ok("NeedsMachineAuth, then Running after /approve")

	if h.opts.gatewayAddr != "" || h.opts.slowPeer {
		if err := selftestExtraPeers(ctx, h, api, caFile); err != nil {
			return err
		}
	}
	if err := selftestRehearsal(ctx, h, api, caFile); err != nil {
		return err
	}
	if err := selftestSynthetic(ctx, h, api); err != nil {
		return err
	}

	step("a reset isolates earlier nodes (one is still running)")
	if _, err := apiPost(api + "/reset"); err != nil {
		return err
	}
	// p3 is still up and still attached to the previous control plane. A
	// node joining the new one must see exactly the harness's peers.
	p4, _, err := h.probe(ctx, "probe-after-reset", "Running")
	if err != nil {
		return err
	}
	defer p4.Close()
	lc4, _ := p4.LocalClient()
	st4, err := lc4.Status(ctx)
	if err != nil {
		return err
	}
	var peers4 []string
	for _, p := range st4.Peer {
		peers4 = append(peers4, p.HostName)
	}
	sort.Strings(peers4)
	var want []string
	for _, p := range h.peerSpecs(Mode{}) {
		want = append(want, p.name)
	}
	sort.Strings(want)
	if strings.Join(peers4, ",") != strings.Join(want, ",") {
		return fmt.Errorf("after a reset a new node sees peers %v, want exactly %v", peers4, want)
	}
	ok("a new node sees exactly %v, not the still-running probe-machine", peers4)
	return nil
}

// probe starts a node the self-test drives by hand: unlike a harness peer, it
// does NOT complete its own login or approval. It returns once the node
// reports want.
func (h *harness) probe(ctx context.Context, name, want string) (*tsnet.Server, *ipnstate.Status, error) {
	h.mu.Lock()
	gen := h.gen
	h.mu.Unlock()
	s := &tsnet.Server{
		Dir:        filepath.Join(h.opts.stateDir, fmt.Sprintf("gen%d", gen), name),
		Hostname:   name,
		ControlURL: h.baseURL,
		Ephemeral:  true,
		Logf:       h.logf(name),
		UserLogf:   h.logf(name),
	}
	if err := s.Start(); err != nil {
		return nil, nil, err
	}
	st, err := waitState(ctx, s, want)
	if err != nil {
		s.Close()
		return nil, nil, fmt.Errorf("%s: %w", name, err)
	}
	return s, st, nil
}

func waitState(ctx context.Context, s *tsnet.Server, want string) (*ipnstate.Status, error) {
	lc, err := s.LocalClient()
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(45 * time.Second)
	last := "unknown"
	for time.Now().Before(deadline) {
		st, err := lc.StatusWithoutPeers(ctx)
		if err == nil {
			last = st.BackendState
			// NeedsLogin is only useful once the AuthURL has arrived.
			if last == want && (want != "NeedsLogin" || st.AuthURL != "") {
				return st, nil
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	return nil, fmt.Errorf("never reached %s (last %s)", want, last)
}

// waitBackend waits for a backend state alone (waitState's NeedsLogin also
// waits for a login URL, which an expired key does not get until a login
// starts).
func waitBackend(ctx context.Context, s *tsnet.Server, want string) error {
	lc, err := s.LocalClient()
	if err != nil {
		return err
	}
	last := "unknown"
	for end := time.Now().Add(45 * time.Second); time.Now().Before(end); time.Sleep(100 * time.Millisecond) {
		if st, err := lc.StatusWithoutPeers(ctx); err == nil {
			if last = st.BackendState; last == want {
				return nil
			}
		}
	}
	return fmt.Errorf("never reached %s (last %s)", want, last)
}

// stays fails if the node leaves state within d: a node that logs itself in
// would make the login tests vacuous.
func stays(ctx context.Context, s *tsnet.Server, state string, d time.Duration) error {
	lc, _ := s.LocalClient()
	end := time.Now().Add(d)
	for time.Now().Before(end) {
		st, err := lc.StatusWithoutPeers(ctx)
		if err == nil && st.BackendState != state {
			return fmt.Errorf("left %s for %s without the login/approval step", state, st.BackendState)
		}
		time.Sleep(200 * time.Millisecond)
	}
	return nil
}

func journalHas(h *harness, peer, fromIP string) bool {
	return journalCount(h, peer, fromIP) > 0
}

func journalCount(h *harness, peer, fromIP string) int {
	n := 0
	for _, ev := range h.snapshot().Journal {
		if ev.Peer == peer && ev.Error == "" && strings.HasPrefix(ev.From, fromIP+":") {
			n++
		}
	}
	return n
}

func curl(args ...string) (string, error) {
	cmd := exec.Command("curl", append([]string{"-sS", "--fail", "-m", "20"}, args...)...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func apiPost(url string) ([]byte, error) {
	resp, err := http.Post(url, "", nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return b, fmt.Errorf("POST %s: %d %s", url, resp.StatusCode, b)
	}
	return b, nil
}

func keys(m map[string]bool) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	return out
}

func step(format string, a ...any) { fmt.Fprintf(os.Stdout, "==> "+format+"\n", a...) }
func ok(format string, a ...any)   { fmt.Fprintf(os.Stdout, "    ok: "+format+"\n", a...) }

// selftestExtraPeers covers the discovery peers (M5), when the harness runs
// with them: gw forwards and is journaled, slow accepts and never answers,
// and ?gw=0 leaves gw out.
func selftestExtraPeers(ctx context.Context, h *harness, api, caFile string) error {
	if _, err := apiPost(api + "/reset"); err != nil {
		return err
	}
	probe, st, err := h.probe(ctx, "probe-extra", "Running")
	if err != nil {
		return err
	}
	defer probe.Close()
	addr, cred, _, err := probe.Loopback()
	if err != nil {
		return err
	}
	probeIP := st.TailscaleIPs[0].String()
	if h.opts.gatewayAddr != "" {
		step("gw peer: forwards tailnet :443 to %s, and is journaled", h.opts.gatewayAddr)
		// -k: whatever serves -gateway here need not hold a cert for gw's name;
		// what is under test is the forward and its journal entry.
		if out, err := curl("-k", "--proxy", "socks5h://tsnet:"+cred+"@"+addr, "https://gw."+MagicDNSSuffix+"/"); err != nil {
			return fmt.Errorf("gw forward: %w\n%s", err, out)
		}
		if !journalHas(h, "gw", probeIP) {
			return fmt.Errorf("the gw peer did not journal the connection from %s", probeIP)
		}
		ok("forwarded and journaled")
	}
	if h.opts.slowPeer {
		step("slow peer: accepts, and never answers a TLS ClientHello")
		start := time.Now()
		out, err := curl("-k", "-m", "2", "--proxy", "socks5h://tsnet:"+cred+"@"+addr, "https://slow."+MagicDNSSuffix+"/")
		if err == nil {
			return fmt.Errorf("the slow peer answered: %.100q", out)
		}
		if time.Since(start) < 1500*time.Millisecond {
			return fmt.Errorf("the slow peer failed fast (%v), not by stalling: %.100q", time.Since(start), out)
		}
		if !journalHas2(h, "slow", probeIP) {
			return fmt.Errorf("the slow peer did not journal the accept from %s", probeIP)
		}
		ok("stalled until the client gave up (%v), and journaled the accept", time.Since(start).Round(100*time.Millisecond))
	}
	if h.opts.gatewayAddr != "" {
		step("?gw=0 leaves the gw peer out of that generation")
		if _, err := apiPost(api + "/reset?gw=0"); err != nil {
			return err
		}
		for _, n := range h.snapshot().Nodes {
			if n.Hostname == "gw" {
				return fmt.Errorf("gw is present after /reset?gw=0")
			}
		}
		ok("gw absent")
	}
	return nil
}

// selftestRehearsal covers the device-check rehearsal's endpoints
// (DEVICE-CHECK.md §3-4): with purgatory on, a node outside the clients
// range sees the peers but reaches none; /move puts the running node in the
// range, it takes the address, and it reaches dash from it.
func selftestRehearsal(ctx context.Context, h *harness, api, caFile string) error {
	step("purgatory: a node outside %s sees the peers but reaches none", clientsRange)
	if _, err := apiPost(api + "/reset?purgatory=1"); err != nil {
		return err
	}
	probe, st, err := h.probe(ctx, "probe-purgatory", "Running")
	if err != nil {
		return err
	}
	defer probe.Close()
	probeIP := st.TailscaleIPs[0].String()
	if clientsRange.Contains(st.TailscaleIPs[0]) {
		return fmt.Errorf("a new node landed inside the clients range (%s); the fixture range must be one testcontrol never assigns", probeIP)
	}
	lc, _ := probe.LocalClient()
	full, err := lc.Status(ctx)
	if err != nil {
		return err
	}
	if _, ok := full.Peer[dashKey(full)]; !ok {
		return fmt.Errorf("dash is not visible to the jailed node; peers: %d", len(full.Peer))
	}
	// The policy is applied from the node's first map request, asynchronously:
	// wait for the harness to report it, then for the peers to have the netmap.
	if err := waitNode(h, "probe-purgatory", func(n nodeInfo) bool { return n.Jailed }); err != nil {
		return fmt.Errorf("the node was never jailed: %w", err)
	}
	time.Sleep(500 * time.Millisecond)
	addr, cred, _, err := probe.Loopback()
	if err != nil {
		return err
	}
	proxy := "socks5h://tsnet:" + cred + "@" + addr
	start := time.Now()
	out, err := curl("--cacert", caFile, "-m", "3", "--proxy", proxy, "https://dash."+MagicDNSSuffix+"/healthz")
	if err == nil {
		return fmt.Errorf("dash answered a node outside the clients range: %.100q", out)
	}
	if time.Since(start) < 2*time.Second {
		return fmt.Errorf("the connection failed fast (%v), not by a dropped SYN: %.100q", time.Since(start), out)
	}
	if journalHas2(h, "dash", probeIP) {
		return fmt.Errorf("dash accepted a connection from %s", probeIP)
	}
	ok("dash visible, and the connection from %s timed out (%v) with nothing accepted", probeIP, time.Since(start).Round(100*time.Millisecond))

	step("/move puts the running node in the clients range: it takes the address, and reaches dash from it")
	to := "100.99.1.5"
	if out, err := apiPost(api + "/move?hostname=probe-purgatory&to=" + to); err != nil || !strings.Contains(string(out), `"moved": 1`) {
		return fmt.Errorf("move: %v %s", err, out)
	}
	// The node itself, not just control, holds the new address.
	var ips []string
	for end := time.Now().Add(10 * time.Second); time.Now().Before(end); time.Sleep(200 * time.Millisecond) {
		if st, err := lc.StatusWithoutPeers(ctx); err == nil {
			ips = ips[:0]
			for _, ip := range st.TailscaleIPs {
				ips = append(ips, ip.String())
			}
			if slices.Contains(ips, to) {
				break
			}
		}
	}
	if !slices.Contains(ips, to) {
		return fmt.Errorf("the node's own addresses are %v, want %s among them", ips, to)
	}
	if slices.Contains(ips, probeIP) {
		return fmt.Errorf("the node kept its old address %s: %v", probeIP, ips)
	}
	if err := waitNode(h, "probe-purgatory", func(n nodeInfo) bool { return !n.Jailed }); err != nil {
		return fmt.Errorf("the moved node is still jailed: %w", err)
	}
	if out, err := curl("--cacert", caFile, "--proxy", proxy, "https://dash."+MagicDNSSuffix+"/healthz"); err != nil {
		return fmt.Errorf("dash after the move: %w\n%s", err, out)
	}
	if !journalHas(h, "dash", to) {
		return fmt.Errorf("the dash peer did not journal a connection from the new address %s", to)
	}
	ok("addresses %v, released, and dash journaled the connection from %s", ips, to)

	step("a moved node still hears of later control changes: a node that joins after the move")
	// Could fail: the harness once pushed a moved node its netmap by hand,
	// which made testcontrol suppress every automatic one after it, so a
	// later join never reached the moved node. Listed is not enough -- the
	// moved node dials the newcomer by its address, so its data plane, not
	// just its status, holds the new peer.
	late, lateSt, err := h.probe(ctx, "probe-late", "Running")
	if err != nil {
		return err
	}
	defer late.Close()
	lateIP := lateSt.TailscaleIPs[0].String()
	ln, err := late.Listen("tcp", ":7443")
	if err != nil {
		return err
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			io.WriteString(c, "late\n")
			c.Close()
		}
	}()
	listed := false
	for end := time.Now().Add(15 * time.Second); time.Now().Before(end) && !listed; time.Sleep(200 * time.Millisecond) {
		if st, err := lc.Status(ctx); err == nil {
			for _, p := range st.Peer {
				listed = listed || p.HostName == "probe-late"
			}
		}
	}
	if !listed {
		return fmt.Errorf("the moved node never listed probe-late among its peers")
	}
	dialCtx, cancelDial := context.WithTimeout(ctx, 15*time.Second)
	c, err := probe.Dial(dialCtx, "tcp", net.JoinHostPort(lateIP, "7443"))
	cancelDial()
	if err != nil {
		return fmt.Errorf("the moved node could not reach probe-late at %s: %w", lateIP, err)
	}
	greeting, _ := io.ReadAll(c)
	c.Close()
	if strings.TrimSpace(string(greeting)) != "late" {
		return fmt.Errorf("probe-late answered %q", greeting)
	}
	ok("probe-late (%s) listed by the moved node, and reached from it", lateIP)

	step("/move refuses what the admin console would not do, and an unknown name is a 404")
	for _, bad := range []struct{ query, want string }{
		{"hostname=dash&to=100.99.1.6", "is a harness peer"},
		{"hostname=probe-purgatory&to=100.100.100.100", "not a tailnet IPv4 address"},
		{"hostname=probe-purgatory&to=10.0.0.1", "not a tailnet IPv4 address"},
		{"hostname=probe-purgatory&to=fd7a:115c:a1e0::1", "not a tailnet IPv4 address"},
		{"hostname=probe-purgatory&to=100.64.0.9", "testcontrol's own pool"},
		{"hostname=probe-purgatory&to=" + to, "already has " + to},
		{"hostname=probe-late&to=" + to, "already probe-purgatory's address"},
	} {
		_, err := apiPost(api + "/move?" + bad.query)
		if err == nil {
			return fmt.Errorf("move accepted %s", bad.query)
		}
		if !strings.Contains(err.Error(), bad.want) {
			return fmt.Errorf("move refused %s for the wrong reason: %v (want %q)", bad.query, err, bad.want)
		}
	}
	if code := apiStatus(api + "/move?hostname=nobody&to=100.99.1.6"); code != http.StatusNotFound {
		return fmt.Errorf("move of an unknown hostname: %d, want 404", code)
	}
	ok("refused, each for its reason; unknown hostname 404")

	step("purgatory off: a new node reaches dash from where it lands")
	if out, err := apiPost(api + "/purgatory?on=0"); err != nil || !strings.Contains(string(out), `"purgatory": false`) {
		return fmt.Errorf("purgatory off: %v %s", err, out)
	}
	p2, st2, err := h.probe(ctx, "probe-released", "Running")
	if err != nil {
		return err
	}
	defer p2.Close()
	addr2, cred2, _, err := p2.Loopback()
	if err != nil {
		return err
	}
	if out, err := curl("--cacert", caFile, "--proxy", "socks5h://tsnet:"+cred2+"@"+addr2, "https://dash."+MagicDNSSuffix+"/healthz"); err != nil {
		return fmt.Errorf("dash with purgatory off: %w\n%s", err, out)
	}
	if !journalHas(h, "dash", st2.TailscaleIPs[0].String()) {
		return fmt.Errorf("the dash peer did not journal the connection from %s", st2.TailscaleIPs[0])
	}
	ok("reached from %s", st2.TailscaleIPs[0])

	step("/purgatory?on=1 mid-generation: a node already present outside the range is jailed; the moved node is not")
	// Could fail: a switch that reached only nodes joining afterwards would
	// leave probe-released talking to dash.
	if out, err := apiPost(api + "/purgatory?on=1"); err != nil || !strings.Contains(string(out), `"purgatory": true`) {
		return fmt.Errorf("purgatory on: %v %s", err, out)
	}
	if err := waitNode(h, "probe-released", func(n nodeInfo) bool { return n.Jailed }); err != nil {
		return fmt.Errorf("probe-released was not jailed: %w", err)
	}
	time.Sleep(500 * time.Millisecond)
	releasedIP := st2.TailscaleIPs[0].String()
	accepted := journalCount(h, "dash", releasedIP)
	start = time.Now()
	out, err = curl("--cacert", caFile, "-m", "3", "--proxy", "socks5h://tsnet:"+cred2+"@"+addr2, "https://dash."+MagicDNSSuffix+"/healthz")
	if err == nil {
		return fmt.Errorf("dash answered probe-released after purgatory came on: %.100q", out)
	}
	if time.Since(start) < 2*time.Second {
		return fmt.Errorf("probe-released failed fast (%v), not by a dropped SYN: %.100q", time.Since(start), out)
	}
	if journalCount(h, "dash", releasedIP) != accepted {
		return fmt.Errorf("dash accepted a connection from the jailed probe-released")
	}
	// The moved node, inside the range, is left alone -- and the switch's
	// netmap push reached it like any other control change.
	if err := waitNode(h, "probe-purgatory", func(n nodeInfo) bool { return !n.Jailed }); err != nil {
		return fmt.Errorf("the moved node was jailed by the switch: %w", err)
	}
	if out, err := curl("--cacert", caFile, "--proxy", proxy, "https://dash."+MagicDNSSuffix+"/healthz"); err != nil {
		return fmt.Errorf("dash from the moved node with purgatory back on: %w\n%s", err, out)
	}
	ok("probe-released timed out (%v) with nothing accepted; the moved node still reaches dash", time.Since(start).Round(100*time.Millisecond))
	return nil
}

// apiStatus is a POST's status code (apiPost folds a non-200 into an error).
func apiStatus(url string) int {
	resp, err := http.Post(url, "", nil)
	if err != nil {
		return 0
	}
	resp.Body.Close()
	return resp.StatusCode
}

// dashKey is the status key of the dash peer, or a zero key if absent.
func dashKey(st *ipnstate.Status) key.NodePublic {
	for k, p := range st.Peer {
		if p.HostName == "dash" {
			return k
		}
	}
	return key.NodePublic{}
}

// waitNode polls /state until hostname's node satisfies want.
func waitNode(h *harness, hostname string, want func(nodeInfo) bool) error {
	var last nodeInfo
	for end := time.Now().Add(10 * time.Second); time.Now().Before(end); time.Sleep(200 * time.Millisecond) {
		for _, n := range h.snapshot().Nodes {
			if n.Hostname == hostname {
				last = n
				if want(n) {
					return nil
				}
			}
		}
	}
	return fmt.Errorf("timed out; last %+v", last)
}

// journalHas2 matches any journal entry for peer from fromIP, errors
// included (a held connection records no error field either way).
func journalHas2(h *harness, peer, fromIP string) bool {
	for _, ev := range h.snapshot().Journal {
		if ev.Peer == peer && strings.HasPrefix(ev.From, fromIP+":") {
			return true
		}
	}
	return false
}

// selftestSynthetic covers the peer sets F7 §6 needs (synthetic.go):
// synthetic candidates the app's filter would accept, an OS and an owner
// set on a real peer that hold against that peer's own Hostinfo re-sends,
// and a reset that clears all of it. Each is a check the F7 suite would
// otherwise fail for a reason that looks like an app bug.
func selftestSynthetic(ctx context.Context, h *harness, api string) error {
	step("/peers: synthetic peers the app's filter would accept, listed by a node within seconds")
	if _, err := apiPost(api + "/reset"); err != nil {
		return err
	}
	probe, _, err := h.probe(ctx, "probe-synthetic", "Running")
	if err != nil {
		return err
	}
	defer probe.Close()
	lc, _ := probe.LocalClient()
	full, err := lc.Status(ctx)
	if err != nil {
		return err
	}
	selfUser := full.Self.UserID
	dash := peerNamed(full, "dash")
	if dash == nil {
		return fmt.Errorf("dash is not among the probe's peers")
	}
	realOS, realUser, before := dash.OS, dash.UserID, len(full.Peer)
	if selfUser == 0 || realUser != selfUser {
		return fmt.Errorf("the probe's owner is %d and dash's %d; the owner checks below need AllNodesSameUser", selfUser, realUser)
	}
	out, err := apiPost(api + "/peers?n=3")
	if err != nil {
		return err
	}
	var added struct {
		Added     int
		Hostnames []string
	}
	json.Unmarshal(out, &added)
	if added.Added != 3 || len(added.Hostnames) != 3 {
		return fmt.Errorf("/peers?n=3 answered %s", out)
	}
	var peers map[string]*ipnstate.PeerStatus
	var missing []string
	for end := time.Now().Add(15 * time.Second); time.Now().Before(end); time.Sleep(200 * time.Millisecond) {
		if full, err = lc.Status(ctx); err != nil {
			continue
		}
		peers, missing = peersByHost(full), nil
		for _, n := range added.Hostnames {
			if peers[n] == nil {
				missing = append(missing, n)
			}
		}
		if len(missing) == 0 {
			break
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("the probe never listed synthetic peers %v; its peers: %v", missing, keys(peersSeen(full)))
	}
	if got := len(full.Peer); got != before+3 {
		return fmt.Errorf("the probe lists %d peers, want %d + 3", got, before)
	}
	// One check per rule of GatewayCandidates.exclusion (R26): a peer that
	// fails one here is dropped by the app before it is a candidate, and
	// the F7 suite would see a small tailnet and no truncation.
	for _, n := range added.Hostnames {
		p := peers[n]
		if want := n + "." + MagicDNSSuffix + "."; p.DNSName != want {
			return fmt.Errorf("synthetic peer %s has DNSName %q, want %q: the app drops a peer with no MagicDNS name before any filter", n, p.DNSName, want)
		}
		if !p.Online {
			return fmt.Errorf("synthetic peer %s is reported offline", n)
		}
		if p.Expired || p.ShareeNode {
			return fmt.Errorf("synthetic peer %s is reported expired=%v sharee=%v", n, p.Expired, p.ShareeNode)
		}
		if !slices.Contains([]string{"linux", "macos", "windows"}, strings.ToLower(p.OS)) {
			return fmt.Errorf("synthetic peer %s reports OS %q, not a server OS", n, p.OS)
		}
		if p.UserID != selfUser {
			return fmt.Errorf("synthetic peer %s reports owner %d, the probe %d: the app would call it another owner", n, p.UserID, selfUser)
		}
	}
	// And /state, which is how a UI test waits for them instead of sleeping.
	for _, n := range added.Hostnames {
		var ni nodeInfo
		for _, x := range h.snapshot().Nodes {
			if x.Hostname == n {
				ni = x
			}
		}
		if !ni.Synthetic || !ni.HarnessPeer || ni.OS != "linux" || ni.UserID != int64(selfUser) || len(ni.Addresses) != 1 {
			return fmt.Errorf("/state lists %s as %+v", n, ni)
		}
		if a, _ := netip.ParseAddr(ni.Addresses[0]); !syntheticRange.Contains(a) || controlPool.Contains(a) || clientsRange.Contains(a) {
			return fmt.Errorf("%s has address %s, want one in %s and outside %s and %s", n, ni.Addresses[0], syntheticRange, controlPool, clientsRange)
		}
	}
	ok("%v: named, online, linux, owner %d; /state lists them as synthetic harness peers", added.Hostnames, selfUser)

	step("a synthetic peer has nothing behind it: a connection stalls until the client gives up, as a probe would")
	addr, cred, _, err := probe.Loopback()
	if err != nil {
		return err
	}
	proxy := "socks5h://tsnet:" + cred + "@" + addr
	start := time.Now()
	out2, err := curl("-k", "-m", "2", "--proxy", proxy, "https://"+added.Hostnames[0]+"."+MagicDNSSuffix+"/")
	if err == nil {
		return fmt.Errorf("synthetic peer %s answered: %.100q", added.Hostnames[0], out2)
	}
	if time.Since(start) < 1500*time.Millisecond {
		return fmt.Errorf("the connection to %s failed fast (%v), not by stalling: %.100q -- a sweep would race through such peers and never truncate", added.Hostnames[0], time.Since(start), out2)
	}
	ok("stalled until the client gave up (%v)", time.Since(start).Round(100*time.Millisecond))

	step("/peers, /peer-os and /peer-owner refuse what a test could not mean")
	for _, bad := range []struct{ query, want string }{
		{"/peers?n=abc", "n must be"},
		{"/peers?n=0", "n must be"},
		{"/peers?n=201", "n must be"},
		{"/peers?n=198", "already this generation"}, // 3 + 198 > 200
		{"/peers?name=Not_A_Label", "DNS label"},
		{"/peer-os?hostname=dash", "os are required"},
		{"/peer-owner?hostname=dash&user=0", "0 is what the app"},
		{"/peer-owner?hostname=dash&user=me", "user=ID"},
	} {
		_, err := apiPost(api + bad.query)
		if err == nil {
			return fmt.Errorf("accepted %s", bad.query)
		}
		if !strings.Contains(err.Error(), bad.want) {
			return fmt.Errorf("refused %s for the wrong reason: %v (want %q)", bad.query, err, bad.want)
		}
	}
	if code := apiStatus(api + "/peer-os?hostname=nobody&os=linux"); code != http.StatusNotFound {
		return fmt.Errorf("/peer-os for an unknown hostname: %d, want 404", code)
	}
	ok("refused, each for its reason; unknown hostname 404")

	step("/peer-os: dash reports the OS it was given, and keeps it after re-sending its own Hostinfo")
	if out, err := apiPost(api + "/peer-os?hostname=dash&os=synology"); err != nil || !strings.Contains(string(out), `"updated": 1`) {
		return fmt.Errorf("peer-os: %v %s", err, out)
	}
	if err := waitPeer(ctx, lc, "dash", func(p *ipnstate.PeerStatus) bool { return p.OS == "synology" }); err != nil {
		return fmt.Errorf("the probe never saw dash as synology: %w", err)
	}
	// Could fail: a node re-sends its Hostinfo whenever its netinfo or prefs
	// change, and testcontrol stores what it is sent. Force one, and require
	// control's copy, then the probe's, to still carry the override.
	if err := resendHostinfo(ctx, h, "dash"); err != nil {
		return err
	}
	n := h.controlNode("dash")
	if n == nil {
		return fmt.Errorf("dash is gone from control")
	}
	if got := n.Hostinfo.OS(); got != "synology" {
		return fmt.Errorf("after dash re-sent its Hostinfo, control holds OS %q, want synology: the override did not stick", got)
	}
	if st, err := lc.Status(ctx); err != nil {
		return err
	} else if d := peerNamed(st, "dash"); d == nil {
		return fmt.Errorf("dash is gone from the probe's peers")
	} else if d.OS != "synology" {
		return fmt.Errorf("after dash re-sent its Hostinfo the probe sees OS %q, want synology", d.OS)
	}
	ok("synology, before and after a Hostinfo re-send (dash's own is %s)", realOS)

	step("/peer-owner: dash reports a non-zero owner that is not the probe's own, held the same way")
	if out, err := apiPost(api + "/peer-owner?hostname=dash&user=777"); err != nil || !strings.Contains(string(out), `"updated": 1`) {
		return fmt.Errorf("peer-owner: %v %s", err, out)
	}
	// Verified, not assumed: the app reads a peer's owner off its node entry,
	// and an owner it could not see would arrive as 0, which exclusion()
	// treats as unknown -- no exclusion at all.
	if err := waitPeer(ctx, lc, "dash", func(p *ipnstate.PeerStatus) bool { return p.UserID == 777 }); err != nil {
		return fmt.Errorf("the probe never saw dash owned by 777: %w", err)
	}
	if err := resendHostinfo(ctx, h, "dash"); err != nil {
		return err
	}
	if n := h.controlNode("dash"); n == nil {
		return fmt.Errorf("dash is gone from control")
	} else if n.User != 777 {
		return fmt.Errorf("after dash re-sent its Hostinfo, control holds owner %d, want 777", n.User)
	}
	st, err := lc.Status(ctx)
	if err != nil {
		return err
	}
	if d := peerNamed(st, "dash"); d == nil {
		return fmt.Errorf("dash is gone from the probe's peers")
	} else if d.UserID == 0 || d.UserID == selfUser || d.UserID != 777 {
		return fmt.Errorf("dash reports owner %d (the probe's is %d), want 777", d.UserID, selfUser)
	}
	ok("owner 777 (the probe's is %d), held across a Hostinfo re-send", selfUser)

	step("/reset clears the synthetic peers and the overrides")
	if _, err := apiPost(api + "/reset"); err != nil {
		return err
	}
	p2, _, err := h.probe(ctx, "probe-synthetic-reset", "Running")
	if err != nil {
		return err
	}
	defer p2.Close()
	lc2, _ := p2.LocalClient()
	// The new dash registered with its own Hostinfo; an override that
	// outlived the generation would be applied at its next re-send, so
	// force one before looking.
	if err := resendHostinfo(ctx, h, "dash"); err != nil {
		return err
	}
	st2, err := lc2.Status(ctx)
	if err != nil {
		return err
	}
	for _, p := range st2.Peer {
		if strings.HasPrefix(p.HostName, "peer-") {
			return fmt.Errorf("synthetic peer %s survived the reset", p.HostName)
		}
	}
	for _, x := range h.snapshot().Nodes {
		if x.Synthetic {
			return fmt.Errorf("/state still lists %s as synthetic", x.Hostname)
		}
	}
	d := peerNamed(st2, "dash")
	if d == nil {
		return fmt.Errorf("dash is not among the new probe's peers")
	}
	if d.OS != realOS {
		return fmt.Errorf("after a reset dash reports OS %q, want its own %q: the override outlived the generation", d.OS, realOS)
	}
	if d.UserID == 0 || d.UserID != st2.Self.UserID {
		return fmt.Errorf("after a reset dash reports owner %d, the probe %d: the override outlived the generation", d.UserID, st2.Self.UserID)
	}
	if out, err = apiPost(api + "/peers?n=1"); err != nil {
		return err
	}
	added.Hostnames = nil
	json.Unmarshal(out, &added)
	if strings.Join(added.Hostnames, ",") != "peer-00" {
		return fmt.Errorf("after a reset /peers named its first peer %v, want peer-00: the numbering outlived the generation", added.Hostnames)
	}
	ok("gone; dash is %s again, owned by %d; numbering restarts at peer-00", d.OS, d.UserID)
	return nil
}

// peerNamed is the peer whose hostname is host, or nil.
func peerNamed(st *ipnstate.Status, host string) *ipnstate.PeerStatus {
	for _, p := range st.Peer {
		if p.HostName == host {
			return p
		}
	}
	return nil
}

func peersByHost(st *ipnstate.Status) map[string]*ipnstate.PeerStatus {
	m := map[string]*ipnstate.PeerStatus{}
	for _, p := range st.Peer {
		m[p.HostName] = p
	}
	return m
}

func peersSeen(st *ipnstate.Status) map[string]bool {
	m := map[string]bool{}
	for _, p := range st.Peer {
		m[p.HostName] = true
	}
	return m
}

// waitPeer polls the node's status until host satisfies want.
func waitPeer(ctx context.Context, lc *local.Client, host string, want func(*ipnstate.PeerStatus) bool) error {
	var last *ipnstate.PeerStatus
	for end := time.Now().Add(10 * time.Second); time.Now().Before(end); time.Sleep(200 * time.Millisecond) {
		if st, err := lc.Status(ctx); err == nil {
			if last = peerNamed(st, host); last != nil && want(last) {
				return nil
			}
		}
	}
	if last == nil {
		return fmt.Errorf("timed out; %s never listed", host)
	}
	return fmt.Errorf("timed out; %s last reported OS %q owner %d", host, last.OS, last.UserID)
}

// resendHostinfo makes the harness peer name send control a fresh copy of
// its own Hostinfo, as it does by itself whenever its netinfo or prefs
// change. ShieldsUp is a Hostinfo field, so setting it and clearing it
// again sends two, and control's stored copy shows each has been
// processed; the peer ends as it began.
func resendHostinfo(ctx context.Context, h *harness, name string) error {
	srv := h.peerServer(name)
	if srv == nil {
		return fmt.Errorf("no harness peer %s", name)
	}
	lc, err := srv.LocalClient()
	if err != nil {
		return err
	}
	for _, up := range []bool{true, false} {
		if _, err := lc.EditPrefs(ctx, &ipn.MaskedPrefs{Prefs: ipn.Prefs{ShieldsUp: up}, ShieldsUpSet: true}); err != nil {
			return err
		}
		seen := false
		for end := time.Now().Add(5 * time.Second); time.Now().Before(end) && !seen; time.Sleep(100 * time.Millisecond) {
			if n := h.controlNode(name); n != nil && n.Hostinfo.ShieldsUp() == up {
				seen = true
			}
		}
		if !seen {
			return fmt.Errorf("control never received %s's Hostinfo with ShieldsUp=%v: the re-send this check depends on did not happen", name, up)
		}
	}
	return nil
}

// peerServer is the harness's own node named name, or nil.
func (h *harness) peerServer(name string) *tsnet.Server {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, p := range h.peers {
		if p.name == name {
			return p.srv
		}
	}
	return nil
}

// controlNode is control's stored entry (a clone) for the first node named
// hostname, or nil: what every peer's next netmap will say about it.
func (h *harness) controlNode(hostname string) *tailcfg.Node {
	h.mu.Lock()
	ctl := h.ctl
	h.mu.Unlock()
	if ctl == nil {
		return nil
	}
	for _, n := range ctl.AllNodes() {
		if n.Hostinfo.Hostname() == hostname {
			return n
		}
	}
	return nil
}
