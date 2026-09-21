// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ProxyConfigurationFactory.swift
//  Latchkey
//
//  Builds the `ProxyConfiguration` WebKit uses to reach the tailnet
//  (revision R12, finding H3).
//
//  This used to be inline in `TSNetManager.proxyConfig`, interleaved with
//  starting the logging relay, so nothing could test it. The consequence was
//  that the L0 "allowFailover == false" check could only assert Apple's
//  default, not the object the app actually hands to WebKit. Now the pure part
//  lives here and `scripts/test-proxy-config.sh` checks the app's own objects.
//
//  Two properties matter and are enforced here, not left to defaults:
//
//  - `allowFailover = false`. With failover allowed, Network.framework may
//    fall back to a direct connection when the proxy is unreachable — a dead
//    proxy would quietly leak the request instead of failing it. False is
//    the framework default today (`proxy_config.h`); it is set explicitly so
//    a future default change cannot flip it, and so the test pins the app's
//    decision rather than Apple's.
//  - `matchDomains` comes straight from `TailnetProxyPolicy`: the split
//    tunnel. An empty list means "proxy everything" to the OS, which is what
//    the policy returns only in proxy-everything mode (a test hook, R4/R15).
//
//  ⚠️ `ProxyConfiguration` is a struct with REFERENCE semantics underneath:
//  it wraps a shared `nw_proxy_config`, and its `mutating` setters write
//  through to that shared object with no copy-on-write. So
//
//      var copy = installed      // looks like a copy
//      copy.matchDomains = …     // also changes `installed`
//
//  Verified on the iOS 27 / macOS 26 SDK; pinned by test-proxy-config.sh.
//  Upstream's `refreshProxyPolicyIfNeeded` did exactly that, rewriting the
//  object already installed in WebKit's data store in place before
//  announcing the change. So this factory only ever builds a FRESH object,
//  and callers rescope by building again from the endpoint inputs — never by
//  copying and editing a configuration that has been handed out.
//

import Foundation
import Network

enum ProxyConfigurationFactory {
    /// tsnet's SOCKS5 username. The password is the per-launch 128-bit
    /// credential tsnet generates (`LoopbackConfig.proxyCredential`).
    static let socksUsername = "tsnet"

    /// A new SOCKS5 proxy configuration for `proxyHost:proxyPort`, scoped by
    /// `policy`. Always a fresh object (see the file comment). Nil for a port
    /// that cannot be a TCP port.
    static func make(proxyHost: String, proxyPort: Int, credential: String,
                     policy: TailnetProxyPolicy) -> ProxyConfiguration? {
        guard let port16 = UInt16(exactly: proxyPort), port16 > 0,
              let port = NWEndpoint.Port(rawValue: port16)
        else { return nil }
        var config = ProxyConfiguration(
            socksv5Proxy: .hostPort(host: NWEndpoint.Host(proxyHost), port: port))
        config.applyCredential(username: socksUsername, password: credential)
        config.matchDomains = policy.matchDomains
        config.allowFailover = false
        return config
    }
}
