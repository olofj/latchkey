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

    /// The id of the `<style>` element `sessionBridge` adds.
    static let bannerStyleID = "latchkey-session-banner-hidden"

    /// The session bridge (M4.2, R21, R22). Runs in the app's own content
    /// world, main frame only, at document start — so it is re-injected on
    /// every navigation, including the `location.assign('/')` KiroCrew does
    /// when a refresh chain is revoked, after which `mc-auth-required` fires.
    ///
    /// Three jobs:
    ///  1. Forward KiroCrew's `mc-auth-required` / `mc-auth-cleared` window
    ///     events to native. DOM events reach listeners in every content
    ///     world; the message handler exists only in the app's world, so the
    ///     page (or anything it loads from a CDN) cannot post to it.
    ///  2. Hide the page's own `#mc-session-expired` banner with CSS ONLY
    ///     (R22): the native sheet replaces it. Never remove the element or
    ///     click its ✕ — a startup gate reads it, and ✕ clears the client's
    ///     latches. `display:none` also keeps its input from autofocusing and
    ///     popping the keyboard.
    ///  3. Say `ready`. If native does not hear it, it removes the style again
    ///     (`revealSessionBanner`), so a broken bridge leaves the page's own
    ///     banner as the way to sign in. With no message handler at all the
    ///     style is never added in the first place.
    static let sessionBridge = #"""
    (function () {
      var handlers = window.webkit && window.webkit.messageHandlers;
      var handler = handlers && handlers.kiroSession;
      if (!handler) { return; }
      function post(event) {
        try { handler.postMessage({ event: event }); } catch (e) {}
      }
      try {
        var style = document.createElement('style');
        style.id = 'latchkey-session-banner-hidden';
        style.textContent = '#mc-session-expired{display:none!important}';
        (document.head || document.documentElement).appendChild(style);
      } catch (e) {}
      window.addEventListener('mc-auth-required', function () { post('auth-required'); });
      window.addEventListener('mc-auth-cleared', function () { post('auth-cleared'); });
      post('ready');
    })();
    """#

    /// Undoes `sessionBridge`'s banner hiding: the handshake's fallback (R22).
    static let revealSessionBanner = #"""
    (function () {
      var s = document.getElementById('latchkey-session-banner-hidden');
      if (s) { s.remove(); }
    })();
    """#

    /// The body of the async function the app runs in its own content world
    /// to ask the gateway something AS THE PAGE: M4's `/api/auth/me` check,
    /// and R32's `POST /api/auth/logout`. Arguments `path`, `method` and
    /// `timeoutMs` (0: none). Returns the HTTP status.
    ///
    /// Why the page and not URLSession: the request must carry the page's
    /// cookies (HttpOnly; the refresh cookie is scoped to /api/auth) and its
    /// Origin, which the gateway's CSRF check compares. `same-origin`
    /// credentials is the contract -- `omit` would make the logout a no-op
    /// that still answers 200. The header only marks the app's own requests,
    /// so the test gateway can tell them from the page's identical calls;
    /// servers ignore it. The abort is what keeps a sign-out from hanging on
    /// a gateway that is down.
    static let sessionFetch = #"""
    const controller = new AbortController();
    const timer = timeoutMs > 0 ? setTimeout(function () { controller.abort(); }, timeoutMs) : null;
    try {
      const r = await fetch(path, {method: method, credentials: 'same-origin', cache: 'no-store',
                                   headers: {'X-Latchkey-Check': '1'}, signal: controller.signal});
      return r.status;
    } finally {
      if (timer !== null) { clearTimeout(timer); }
    }
    """#
}
