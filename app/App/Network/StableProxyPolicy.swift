// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  StableProxyPolicy.swift
//  Latchkey
//
//  The split-tunnel rules Latchkey actually publishes (revision R27).
//
//  Upstream's `TailnetProxyPolicy.make(from:)` lists every peer's MagicDNS
//  name and short hostname, so any device joining, leaving or being renamed
//  anywhere in the tailnet changes the rule set -- and a changed rule set is
//  republished into WebKit's data store under the live dashboard, where
//  WebKit may rebuild its sessions.
//
//  Latchkey loads one gateway by its FQDN (bare names are rewritten to the
//  FQDN before any load, `BrowserViewModel.resolveForTailnet`), so it needs
//  only:
//    - the two tailnet address ranges (100.64.0.0/10, fd7a:115c:a1e0::/48),
//    - the MagicDNS suffix, which covers every OWN peer's FQDN by label-wise
//      suffix match,
//    - the FQDN of each peer NOT under that suffix: nodes shared in from
//      another tailnet keep their own tailnet's name (tailcfg.go:562-584).
//      Upstream listed them; leaving them out sent them direct (M5 review).
//      That list changes only when a share does, not with ordinary churn.
//  That is still a scoped split tunnel -- nothing public is proxied, which is
//  what upstream's AGENTS.md warns about. With no suffix known yet, upstream's
//  own policy is used unchanged. `hasPeerData` and the exit-node "proxy
//  everything" mode always come from upstream's policy.
//

import Foundation
import TailscaleKit

enum StableProxyPolicy {
    static func make(from status: IpnState.Status?, exitNodeEnabled: Bool = false) -> TailnetProxyPolicy {
        let full = TailnetProxyPolicy.make(from: status, exitNodeEnabled: exitNodeEnabled)
        if full.proxiesEverything { return full }
        let suffix = TailnetProxyPolicy.normalizeDomain(status?.CurrentTailnet?.MagicDNSSuffix ?? "")
        // No suffix: nothing to be stable about yet. Upstream's list is the
        // only way names reach the proxy (M5 review).
        guard !suffix.isEmpty else { return full }
        let ipRules = [TailnetProxyPolicy.tailscaleIPv4CIDR, TailnetProxyPolicy.tailscaleIPv6CIDR]
        var outside = Set<String>()
        var peers = Array(status?.Peer?.values ?? [:].values)
        if let me = status?.SelfStatus { peers.append(me) }
        for peer in peers {
            let fqdn = TailnetProxyPolicy.normalizeDomain(peer.DNSName)
            guard fqdn.contains("."), fqdn != suffix, !fqdn.hasSuffix("." + suffix) else { continue }
            outside.insert(fqdn)
        }
        return TailnetProxyPolicy(matchDomains: ipRules + [suffix] + outside.sorted(),
                                  hasPeerData: full.hasPeerData,
                                  shortNamesWithheldAsPublicTLD: [])
    }
}
