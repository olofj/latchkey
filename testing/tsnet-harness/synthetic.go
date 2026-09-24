package main

// Synthetic peers and per-node overrides: the peer sets F7 §6 needs, none of
// which a generation of real tsnet peers can present cheaply.
//
//   - A large tailnet. Forty candidates -- enough that a 12 s sweep of 4 s
//     probes must truncate -- would be forty userspace stacks. A synthetic
//     peer is an entry in testcontrol's table and nothing else: the app's
//     node sees it in its netmap as a candidate, and a probe to it stalls,
//     because no key behind it will ever answer a handshake, until the
//     app's own per-request timeout. The self-test measures the stall.
//   - A gateway the filter declines. /peer-os and /peer-owner change what a
//     REAL peer reports, so gw can be a NAS ("OS synology") or a
//     colleague's ("another owner") and still answer when the owner taps it.
//
// What a synthetic entry must carry follows from GatewayCandidates.exclusion
// (R26) read against ipnlocal's PeerStatus. Name is the MagicDNS FQDN with
// its trailing dot, as serveRegister builds one: the app reads DNSName and
// drops a nameless peer before any filter is asked, so nothing about it
// would show. User is the UserID every real node already has
// (AllNodesSameUser), read off the table rather than assumed, because any
// other is "another owner". Hostinfo carries Hostname and a server OS.
// testcontrol's AddFakeNode sets neither Hostinfo nor Name, which is why it
// is not used.

import (
	"errors"
	"fmt"
	"maps"
	"net/http"
	"net/netip"

	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
)

// maxSynthetic caps a generation's synthetic peers: one /24 of addresses,
// and five times what F7 §6 asks for.
const maxSynthetic = 200

// syntheticAddr writes the slot into the last octet; this fails to compile
// if the cap ever outgrows it.
const _ = uint8(maxSynthetic + 1)

// syntheticRange is where synthetic peers get their addresses: a fixture
// range in the CGNAT block, outside controlPool (a node registering later
// could be handed the same address) and outside clientsRange (an address
// there means something to the device-check rehearsal). Never the real
// policy's ranges; see clientsRange.
var syntheticRange = netip.MustParsePrefix("100.98.0.0/24")

// syntheticIDBase keeps synthetic node IDs clear of testcontrol's, which
// count up from 1 as nodes register.
const syntheticIDBase = 1 << 20

// override is what /peer-os and /peer-owner set on the nodes of one
// hostname, kept so every map request can re-assert it (enforceOverrides).
type override struct {
	os   string         // "" leaves the node's own
	user tailcfg.UserID // 0 leaves the node's own
}

// addPeers adds n synthetic peers named prefix-NN, numbered from the
// generation's next slot, and pushes them to every node. The slots are
// reserved under mu, so two calls cannot share a name or an address, and
// the cap is on the generation's total.
func (h *harness) addPeers(n int, prefix, os string) (names []string, status int, err error) {
	h.mu.Lock()
	ctl, gen, first := h.ctl, h.gen, h.syntheticN
	if ctl != nil && first+n <= maxSynthetic {
		h.syntheticN += n
	}
	reowned := map[string]bool{}
	for name, ov := range h.overrides {
		reowned[name] = ov.user != 0
	}
	h.mu.Unlock()
	if ctl == nil {
		return nil, http.StatusServiceUnavailable, errors.New("control plane is resetting")
	}
	if first+n > maxSynthetic {
		return nil, http.StatusBadRequest, fmt.Errorf("%d synthetic peers already this generation; at most %d", first, maxSynthetic)
	}
	// The owner comes from a real node whose owner has not been changed. A
	// constant that drifted from testcontrol's (123 today) would make every
	// synthetic peer "another owner", and nothing would say so.
	var owner tailcfg.UserID
	for _, node := range ctl.AllNodes() {
		if !reowned[node.Hostinfo.Hostname()] {
			owner = node.User
			break
		}
	}
	if owner == 0 {
		return nil, http.StatusServiceUnavailable, errors.New("no node to take the owner from")
	}
	for slot := first; slot < first+n; slot++ {
		name := fmt.Sprintf("%s-%02d", prefix, slot)
		addr := netip.PrefixFrom(syntheticAddr(slot), 32)
		nk := key.NewNode().Public()
		node := &tailcfg.Node{
			ID:                tailcfg.NodeID(syntheticIDBase + slot),
			StableID:          tailcfg.StableNodeID(fmt.Sprintf("SYNTH%08x", slot)),
			Name:              name + "." + MagicDNSSuffix + ".",
			User:              owner,
			Key:               nk,
			Machine:           key.NewMachine().Public(),
			DiscoKey:          key.NewDisco().Public(),
			Addresses:         []netip.Prefix{addr},
			AllowedIPs:        []netip.Prefix{addr},
			Hostinfo:          (&tailcfg.Hostinfo{Hostname: name, OS: os}).View(),
			MachineAuthorized: true,
		}
		// Recorded before the push: a /state read between the two would
		// list it as an app node, and the UI tests take the one node that
		// is not the harness's for the app's.
		h.mu.Lock()
		if h.gen == gen {
			h.synthetic[nk] = true
		}
		h.mu.Unlock()
		ctl.UpdateNode(node)
		names = append(names, name)
	}
	return names, http.StatusOK, nil
}

func syntheticAddr(slot int) netip.Addr {
	a := syntheticRange.Addr().As4()
	a[3] = byte(slot + 1) // .1 upward, never the network address
	return netip.AddrFrom4(a)
}

// validLabel is a DNS label a synthetic hostname can be built on: lower
// case, so the hostname and the FQDN agree, and short enough for its -NN.
func validLabel(s string) bool {
	if s == "" || len(s) > 60 || s[0] == '-' || s[len(s)-1] == '-' {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return true
}

// setPeerOS makes hostname's nodes report os, now and at every later map
// request (enforceOverrides).
func (h *harness) setPeerOS(hostname, os string) (updated, status int, err error) {
	return h.setOverride(hostname, func(ov *override) { ov.os = os }, func(n *tailcfg.Node) {
		hi := n.Hostinfo.AsStruct()
		hi.OS = os
		n.Hostinfo = hi.View()
	})
}

// setPeerOwner gives hostname's nodes the owner user. User only: Sharer
// would make it a shared-in node, which the app declines for a different
// reason. The app reads a peer's owner off its node entry (ipnlocal fills
// PeerStatus.UserID from p.User()), not off the netmap's UserProfiles, so
// no profile is needed for it to see a real, different owner -- which is as
// well, since testcontrol offers no way to add one. The self-test holds
// this to account rather than trusting it.
func (h *harness) setPeerOwner(hostname string, user tailcfg.UserID) (updated, status int, err error) {
	return h.setOverride(hostname, func(ov *override) { ov.user = user }, func(n *tailcfg.Node) { n.User = user })
}

// setOverride records the override, then pushes it. In that order: a map
// request arriving between the two is rewritten as well. It is taken back
// when no node has the name -- an override for a name nothing carries
// would lie in wait for whatever registers under it later.
func (h *harness) setOverride(hostname string, record func(*override), change func(*tailcfg.Node)) (updated, status int, err error) {
	h.mu.Lock()
	ctl := h.ctl
	before, had := h.overrides[hostname]
	ov := before
	record(&ov)
	h.overrides[hostname] = ov
	h.mu.Unlock()
	if ctl == nil {
		return 0, http.StatusServiceUnavailable, errors.New("control plane is resetting")
	}
	if updated = h.updateNodes(hostname, change); updated == 0 {
		h.mu.Lock()
		if had {
			h.overrides[hostname] = before
		} else {
			delete(h.overrides, hostname)
		}
		h.mu.Unlock()
		return 0, http.StatusNotFound, fmt.Errorf("no node named %s", hostname)
	}
	return updated, http.StatusOK, nil
}

// enforceOverrides runs on every map request, before testcontrol reads it
// (holdMapRequest). Two things, for two reasons.
//
// The request's own Hostinfo is rewritten. testcontrol stores whatever a
// non-streaming map request carries, and a node sends one whenever its
// netinfo or prefs change -- within seconds of joining, as STUN answers
// arrive -- so an OS set once with UpdateNode came back as the real one at
// the node's next re-send, silently. The request is the only place that
// works: the store happens after this hook returns, so a push from here
// would be overwritten by the very request being held.
//
// Then every overridden node's stored entry is compared with what was set,
// and pushed back if it drifted. The owner lives in the entry, which map
// processing never writes (it writes Hostinfo, Endpoints, DiscoKey, Cap and
// HomeDERP), so for it this is belt and braces. For the OS it closes, at
// the next map request from any node, the one window the rewrite leaves: a
// request that passed this hook before /peer-os recorded its override and
// was stored after the push.
//
// Bounded, as holdMapRequest must be: one AllNodes, at most one UpdateNode
// per drifted node, no blocking call, and mu released before either.
func (h *harness) enforceOverrides(gen int, req *tailcfg.MapRequest) {
	h.mu.Lock()
	ctl := h.ctl
	if h.gen != gen || len(h.overrides) == 0 {
		h.mu.Unlock()
		return
	}
	overrides := maps.Clone(h.overrides)
	h.mu.Unlock()
	if req.Hostinfo != nil {
		if ov := overrides[req.Hostinfo.Hostname]; ov.os != "" {
			req.Hostinfo.OS = ov.os
		}
	}
	for _, n := range ctl.AllNodes() { // clones
		ov, ok := overrides[n.Hostinfo.Hostname()]
		if !ok {
			continue
		}
		drifted := false
		if ov.os != "" && n.Hostinfo.OS() != ov.os {
			hi := n.Hostinfo.AsStruct()
			hi.OS = ov.os
			n.Hostinfo = hi.View()
			drifted = true
		}
		if ov.user != 0 && n.User != ov.user {
			n.User = ov.user
			drifted = true
		}
		if drifted {
			ctl.UpdateNode(n)
		}
	}
}
