#if LATCHKEY_TEST_HOOKS
import SwiftUI

/// F10 §4.5's instrument (`-UITestPageSweep`): the page reports, from its own
/// layout, which of its drawn items collide. The accessibility tree cannot
/// answer that for web content: it has no clipping and no z-order, so a chip
/// scrolled out of the instance bar, or content scrolled under the sticky
/// header, overlaps its neighbours there while the owner sees nothing wrong
/// (measured on the real 0.7.1 bundle, F10 §9). The page knows both.
///
/// An item is a control (not inside another control) or an element with its
/// own text (not inside a control), measured tight (a text item by its text
/// nodes' ranges), clipped by every ancestor whose overflow is not visible
/// and by the viewport. It is drawn if it is not hidden by `display`,
/// `visibility` or an opacity under 0.1 anywhere up its ancestry, is at
/// least 2 px on each axis once clipped, and at one of five points inside it
/// nothing above it paints (a background colour or image; transparent layers
/// are looked through). Hit tests are taken with every element's
/// `pointer-events` forced on for the length of the script, because the page
/// fades content under its header with an overlay that ignores the pointer
/// (F10 §9). Two drawn items collide when their clipped rects, each inset by
/// 1 px, intersect and neither contains the other in the DOM.
enum PageSweep {
    static let flag = "-UITestPageSweep"

    /// Run by `callAsyncJavaScript` in the app's content world; returns JSON.
    static let script = #"""
    const vw = innerWidth, vh = innerHeight;
    const controlSel = 'a[href],button,input,textarea,select,[role="button"],[role="link"],[role="tab"],[role="menuitem"],[role="switch"],[role="checkbox"]';
    const shown = el => {
      for (let e = el; e && e.nodeType === 1; e = e.parentElement) {
        const cs = getComputedStyle(e);
        if (cs.display === 'none' || cs.visibility !== 'visible' || parseFloat(cs.opacity) < 0.1) return false;
      }
      return true;
    };
    const tight = el => {
      if (el.matches(controlSel)) return el.getBoundingClientRect();
      let r = null;
      for (const n of el.childNodes) {
        if (n.nodeType !== 3 || !n.textContent.trim()) continue;
        const range = document.createRange();
        range.selectNodeContents(n);
        const b = range.getBoundingClientRect();
        r = r ? { left: Math.min(r.left, b.left), top: Math.min(r.top, b.top),
                  right: Math.max(r.right, b.right), bottom: Math.max(r.bottom, b.bottom) } : b;
      }
      return r;
    };
    const clip = (el, r) => {
      let x1 = r.left, y1 = r.top, x2 = r.right, y2 = r.bottom;
      // From the element itself: its own text can overflow it, and its own
      // overflow clips that text.
      for (let e = el; e && e !== document.documentElement; e = e.parentElement) {
        const cs = getComputedStyle(e);
        if (cs.overflowX === 'visible' && cs.overflowY === 'visible') continue;
        const p = e.getBoundingClientRect();
        if (cs.overflowX !== 'visible') { x1 = Math.max(x1, p.left); x2 = Math.min(x2, p.right); }
        if (cs.overflowY !== 'visible') { y1 = Math.max(y1, p.top); y2 = Math.min(y2, p.bottom); }
      }
      return { x1: Math.max(x1, 0), y1: Math.max(y1, 0), x2: Math.min(x2, vw), y2: Math.min(y2, vh) };
    };
    // Seen at a point unless something above it there paints: a background
    // colour with any alpha, or a background image (a fade is a gradient).
    // Transparent layers are looked through.
    const paints = e => {
      const cs = getComputedStyle(e);
      const m = cs.backgroundColor.match(/rgba?\(([^)]*)\)/);
      const alpha = m ? (m[1].split(',')[3] === undefined ? 1 : parseFloat(m[1].split(',')[3])) : 0;
      return alpha > 0.3 || cs.backgroundImage !== 'none';
    };
    const onTop = (el, c) => {
      const w = c.x2 - c.x1, h = c.y2 - c.y1;
      for (const [fx, fy] of [[0.5, 0.5], [0.2, 0.3], [0.8, 0.3], [0.2, 0.7], [0.8, 0.7]]) {
        for (const t of document.elementsFromPoint(c.x1 + w * fx, c.y1 + h * fy)) {
          if (t === el || el.contains(t) || t.contains(el)) return true;
          if (paints(t)) break;
        }
      }
      return false;
    };
    // An overlay that ignores the pointer still covers what is under it, so
    // for the length of this script every element takes hit tests. The
    // script runs to completion with no paint in between.
    const probe = document.createElement('style');
    probe.textContent = '* { pointer-events: auto !important; }';
    document.head.appendChild(probe);
    const label = el => (el.getAttribute('aria-label') || el.textContent || el.getAttribute('placeholder') || el.tagName)
      .trim().replace(/\s+/g, ' ').slice(0, 48);
    const items = [];
    try {
    for (const el of document.body.querySelectorAll('*')) {
      if (el.closest('svg') && el.tagName.toLowerCase() !== 'svg') continue;
      const control = el.matches(controlSel);
      const outer = el.parentElement && el.parentElement.closest(controlSel);
      if (outer) continue;
      if (!control && ![...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim())) continue;
      const r = tight(el);
      if (!r) continue;
      const c = clip(el, r);
      if (c.x2 - c.x1 < 2 || c.y2 - c.y1 < 2) continue;
      if (!shown(el) || !onTop(el, c)) continue;
      // Text in a transparent colour with no fill of its own draws nothing.
      if (!control) {
        const cs = getComputedStyle(el);
        const fill = cs.webkitTextFillColor || cs.color;
        if (/rgba\([^)]*,\s*0\)$/.test(fill) && (cs.backgroundClip !== 'text' && cs.webkitBackgroundClip !== 'text')) continue;
      }
      items.push({ el, c, label: label(el) });
    }
    } finally {
      probe.remove();
    }
    const box = c => `(${Math.round(c.x1)},${Math.round(c.y1)} ${Math.round(c.x2 - c.x1)}x${Math.round(c.y2 - c.y1)})`;
    const collisions = [];
    for (let i = 0; i < items.length; i++) {
      for (let j = i + 1; j < items.length; j++) {
        const a = items[i], b = items[j];
        if (a.el.contains(b.el) || b.el.contains(a.el)) continue;
        if (Math.max(a.c.x1, b.c.x1) + 1 < Math.min(a.c.x2, b.c.x2) - 1 &&
            Math.max(a.c.y1, b.c.y1) + 1 < Math.min(a.c.y2, b.c.y2) - 1) {
          collisions.push(`"${a.label}" ${box(a.c)} and "${b.label}" ${box(b.c)}`);
        }
      }
    }
    window.__latchkeySweepSeq = (window.__latchkeySweepSeq || 0) + 1;
    return JSON.stringify({ seq: window.__latchkeySweepSeq, vw, vh, n: items.length,
                            items: items.map(x => `${x.label} ${box(x.c)}`), collisions });
    """#
}

/// The report, as the value of `page-sweep`, re-taken every second while the
/// flag is set. Empty until the page has answered once.
struct PageSweepInstrument: View {
    let model: BrowserViewModel
    @State private var report = ""

    var body: some View {
        Text("page-sweep")
            .accessibilityIdentifier("page-sweep")
            .accessibilityValue(report)
            .task {
                while !Task.isCancelled {
                    if let json = await model.sessionCall(PageSweep.script, arguments: [:]) as? String {
                        report = json
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }
}
#endif
