// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  GatewayAddress.swift
//  Latchkey
//
//  What the app is allowed to remember about where the gateway is: its origin,
//  and nothing that could carry a credential (revision R2).
//
//  A KiroCrew sign-in URL is `https://<gateway>/?token=…`, and the obvious
//  thing for a person to do with one is paste it into the gateway field. That
//  field is persisted to `workspaces.json` on every keystroke, so without this
//  a live token would be written to disk the moment it was pasted. The rule
//  is: nothing after `?` or `#` is ever stored, and a committed address is
//  reduced to `scheme://host[:port]`.
//
//  Pure Foundation, so `scripts/test-gateway-address.sh` compiles it alone.
//

import Foundation

enum GatewayAddress {
    /// Cuts `raw` at its first `?` or `#`. Safe on partial input — this runs
    /// on every keystroke, where the text is usually not a URL yet.
    nonisolated static func stripParameters(_ raw: String) -> String {
        guard let cut = raw.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return raw }
        return String(raw[..<cut])
    }

    /// `scheme://host[:port]` for an http(s) URL string, or nil if `raw` has
    /// no http(s) scheme and host. Scheme and host are lowercased; a default
    /// port (80 for http, 443 for https) is dropped so equal origins compare
    /// equal as strings.
    nonisolated static func origin(of raw: String) -> String? {
        guard let components = URLComponents(string: stripParameters(raw)),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        var out = "\(scheme)://\(host)"
        if let port = components.port,
           !(scheme == "http" && port == 80), !(scheme == "https" && port == 443) {
            out += ":\(port)"
        }
        return out
    }

    /// The value to persist for a committed gateway entry: its origin when it
    /// is a URL, otherwise the text with any parameters cut off.
    nonisolated static func persistable(_ raw: String) -> String {
        origin(of: raw) ?? stripParameters(raw)
    }
}
