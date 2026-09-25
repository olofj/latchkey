// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ContentRules.swift
//  Latchkey
//
//  The content rule list that keeps every load the dashboard makes to its
//  gateway, plus four fixed CDN hosts (F6 §4.1, §4.1a).
//
//  `NavigationPolicy` (R3) decides navigations; WebKit never asks it about a
//  subresource. Fonts, scripts, images, fetches, WebSockets and workers are
//  what this list is for. The shape is "block everything, then
//  `ignore-previous-rules` for what is allowed", because the url-filter
//  dialect has no alternation and no "unless" on the resource's own URL:
//  `unless-domain` is a condition on the PAGE's URL (F6 §4.1), so the
//  obvious rule would have blocked nothing.
//
//  Pure Foundation, so scripts/test-content-rules.sh and
//  scripts/test-cdn-allowlist.swift compile it alone. The WebKit half, which
//  compiles and installs the list, is ContentRulesInstaller.swift.
//

import Foundation

nonisolated enum ContentRules {
    /// Bump whenever the template below changes: the compiled list is keyed
    /// by an identifier that carries it (F6 §4.1, "Identifier and caching").
    static let schemaVersion = 1

    /// The four CDN hosts of F6 §4.1a, in this order. Exact hosts, no
    /// wildcards, neither font host: `_BASE_CSP` names these for widget
    /// runtimes (MCP apps import React and Excalidraw from esm.sh), and a
    /// widget is blank without them. Fonts are cosmetic and stay blocked.
    /// **Changing this list changes a promise**: each host sees the phone's
    /// address and that it loads a KiroCrew dashboard. See F6 §4.1a and R41.
    static let allowedCDNHosts = ["esm.sh", "cdn.jsdelivr.net",
                                  "cdnjs.cloudflare.com", "cdn.tailwindcss.com"]

    /// The prefix every identifier this app compiles under shares, so old
    /// ones (another gateway, another schema, the other CDN setting) can be
    /// found and removed.
    static let identifierPrefix = "latchkey.single-origin."

    /// The rules for `origin`, as `GatewayAddress.origin(of:)` renders it
    /// (lowercase, default port dropped), or nil if it is not http(s). Ten
    /// rules when `allowCDNs`, six when not.
    static func json(forOrigin origin: String, allowCDNs: Bool) -> String? {
        guard let parts = split(origin) else { return nil }
        let wsScheme = parts.scheme == "https" ? "wss" : "ws"
        let authority = urlFilterEscaped(parts.authority)
        var rules: [String] = []
        // 1. Block every load of every type. No resource-type, so a type
        //    WebKit adds later is blocked too: the list fails closed.
        rules.append(rule(".*", action: "block"))
        // The CDN allowlist (§4.1a). `https://` literal, so plaintext is not
        // admitted; the trailing `/` is what stops `esm.sh.evil.example` and
        // `esm.sh:8444` from matching. It is the most important character here.
        if allowCDNs {
            for host in allowedCDNHosts {
                rules.append(rule("^https://\(urlFilterEscaped(host))/", action: "ignore-previous-rules"))
            }
        }
        // 2. Top documents and popups belong to NavigationPolicy (R3): a
        //    main-frame redirect blocked here would fail with WebKitErrorDomain
        //    104 before the navigation delegate is asked, and window.open would
        //    return null before createWebViewWith runs.
        rules.append(#"{"trigger":{"url-filter":".*","resource-type":["top-document","popup"]},"action":{"type":"ignore-previous-rules"}}"#)
        // 3. The origin exactly: scheme, host, port, then `/`.
        rules.append(rule("^\(parts.scheme)://\(authority)/", action: "ignore-previous-rules"))
        // 4. The dashboard's WebSockets, on the same authority.
        rules.append(rule("^\(wsScheme)://\(authority)/", action: "ignore-previous-rules"))
        // 5. blob: workers and object URLs; a blob carries its creator's origin.
        rules.append(rule("^blob:", action: "ignore-previous-rules"))
        // 6. about:srcdoc widget frames (and about:blank, for a clean reading).
        rules.append(rule("^about:", action: "ignore-previous-rules"))
        return "[" + rules.joined(separator: ",") + "]"
    }

    /// `latchkey.single-origin.v1.cdn1.<origin>`. The CDN flag is part of the
    /// identity: the in-process cache and WebKit's store both key by it, and
    /// without it flipping the toggle would hand back the list compiled for
    /// the other setting.
    static func identifier(forOrigin origin: String, allowCDNs: Bool) -> String {
        "\(identifierPrefix)v\(schemaVersion).cdn\(allowCDNs ? 1 : 0).\(origin)"
    }

    /// The escape table WebKit uses for `if-domain` (`getDomainList`):
    /// `\ { } [ . ? * $`. Enough here because `split` admits only host,
    /// IPv6 and port characters.
    /// `/`, `:` and `-` stay literal; a bracketed IPv6 host escapes its `[`,
    /// and `]` alone is literal in this dialect.
    static func urlFilterEscaped(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\{}[.?*$".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// The payload the `-UITestBreakContentRules` hook hands the real
    /// compiler: an unknown action, so the failure path is WebKit's own.
    static let brokenJSON = #"[{"trigger":{"url-filter":".*"},"action":{"type":"no-such-action"}}]"#

    private static func rule(_ filter: String, action: String) -> String {
        // JSON-escape the filter: every backslash doubles.
        let escaped = filter.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"trigger":{"url-filter":""# + escaped + #""},"action":{"type":""# + action + #""}}"#
    }

    /// Scheme and `host[:port]` of an http(s) origin with nothing after it.
    private static func split(_ origin: String) -> (scheme: String, authority: String)? {
        for scheme in ["https", "http"] {
            let prefix = scheme + "://"
            if origin.hasPrefix(prefix) {
                let authority = String(origin.dropFirst(prefix.count))
                // Host names, IPv6 literals and a port only. Anything else
                // (`+`, `(`, `|`, …) is a regex operator in this dialect and
                // would widen the rule past the origin; such an origin gets
                // no rules, and the compile of the fallback fails closed.
                let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-:[]")
                guard !authority.isEmpty, authority.allSatisfy({ allowed.contains($0) }) else { return nil }
                return (scheme, authority)
            }
        }
        return nil
    }
}
