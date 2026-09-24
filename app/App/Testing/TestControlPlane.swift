// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  TestControlPlane.swift
//  Latchkey
//
//  L2's way in (PLAN M3, revision R17).
//
//    -TestControlURL http://127.0.0.1:8490
//
//  points the real tsnet node at the host-side fake control plane
//  (testing/tsnet-harness in the parent repo). Unlike L1's status fixture,
//  nothing is faked in the app: the node logs in, receives its netmap and
//  MagicDNS config, and serves the loopback SOCKS5 proxy WebKit uses.
//
//  The override lives only in the launch's `Configuration`, like the auth
//  key; the workspace definition on disk keeps the real control URL, so a
//  later launch without the argument is back on the real control plane.
//
//  Test builds only (R15). Loopback only: the harness runs on the host, which
//  the simulator shares, and nothing else may stand in for the control plane.
//

import Foundation

enum TestControlPlane {
    /// The control URL for this launch, or nil for the workspace's own. A
    /// requested but unacceptable URL is a fatal error: falling back to the
    /// real control plane would send a test node to Tailscale.
    static func controlURLOverride() -> String? {
#if LATCHKEY_TEST_HOOKS
        guard let raw = TestHooks.value("-TestControlURL") else {
            // Named but unusable (empty, last on the line, or `-X=value`):
            // the same fall-back to the real control plane (M3 review).
            if TestHooks.anyArgument(hasPrefix: "-TestControlURL") {
                fatalError("-TestControlURL needs a value: -TestControlURL http://127.0.0.1:8490")
            }
            return nil
        }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), isLoopback(host)
        else {
            fatalError("-TestControlURL must be an http(s) URL on 127.0.0.1, [::1] or localhost; got \(raw)")
        }
        return raw
#else
        return nil
#endif
    }

    /// An exact allowlist, not a parser. Spellings Swift accepts as numbers
    /// but Go does not parse as an address (`127.0.0.01`, `127.+0.0.1`) would
    /// send the node to DNS and then to Tailscale's own resolvers (M3 review).
    static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "::1", "[::1]", "localhost"].contains(host.lowercased())
    }
}
