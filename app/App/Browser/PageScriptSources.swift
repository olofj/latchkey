// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  PageScriptSources.swift
//  Latchkey
//
//  JavaScript the app injects into the dashboard, as source text only.
//
//  Kept apart from the `WKUserScript` construction (PageScripts.swift) and
//  free of WebKit, so `scripts/test-page-scripts.sh` can compile this file on
//  the host, print a script, and run it under Node against a fake `location`
//  and `history`. The test exercises the exact text the app injects.
//

import Foundation

enum PageScriptSources {
    /// Removes `token` from the address at document start (revision R2).
    ///
    /// A sign-in link is `https://<gateway>/?token=…`. By the time any script
    /// on that page runs, the token has already done its job: KiroCrew's auth
    /// middleware serves the page and sets the session and refresh cookies on
    /// that same response (`dashboard/token_auth.py:2891-3037` in 0.6.0).
    /// Leaving it in the address keeps a credential that is re-redeemable for
    /// 300 s in the back-forward list and in anything that reads the URL.
    ///
    /// Why document start, before the page's own scripts:
    ///  - React Router snapshots the location when it initialises. Rewriting
    ///    the URL after that leaves the router believing the query still holds
    ///    the token, and its next `setSearchParams` would write it back.
    ///  - It turns every sign-in load into the ordinary cookie-authenticated
    ///    load the app makes on every cold start, which is the most exercised
    ///    path the dashboard has.
    ///
    /// Cost, accepted: KiroCrew 0.6.0 reads `?token=` for one optional
    /// feature — a token carrying a `prompt` claim prefills the chat
    /// (`App-*.js`, the effect that calls its `YA()` decoder). Sign-in links
    /// minted by `kirocrew token` or the phone-access QR carry no prompt, so
    /// nothing is lost for them.
    ///
    /// Other parameters and the fragment are preserved; only `token` goes.
    /// `history.state` is passed through so the router's own state survives.
    static let stripSignInToken = #"""
    (function () {
      try {
        var params = new URLSearchParams(window.location.search);
        if (!params.has('token')) { return; }
        params.delete('token');
        var rest = params.toString();
        var clean = window.location.pathname + (rest ? '?' + rest : '') + window.location.hash;
        window.history.replaceState(window.history.state, '', clean);
      } catch (e) {
        // Never break the page over this. The token then stays in the
        // address, which is exactly the pre-R2 behaviour.
      }
    })();
    """#
}
