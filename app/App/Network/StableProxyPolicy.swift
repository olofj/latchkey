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
//    - the MagicDNS suffix, which covers every peer's FQDN by label-wise
//      suffix match.
//  That is still a scoped split tunnel -- nothing public is proxied, which is
//  what upstream's AGENTS.md warns about -- and it changes only if the
//  tailnet's suffix does. Everything else (`hasPeerData`, the exit-node
//  "proxy everything" mode) comes from upstream's policy unchanged.
//

import Foundation
import TailscaleKit

enum StableProxyPolicy {
    static func make(from status: IpnState.Status?, exitNodeEnabled: Bool = false) -> TailnetProxyPolicy {
        let full = TailnetProxyPolicy.make(from: status, exitNodeEnabled: exitNodeEnabled)
        if full.proxiesEverything { return full }
        var rules = [TailnetProxyPolicy.tailscaleIPv4CIDR, TailnetProxyPolicy.tailscaleIPv6CIDR]
        if let suffix = status?.CurrentTailnet?.MagicDNSSuffix {
            let d = TailnetProxyPolicy.normalizeDomain(suffix)
            if !d.isEmpty { rules.append(d) }
        }
        return TailnetProxyPolicy(matchDomains: rules,
                                  hasPeerData: full.hasPeerData,
                                  shortNamesWithheldAsPublicTLD: [])
    }
}
