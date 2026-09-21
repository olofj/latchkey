package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
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
	if err := stays(ctx, p2, "NeedsLogin", 2*time.Second); err != nil {
		return err
	}
	ok("NeedsLogin, and it stays there until the login page is visited")

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

	if h.opts.gatewayAddr != "" || h.opts.slowPeer {
		if err := selftestExtraPeers(ctx, h, api, caFile); err != nil {
			return err
		}
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
