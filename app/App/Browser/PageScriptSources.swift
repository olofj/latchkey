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
    /// servers ignore it. The abort is what keeps a check or a sign-out from
    /// hanging on a gateway that is down, or on a connection that is open
    /// and answers nothing; every caller in the app passes a timeout
    /// (`SessionManager.checkTimeout`, `DashboardSignOut.requestTimeout`).
    /// 0 still means none, for the contract's sake, but nothing sends it.
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

    /// The name `pageBackground` posts to. Registered in the app's own
    /// content world only, like the session bridge's.
    static let pageBackgroundHandler = "latchkeyPageBackground"

    /// Reports the page's canvas colour (F9 §0.1 step 2): the strip above the
    /// web view is tinted with it, so page and strip read as one surface.
    ///
    /// Why not `WKWebView.themeColor`: KiroCrew 0.7.0 declares a fixed
    /// `theme-color` of `#0d0f12` and switches between twenty-odd dark AND
    /// light themes at runtime by `data-theme`, so the meta tag would paint a
    /// near-black bar above a light page. Why not `underPageBackgroundColor`:
    /// `RawWebView` overrides it to stop the pre-paint flash, and the getter
    /// then returns the override, not the page.
    ///
    /// The canvas takes `<html>`'s background, else `<body>`'s (CSS
    /// Backgrounds §2.11.2), which is what this reads. It posts the computed
    /// value — `rgb(…)`/`rgba(…)`, or `''` when the page paints nothing — on
    /// load, on attribute changes to `<html>`/`<body>` (a theme switch), on
    /// stylesheet insertion, on a colour-scheme change and after a background
    /// transition ends, coalesced to one read per frame and only on change.
    static let pageBackground = #"""
    (function () {
      var handlers = window.webkit && window.webkit.messageHandlers;
      var handler = handlers && handlers.latchkeyPageBackground;
      if (!handler) { return; }
      var last = null, pending = false;
      function clear(c) { return !c || c === 'transparent' || /^rgba\(.*,\s*0\)$/.test(c); }
      function read() {
        pending = false;
        var c = '';
        try {
          var d = document.documentElement, b = document.body;
          c = d ? getComputedStyle(d).backgroundColor : '';
          if (clear(c)) { c = b ? getComputedStyle(b).backgroundColor : ''; }
          if (clear(c)) { c = ''; }
        } catch (e) { c = ''; }
        if (c === last) { return; }
        last = c;
        try { handler.postMessage(c); } catch (e) {}
      }
      function schedule() {
        if (pending) { return; }
        pending = true;
        requestAnimationFrame(read);
      }
      var observer = new MutationObserver(function () {
        if (document.head) { observer.observe(document.head, {childList: true}); }
        if (document.body) { observer.observe(document.body, {attributes: true}); }
        schedule();
      });
      observer.observe(document.documentElement, {attributes: true, childList: true});
      document.addEventListener('DOMContentLoaded', schedule);
      window.addEventListener('load', schedule);
      document.addEventListener('transitionend', schedule, true);
      try { matchMedia('(prefers-color-scheme: dark)').addEventListener('change', schedule); } catch (e) {}
      schedule();
    })();
    """#

    /// The name `appBarObserver` posts to, in the app's own content world.
    static let appBarHandler = "latchkeyAppBar"

    /// Reports the finger's travel to the app bar (F15 §4a).
    ///
    /// Why a page script and not the web view's `UIScrollView`: KiroCrew
    /// 0.7.0's shell is `h-dvh` with `overflow-hidden` and inner scrollers,
    /// so the document never scrolls and the scroll view never moves. Only an
    /// element inside the page does, and WebKit reports that only to the page.
    ///
    /// It observes and never takes part. Every listener is `passive` (it
    /// cannot call `preventDefault`, so it cannot stop a scroll) and on
    /// `window` in the capture phase, which sees a scroll of ANY element
    /// without reading the page's markup (F15 §3). It lives in the app's
    /// content world, invisible to the page.
    ///
    /// Posts `{p: 's'|'m'|'e', dx, dy, r}`: a touch-down, a move coalesced to
    /// one per frame, a lift. dx/dy are screen points. `r` is the largest
    /// vertical scroll range of anything that scrolled during the touch — 0
    /// when nothing did, which is how a page too short to scroll is told
    /// apart from one that scrolls. A change of viewport size (the bar itself
    /// retracting) re-bases the finger instead of counting as travel.
    static let appBarObserver = #"""
    (function () {
      var handlers = window.webkit && window.webkit.messageHandlers;
      var handler = handlers && handlers.latchkeyAppBar;
      if (!handler) { return; }
      var opts = {capture: true, passive: true};
      var active = false, pending = false, x = 0, y = 0, w = 0, h = 0, dx = 0, dy = 0, range = 0;
      function scale() { return window.visualViewport ? window.visualViewport.scale : 1; }
      function send(p) {
        try { handler.postMessage({p: p, dx: dx, dy: dy, r: range}); } catch (e) {}
        dx = 0; dy = 0;
      }
      function flush() { pending = false; if (active && (dx || dy)) { send('m'); } }
      function base(t) { x = t.clientX; y = t.clientY; w = window.innerWidth; h = window.innerHeight; }
      function end() {
        if (!active) { return; }
        if (dx || dy) { send('m'); }
        active = false;
        send('e');
      }
      window.addEventListener('touchstart', function (e) {
        if (e.touches.length !== 1) { end(); return; }
        active = true; dx = 0; dy = 0; range = 0;
        base(e.touches[0]);
        send('s');
      }, opts);
      window.addEventListener('touchmove', function (e) {
        if (!active) { return; }
        if (e.touches.length !== 1) { end(); return; }
        var t = e.touches[0];
        if (window.innerWidth !== w || window.innerHeight !== h) { base(t); return; }
        var k = scale();
        dx += (t.clientX - x) * k; dy += (t.clientY - y) * k;
        x = t.clientX; y = t.clientY;
        if (!pending) { pending = true; requestAnimationFrame(flush); }
      }, opts);
      window.addEventListener('touchend', end, opts);
      window.addEventListener('touchcancel', end, opts);
      window.addEventListener('scroll', function (e) {
        if (!active) { return; }
        var el = (e.target === document || e.target === window) ? document.scrollingElement : e.target;
        if (!el || typeof el.scrollHeight !== 'number') { return; }
        var r = (el.scrollHeight - el.clientHeight) * scale();
        if (r > range) { range = r; }
      }, opts);
    })();
    """#

    /// Parses what `pageBackground` posts into sRGB components in 0…1.
    /// `nil` for anything else — an empty report, `color(…)`, `oklch(…)` —
    /// and for a colour that is not fully opaque: the strip would then show
    /// the app's background through it and match nothing. The caller falls
    /// back to the system background, which is the web view's own before
    /// the first paint.
    nonisolated static func opaqueRGB(fromCSS css: String) -> (red: Double, green: Double, blue: Double)? {
        let s = css.trimmingCharacters(in: .whitespaces).lowercased()
        let body: Substring
        if s.hasPrefix("rgba("), s.hasSuffix(")") {
            body = s.dropFirst(5).dropLast()
        } else if s.hasPrefix("rgb("), s.hasSuffix(")") {
            body = s.dropFirst(4).dropLast()
        } else {
            return nil
        }
        let parts = body.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .compactMap { Double($0) }
        guard parts.count == 3 || parts.count == 4,
              parts.prefix(3).allSatisfy({ (0...255).contains($0) }) else { return nil }
        if parts.count == 4, parts[3] < 1 { return nil }
        return (parts[0] / 255, parts[1] / 255, parts[2] / 255)
    }
}
