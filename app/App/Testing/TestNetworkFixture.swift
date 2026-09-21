// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  TestNetworkFixture.swift
//  Latchkey
//
//  The offline harness's way in (revision R11, finding H4; milestone M2).
//
//  An override that only swaps the proxy endpoint never loads anything:
//  `BrowserViewModel.loadInitial()` waits for the node to be `.Running` and for
//  a status with the gateway as a peer, and `TailnetProxyPolicy.make(from:
//  nil)` yields IP ranges only — so a MagicDNS name would go direct. The easy
//  workaround, proxying everything, tests the one configuration production
//  never ships.
//
//  So instead of a node, a test supplies what a node would have produced:
//
//    -TestStatusFixture   <IpnState.Status as JSON>   (MagicDNS suffix + peers)
//    -TestProxyEndpoint   127.0.0.1:1080              (the stub SOCKS5 proxy)
//    -TestProxyCredential s3cret                      (its password)
//
//  `TSNetManager` then starts no tsnet node, sets `.Running` and the fixture
//  status, and publishes the proxy configuration through its normal
//  `proxyConfig` → `ProxyConfigurationFactory` → `TailnetProxyPolicy` path,
//  logging relay included. Everything above the model — `loadInitial`,
//  `HomePageAvailability`, `hasPeerData`, `resolveForTailnet`, the navigation
//  policy, the data store's proxy — is the production code, unmodified.
//
//  Test builds only (R15). Fixture addresses are never dialled: WebKit reaches
//  the gateway by name through the proxy, and the stub maps that name to a
//  local listener. Never put a real tailnet name or address in a fixture (R10)
//  — on a machine running Tailscale those route through the host's own VPN,
//  and a leak would succeed instead of failing.
//

#if LATCHKEY_TEST_HOOKS
import Foundation
import TailscaleKit

struct TestNetworkFixture {
    let status: IpnState.Status
    let proxyHost: String
    let proxyPort: Int
    let credential: String

    /// The fixture from launch arguments, or nil when not requested. A
    /// requested but malformed fixture is a fatal error: silently starting a
    /// real node instead would let a test pass for the wrong reason.
    static func fromLaunchArguments() -> TestNetworkFixture? {
        guard let json = TestHooks.value("-TestStatusFixture") else { return nil }
        guard let data = json.data(using: .utf8) else {
            fatalError("-TestStatusFixture is not UTF-8")
        }
        let status: IpnState.Status
        do {
            status = try JSONDecoder().decode(IpnState.Status.self, from: data)
        } catch {
            fatalError("-TestStatusFixture does not decode as IpnState.Status: \(error)")
        }
        guard let endpoint = TestHooks.value("-TestProxyEndpoint"),
              let colon = endpoint.lastIndex(of: ":"),
              let port = Int(endpoint[endpoint.index(after: colon)...]),
              !endpoint[..<colon].isEmpty
        else {
            fatalError("-TestStatusFixture needs -TestProxyEndpoint host:port")
        }
        guard let credential = TestHooks.value("-TestProxyCredential") else {
            fatalError("-TestStatusFixture needs -TestProxyCredential")
        }
        let host = String(endpoint[..<colon])
        if Self.mentionsRealTailnet(json) || host.hasSuffix(".ts.net") {
            // R10: a real tailnet name in a test is how a leak turns into a
            // pass. The fixture tailnet is tail-scale.ts.net; nothing else.
            fatalError("test fixture references a real tailnet; use tail-scale.ts.net names only")
        }
        return TestNetworkFixture(status: status, proxyHost: host, proxyPort: port,
                                  credential: credential)
    }

    /// Olof's tailnet. The fixture tailnet is `tail-scale.ts.net`.
    private static func mentionsRealTailnet(_ json: String) -> Bool {
        json.range(of: "example", options: .caseInsensitive) != nil
    }
}
#endif
