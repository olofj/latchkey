// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  DashboardSignOut.swift
//  Latchkey
//
//  What "Sign out of the dashboard" (revision R32) means, as data: how the
//  gateway's answer to `POST /api/auth/logout` is read, and what the user is
//  told afterwards. Pure, so scripts/test-signout.sh checks it on the host.
//  The sequence itself -- ask the page, wipe the web data, reload -- is
//  `Workspace.signOutOfDashboard`.
//
//  The logout is asked for from the PAGE, in the app's content world, never
//  with URLSession: the gateway's CSRF check wants the page's own Origin, and
//  the refresh cookie (Path=/api/auth, HttpOnly) is the page's to send. Only
//  then does the gateway revoke the chain and denylist the access session
//  (auth_refresh.py:760-820 in 0.6.0). Local data is cleared whatever the
//  gateway said: a sign-out must work with the gateway down, and the user is
//  told when that is all it could do.
//

import Foundation

enum DashboardSignOut {
    enum Outcome: Equatable {
        /// The gateway answered 200: its refresh chain is revoked and the
        /// access session denylisted there, and the cookies are gone here.
        case endedAtGateway
        /// The cookies are gone here, but the gateway did not confirm: nil
        /// when it did not answer at all (unreachable, no page, timed out),
        /// otherwise the status it gave instead of 200. The session it holds
        /// runs on until it expires.
        case endedLocally(gatewayStatus: Int?)
    }

    /// How long the page-world logout may take before local data is cleared
    /// anyway: long enough for a slow relay, short enough that a gateway
    /// that is down does not look like a hang.
    nonisolated static let requestTimeout: Duration = .seconds(10)

    nonisolated static func outcome(logoutStatus: Int?) -> Outcome {
        logoutStatus == 200 ? .endedAtGateway : .endedLocally(gatewayStatus: logoutStatus)
    }

    /// What the sign-in sheet says afterwards; nothing when the gateway
    /// confirmed, since the sheet's own text already covers a normal
    /// sign-out.
    nonisolated static func notice(for outcome: Outcome) -> String? {
        switch outcome {
        case .endedAtGateway:
            return nil
        case .endedLocally(nil):
            return "Signed out on this device only: the gateway couldn't be reached, so it still holds this session until it expires (up to 30 days)."
        case .endedLocally(let status?):
            return "Signed out on this device only: the gateway answered \(status) instead of ending the session, so it still holds it until it expires (up to 30 days)."
        }
    }
}
