// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  FixtureTailnetCheck.swift
//  Latchkey
//
//  "Does this test fixture name a tailnet it should not?" — the pure half of
//  TestNetworkFixture's R10 guard, split out so `scripts/test-fixture-tailnets.sh`
//  can compile it on the host. TestNetworkFixture itself imports TailscaleKit
//  and cannot be host-compiled.
//
//  Why this exists at all: a real tailnet name in a test is how a leak turns
//  into a pass. On a Mac running Tailscale, a real `*.ts.net` name resolves and
//  routes through the host's own VPN, so a test meant to prove "this connection
//  is refused" instead proves nothing — it succeeded.
//
//  It is an ALLOW-LIST on purpose. Until 2026-09-23 this check named one real
//  tailnet — the author's — which protected exactly one person: anyone else's
//  real tailnet passed a check that looked like it was checking.
//

#if LATCHKEY_TEST_HOOKS
import Foundation

enum FixtureTailnets {
    /// The only tailnets a fixture may name. `tail-scale.ts.net` is the
    /// harnesses'; `example.ts.net` is for illustrative strings.
    static let allowed: Set<String> = ["tail-scale.ts.net", "example.ts.net"]

    /// Characters legal in a DNS label, for finding where a hostname starts.
    private static let labelCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")

    /// The first `*.ts.net` tailnet in `text` that is not in `allowed`, or nil.
    ///
    /// The tailnet is the label immediately before `.ts.net`, found by walking
    /// **back over label characters only**. That bound is the whole trick and
    /// the reason this has a test: `text` is a JSON document, not a hostname.
    /// Splitting it on "." to find the label reads back across quotes, colons
    /// and braces whenever the preceding JSON happens to contain no dot — which
    /// made every legitimate fixture look foreign and crashed the app on launch
    /// in three suites before it was caught.
    static func foreign(in text: String) -> String? {
        let lower = text.lowercased()
        var searchFrom = lower.startIndex
        while let hit = lower.range(of: ".ts.net", range: searchFrom..<lower.endIndex) {
            var start = hit.lowerBound
            while start > lower.startIndex {
                let previous = lower.index(before: start)
                guard labelCharacters.contains(lower[previous]) else { break }
                start = previous
            }
            let label = String(lower[start..<hit.lowerBound])
            if !label.isEmpty {
                let tailnet = "\(label).ts.net"
                if !allowed.contains(tailnet) { return tailnet }
            }
            searchFrom = hit.upperBound
        }
        return nil
    }
}
#endif
