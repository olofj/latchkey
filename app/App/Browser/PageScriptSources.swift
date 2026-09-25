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

    /// The JSON-answering sibling of `sessionFetch`, for a share (F3 §4.5):
    /// the slot list, the folders and the post. Arguments `path`, `method`,
    /// `body` (a JSON string, or null), `shareId` and `timeoutMs`. Returns
    /// `{status, body, auth}` -- the status, the response text and whether
    /// `X-Auth-Required` came back -- or `{status: 0}` when the request got
    /// no answer (network, abort). As the page, for the reasons
    /// `sessionFetch` gives; the header names the item, so the test gateway
    /// can tell a share's requests from the page's.
    static let shareFetch = #"""
    const controller = new AbortController();
    const timer = timeoutMs > 0 ? setTimeout(function () { controller.abort(); }, timeoutMs) : null;
    try {
      const headers = {'X-Latchkey-Share': shareId};
      if (body !== null && body !== undefined) { headers['Content-Type'] = 'application/json'; }
      const r = await fetch(path, {method: method, credentials: 'same-origin', cache: 'no-store',
                                   headers: headers, body: body === null ? undefined : body,
                                   signal: controller.signal});
      const text = await r.text();
      return {status: r.status, body: text, auth: r.headers.get('X-Auth-Required') !== null};
    } catch (e) {
      return {status: 0, body: '', auth: false};
    } finally {
      if (timer !== null) { clearTimeout(timer); }
    }
    """#

    /// Stages one chunk of a shared document in the app's content world
    /// (F3 §4.6). `callAsyncJavaScript` passes strings, not bytes, so the
    /// file arrives as base64 of at most `ShareDelivery.chunkBytes` raw bytes
    /// per call. Arguments `id`, `index` and `chunk`. The parts live on the
    /// app world's `window`, which the page cannot see. Returns the number of
    /// parts staged; a chunk out of order clears the item and returns -1, so
    /// a retry can never append to a half-staged file.
    static let shareStageChunk = #"""
    const store = window.__latchkeyShare || (window.__latchkeyShare = {});
    if (index === 0) { store[id] = []; }
    const parts = store[id];
    if (!parts || parts.length !== index) { delete store[id]; return -1; }
    const bin = atob(chunk);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) { bytes[i] = bin.charCodeAt(i); }
    parts.push(new Blob([bytes]));
    return parts.length;
    """#

    /// Uploads the staged parts as the page (F3 §4.6): one `file` part named
    /// `filename`, to `/api/upload/file`, the dashboard composer's route.
    /// Arguments `id`, `filename`, `parts` (the count the app staged) and
    /// `timeoutMs`. Returns what `shareFetch` returns; a staged count that is
    /// not `parts` is refused here, before anything is sent. The staged
    /// parts are dropped whatever happens.
    static let shareUpload = #"""
    const store = window.__latchkeyShare || {};
    const staged = store[id];
    const controller = new AbortController();
    const timer = timeoutMs > 0 ? setTimeout(function () { controller.abort(); }, timeoutMs) : null;
    try {
      if (!staged || staged.length !== parts) { return {status: -1, body: '', auth: false}; }
      const form = new FormData();
      form.append('file', new Blob(staged), filename);
      const r = await fetch('/api/upload/file', {method: 'POST', credentials: 'same-origin', body: form,
                                                 headers: {'X-Latchkey-Share': id}, signal: controller.signal});
      const text = await r.text();
      return {status: r.status, body: text, auth: r.headers.get('X-Auth-Required') !== null};
    } catch (e) {
      return {status: 0, body: '', auth: false};
    } finally {
      delete store[id];
      if (timer !== null) { clearTimeout(timer); }
    }
    """#

    /// The name `blockedMarker` posts to, in the app's own content world.
    static let blockedMarkerHandler = "kiroBlocked"
    /// The id of the `<style>` element `blockedMarker` adds.
    static let blockedMarkerStyleID = "latchkey-blocked-marker"
    /// What VoiceOver reads for a blocked image, and what the L1 test finds.
    static let blockedMarkerLabel = "Image not loaded. Tap to open in Safari."

    /// Marks images the content rule list blocked, and counts (F6 §4a).
    ///
    /// A rule list blocks silently: the page never learns why, and the app
    /// never sees the request. Injecting a marker element beside the image
    /// fights React, which reconciles it away on the next render, so this
    /// sets two attributes on the image React already owns: if React
    /// re-renders it, the load fails again and they are set again.
    ///
    ///  - A capture-phase `error` listener on `document` (`error` does not
    ///    bubble). An `img` whose http(s) source is off this document's
    ///    origin gets `data-latchkey-blocked="<absolute url>"` and an
    ///    `aria-label`. Off-origin `script`/`link` failures are counted as
    ///    blocked; same-origin `img`/`script`/`link` failures are counted as
    ///    the gateway's own — a wrong allow rule shows up as those, not as a
    ///    mystery blank page. Counts go to native 1 s after the last one, as
    ///    `{event: "counts", blocked, gatewayFailed}` increments: numbers,
    ///    never URLs.
    ///  - A `<style>` on `<html>` at document start (before `<head>` exists)
    ///    draws the marker: a 44 pt dashed box. `min-*` is what makes an
    ///    `alt=""` image visible at all; WebKit renders a failed one at 0×0.
    ///    No URL in it, so it depends on neither `img-src` nor the list.
    ///  - A capture-phase `click` listener. Trusted clicks only, so the
    ///    page's own `el.click()` cannot send anything out; a tap on a marked
    ///    image posts `{event: "open", url}` and does not reach the page's own
    ///    handler (a lightbox).
    ///  - After `load` and on a 2 s debounce after each new resource entry,
    ///    the origins of off-origin resources the page has loaded, as
    ///    increments `{event: "hosts", hosts: {origin: n}}`. A diagnostic of
    ///    which allowlisted CDNs were contacted (§4.1a), never evidence that a
    ///    block happened.
    ///
    /// Every frame (the one exception PageScripts' header asks to be
    /// justified): agent images render inside same-origin widget frames too.
    /// Runs in the app's own content world, so the page cannot post to it.
    /// If a future bundle swallows `error` events, the marker stops appearing
    /// and the blocking itself carries on.
    static let blockedMarker = #"""
    (function () {
      var handlers = window.webkit && window.webkit.messageHandlers;
      var handler = handlers && handlers.kiroBlocked;
      var ATTR = 'data-latchkey-blocked';
      var LABEL = 'Image not loaded. Tap to open in Safari.';
      function post(m) { try { if (handler) { handler.postMessage(m); } } catch (e) {} }

      function absolute(u) {
        try {
          var x = new URL(u, document.baseURI);
          return (x.protocol === 'http:' || x.protocol === 'https:') ? x : null;
        } catch (e) { return null; }
      }

      try {
        var style = document.createElement('style');
        style.id = 'latchkey-blocked-marker';
        style.textContent = 'img[' + ATTR + '] { display: inline-block; min-width: 44px; min-height: 44px; ' +
          'box-sizing: border-box; border: 1px dashed currentColor; border-radius: 6px; ' +
          'background-color: rgba(127,127,127,.15); cursor: pointer; }';
        document.documentElement.appendChild(style);
      } catch (e) {}

      // Only images this script marked, with the URL it saw, count: a page
      // (or sanitized agent HTML, which keeps data-* attributes) can set
      // the attribute on anything, but cannot reach this world's map.
      var marked = new WeakMap();
      var blocked = 0, gatewayFailed = 0, countsTimer = null;
      function flushCounts() {
        countsTimer = null;
        if (!blocked && !gatewayFailed) { return; }
        post({event: 'counts', blocked: blocked, gatewayFailed: gatewayFailed});
        blocked = 0; gatewayFailed = 0;
      }
      function scheduleCounts() {
        if (countsTimer !== null) { clearTimeout(countsTimer); }
        countsTimer = setTimeout(flushCounts, 1000);
      }

      document.addEventListener('error', function (e) {
        var el = e.target;
        if (!el || !el.tagName) { return; }
        var tag = String(el.tagName).toLowerCase(), raw = null;
        if (tag === 'img') { raw = el.currentSrc || el.src; }
        else if (tag === 'script') { raw = el.src; }
        else if (tag === 'link') { raw = el.href; }
        if (!raw) { return; }
        var url = absolute(raw);
        if (!url) { return; }
        if (url.origin === location.origin) { gatewayFailed += 1; scheduleCounts(); return; }
        blocked += 1;
        if (tag === 'img') {
          marked.set(el, url.href);
          el.setAttribute(ATTR, url.href);
          el.setAttribute('aria-label', LABEL);
        }
        scheduleCounts();
      }, true);

      document.addEventListener('click', function (e) {
        if (!e.isTrusted) { return; }
        var t = e.target;
        var el = t && t.closest ? t.closest('img[' + ATTR + ']') : null;
        if (!el || !marked.has(el)) { return; }
        e.preventDefault();
        e.stopPropagation();
        post({event: 'open', url: marked.get(el)});
      }, true);

      var hosts = {}, hostsTimer = null;
      function flushHosts() {
        hostsTimer = null;
        var any = false;
        for (var k in hosts) { if (Object.prototype.hasOwnProperty.call(hosts, k)) { any = true; break; } }
        if (!any) { return; }
        post({event: 'hosts', hosts: hosts});
        hosts = {};
      }
      function note(entries) {
        for (var i = 0; i < entries.length; i++) {
          var url = absolute(entries[i].name);
          if (!url || url.origin === location.origin) { continue; }
          hosts[url.origin] = (hosts[url.origin] || 0) + 1;
        }
        if (hostsTimer !== null) { clearTimeout(hostsTimer); }
        hostsTimer = setTimeout(flushHosts, 2000);
      }
      try {
        new PerformanceObserver(function (list) { note(list.getEntries()); })
          .observe({type: 'resource', buffered: true});
      } catch (e) {}
      window.addEventListener('load', function () {
        if (hostsTimer !== null) { clearTimeout(hostsTimer); flushHosts(); }
      });
    })();
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

    /// The name `activationReporter` posts to, in the app's own content world.
    static let activationHandler = "latchkeyActivation"

    /// Tells the app the owner clicked (F17 §4.2): the one signal a page
    /// cannot forge. `isTrusted` is false for `el.click()` and
    /// `dispatchEvent`, and the handler exists only in the app's world, so
    /// neither can post to it. `click` alone: a tap, a keyboard activation
    /// and a form's implicit submit all produce one; scrolling and typing do
    /// not. On `window`, capturing, and installed at document start, so it
    /// runs before any listener the page adds and a page's
    /// `stopPropagation` cannot hide a click from it.
    static let activationReporter = #"""
    (function () {
      var h = window.webkit && window.webkit.messageHandlers
        && window.webkit.messageHandlers.latchkeyActivation;
      if (!h) { return; }
      window.addEventListener('click', function (e) {
        if (e.isTrusted) { try { h.postMessage(1); } catch (err) {} }
      }, true);
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
    ///
    /// And `{p: 'x', r}`, the page's extent: the largest vertical scroll range
    /// of the document or of any element whose `overflow-y` lets it scroll
    /// (form controls aside), in screen points, touch or no touch. The bar is
    /// hidden by default, and a page with no range must keep it (F15 §4b), so
    /// the app has to know before the owner touches anything. Measured at most
    /// every 500 ms, after the document loads, resizes, mutates or scrolls, and
    /// posted when it changes and always at `load`. It reads layout, never
    /// the page's markup or text.
    static let appBarObserver = #"""
    (function () {
      var handlers = window.webkit && window.webkit.messageHandlers;
      var handler = handlers && handlers.latchkeyAppBar;
      if (!handler) { return; }
      var opts = {capture: true, passive: true};
      var active = false, pending = false, x = 0, y = 0, w = 0, h = 0, dx = 0, dy = 0, range = 0;
      var extent = -1, due = 0;
      function scale() { return window.visualViewport ? window.visualViewport.scale : 1; }
      function post(m) { try { handler.postMessage(m); } catch (e) {} }
      function send(p) {
        post({p: p, dx: dx, dy: dy, r: range});
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
      function overflowY(el) {
        return (el && typeof getComputedStyle === 'function') ? getComputedStyle(el).overflowY : 'visible';
      }
      function measure(always) {
        due = 0;
        var r = 0;
        try {
          var se = document.scrollingElement;
          if (se) {
            var clip = /^(hidden|clip)$/;
            var d = se.scrollHeight - se.clientHeight;
            if (d > 0 && !clip.test(overflowY(document.documentElement)) && !clip.test(overflowY(document.body))) { r = d; }
          }
          var all = document.querySelectorAll ? document.querySelectorAll('*') : [];
          for (var i = 0; i < all.length; i++) {
            var el = all[i], e = el.scrollHeight - el.clientHeight;
            if (e > r && el !== se && !/^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName)
                && /^(auto|scroll|overlay)$/.test(overflowY(el))) { r = e; }
          }
        } catch (err) { return; }
        r = Math.round(r * scale());
        if (always || r !== extent) { extent = r; post({p: 'x', r: r}); }
      }
      function soon() { if (!due && typeof setTimeout === 'function') { due = setTimeout(measure, 500); } }
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
        soon();
        if (!active) { return; }
        var el = (e.target === document || e.target === window) ? document.scrollingElement : e.target;
        if (!el || typeof el.scrollHeight !== 'number') { return; }
        var r = (el.scrollHeight - el.clientHeight) * scale();
        if (r > range) { range = r; }
      }, opts);
      window.addEventListener('DOMContentLoaded', soon, opts);
      window.addEventListener('resize', soon, opts);
      window.addEventListener('load', function () { measure(true); }, opts);
      if (typeof MutationObserver === 'function') {
        new MutationObserver(soon).observe(document, {childList: true, subtree: true, attributes: true, characterData: true});
      }
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
