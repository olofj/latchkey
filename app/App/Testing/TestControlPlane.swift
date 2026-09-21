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
        guard let raw = TestHooks.value("-TestControlURL") else { return nil }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), isLoopback(host)
        else {
            fatalError("-TestControlURL must be an http(s) URL on loopback (127.0.0.1, ::1, localhost); got \(raw)")
        }
        return raw
#else
        return nil
#endif
    }

    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h == "::1" { return true }
        let octets = h.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { UInt8($0) != nil }
    }
}
