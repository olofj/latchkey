// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  TailnetLogout.swift
//  Latchkey
//
//  Logging the node out of the tailnet (revision R32): LocalAPI `POST
//  /logout`, which is `LocalBackend.Logout`. The node key is EXPIRED AT THE
//  CONTROL PLANE first (`controlclient.TryLogout` re-registers it with an
//  expiry in the far past), then the profile is deleted locally. Upstream's
//  Settings logout was `LocalBackend.DeleteProfile` (removed in R32; it was
//  `StatusViewModel.logout`), which only forgets the profile and never
//  contacts control: control keeps a node with a valid key, and every
//  reinstall added one more. That is the orphan R32 is about.
//
//  TailscaleKit's own `LocalAPIClient.logout()` is not public, and a vendored
//  change needs a framework rebuild and its own commit (AGENTS.md). The
//  request is built here instead, exactly as TailscaleKit builds its others,
//  and kept pure so scripts/test-signout.sh can hold it to that.
//
//  A failed logout does NOT let the caller delete the node's local state
//  (R32 review): that would make the orphan permanent, since the key that
//  could still be expired is in that state. The user chooses -- retry, or
//  delete anyway with the cost spelled out (`failureMessage`).
//

import Foundation

enum TailnetLogout {
    enum Outcome: Equatable {
        /// Control expired the key and the node forgot its profile.
        case loggedOut
        /// LocalAPI answered as for a logout, but the node had no valid key
        /// to expire (at NeedsLogin: never logged in, or its key already
        /// expired), so there was nothing at control to orphan. `serveLogout`
        /// answers 204 in both cases; the node's state before the call tells
        /// them apart.
        case noKey
        /// Nothing to log out: a test fixture, or a node that never started.
        case noNode
        /// Logged; the node keeps its valid key at control, and its state
        /// here must be kept too, or the key can never be expired from here.
        case failed(String)
    }

    /// Long enough for control to answer over a slow link. Cancelling the
    /// request after this cancels tsnet's side too (the handler runs on the
    /// request's context), so a reset never waits longer than this.
    nonisolated static let timeout: TimeInterval = 20

    /// The request, as `LocalAPIClient.basicAuthURLRequest` makes its
    /// others: plain HTTP to the loopback, `tsnet:<key>` as Basic auth and
    /// the `Sec-Tailscale: localapi` header the loopback insists on.
    nonisolated static func request(ip: String, port: Int, localAPIKey: String,
                                    timeout: TimeInterval = TailnetLogout.timeout) -> URLRequest? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = ip
        components.port = port
        components.path = "/localapi/v0/logout"
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        let credential = Data("tsnet:\(localAPIKey)".utf8).base64EncodedString()
        request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
        return request
    }

    /// `serveLogout` answers 204 when `LocalBackend.Logout` returned nil,
    /// which includes a node with no key to begin with.
    nonisolated static func succeeded(status: Int) -> Bool {
        (200..<300).contains(status)
    }

    /// Reads LocalAPI's answer. `hadKey` is whether the node held a key
    /// control could expire when the request was made -- a 2xx does not say.
    nonisolated static func outcome(status: Int, hadKey: Bool) -> Outcome {
        guard succeeded(status: status) else { return .failed("LocalAPI answered \(status)") }
        return hadKey ? .loggedOut : .noKey
    }

    /// The alert a reset shows when control could not be asked (R32 review).
    nonisolated static let failureTitle = "Couldn't reach Tailscale to log this node out"

    /// Its message: what "Delete anyway" costs, in the admin console's terms.
    nonisolated static func failureMessage(_ reason: String) -> String {
        "The node's key was not expired (\(reason)). If you delete anyway, this node stays in the Tailscale admin console with a valid key until it expires or an admin removes it there. Cancel keeps the node; you are signed out of the dashboard either way."
    }
}
