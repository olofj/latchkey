import UIKit
import XCTest

// F10 §4.3 and §4.4: two checks called at the end of existing L1 flows, not
// a suite of their own. Both return findings as sentences instead of
// failing, so a shared launch (F14) can record them and the test that owns
// the claim asserts they are empty.

/// The window's safe-area insets, from the `window-safe-insets` probe
/// (`-UITestReportSafeArea`, `RawWebView.swift`).
struct SafeInsets: CustomStringConvertible {
    let top, left, bottom, right: Double

    var description: String { "top=\(Int(top)) left=\(Int(left)) bottom=\(Int(bottom)) right=\(Int(right))" }
}

@MainActor
extension XCTestCase {
    /// Nil, with a failure, when the probe is missing or unreadable: a sweep
    /// without insets would pass everything.
    func safeInsets(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> SafeInsets? {
        let probe = app.descendants(matching: .any).matching(identifier: "window-safe-insets").firstMatch
        guard probe.appears(within: 10) else {
            XCTFail("the four-inset probe is installed (-UITestReportSafeArea)", file: file, line: line)
            return nil
        }
        let value = probe.value as? String ?? ""
        var parts: [String: Double] = [:]
        for pair in value.split(separator: " ") {
            let kv = pair.split(separator: "=")
            if kv.count == 2, let n = Double(kv[1]) { parts[String(kv[0])] = n }
        }
        guard let t = parts["top"], let l = parts["left"], let b = parts["bottom"], let r = parts["right"] else {
            XCTFail("the four-inset probe reads four numbers: \(value)", file: file, line: line)
            return nil
        }
        return SafeInsets(top: t, left: l, bottom: b, right: r)
    }

    /// §4.3: every hittable element of the app's own chrome that reaches into
    /// an unsafe region, as "id-or-label frame reaches <edges> of <safe>".
    /// The web view is the page's and is not walked (§4.5 covers it). An
    /// element inside a scroll view, table or collection view is checked
    /// against the sides only: a list scrolling under the home indicator is
    /// how lists work. `exempt` maps an identifier or label to its reason.
    /// One snapshot for the tree; hittability is asked only of the offenders.
    func obstructions(in app: XCUIApplication, insets: SafeInsets,
                      exempt: [String: String] = [:]) throws -> [String] {
        let kinds: Set<XCUIElement.ElementType> = [.button, .link, .staticText, .image, .switch, .slider,
                                                  .textField, .secureTextField, .toggle, .menuButton,
                                                  .segmentedControl, .searchField, .cell]
        let scrollers: Set<XCUIElement.ElementType> = [.scrollView, .table, .collectionView]
        let window = app.windows.firstMatch.frame
        let safe = CGRect(x: window.minX + insets.left, y: window.minY + insets.top,
                          width: window.width - insets.left - insets.right,
                          height: window.height - insets.top - insets.bottom)
        var offenders: [(XCUIElement.ElementType, String, CGRect, [String])] = []
        // A bar's items are laid out by the system, which in landscape puts
        // them in the side inset band beside the island's column, as in its
        // own apps (Settings' Done measured at x=42 against a 62 pt inset).
        // They are held to the top and bottom edges only.
        func walk(_ s: XCUIElementSnapshot, scrolled: Bool, barred: Bool) {
            if s.elementType == .webView { return }
            let inScroller = scrolled || scrollers.contains(s.elementType)
            let inBar = barred || s.elementType == .navigationBar || s.elementType == .toolbar
            let key = s.identifier.isEmpty ? s.label : s.identifier
            let f = s.frame
            if kinds.contains(s.elementType), f.width > 0.5, f.height > 0.5, !key.isEmpty, exempt[key] == nil {
                var edges: [String] = []
                if !inBar, f.minX < safe.minX - 0.5 { edges.append("left") }
                if !inBar, f.maxX > safe.maxX + 0.5 { edges.append("right") }
                if !inScroller, f.minY < safe.minY - 0.5 { edges.append("top") }
                if !inScroller, f.maxY > safe.maxY + 0.5 { edges.append("bottom") }
                if !edges.isEmpty { offenders.append((s.elementType, key, f, edges)) }
            }
            s.children.forEach { walk($0, scrolled: inScroller, barred: inBar) }
        }
        walk(try app.snapshot(), scrolled: false, barred: false)
        return offenders.compactMap { type, key, frame, edges in
            let e = app.descendants(matching: type).matching(
                NSPredicate(format: "identifier == %@ OR label == %@", key, key)).firstMatch
            guard e.exists, e.isHittable else { return nil }
            return "\(key) \(frame) reaches the \(edges.joined(separator: "+")) unsafe region; safe area \(safe)"
        }
    }

    /// §4.4: Apple's audit of what is on screen, for clipped text, hit
    /// regions, undetectable elements and contrast. `suppress` returns a
    /// reason for a finding that is intended, which is printed and not
    /// returned; every other finding is returned as a sentence. Findings on
    /// the page's own elements are §4.5's and suppressed: an element is the
    /// page's when its frame and label are one of the web view's
    /// descendants'. Not "inside the web view's frame": the web view stays
    /// in the tree, full screen, under the error page and every sheet.
    func auditFindings(in app: XCUIApplication, context: String,
                       suppress: @escaping (XCUIAccessibilityAuditIssue) -> String? = { _ in nil }) throws -> [String] {
        var page = Set<String>()
        let web = app.webViews.firstMatch
        if web.exists {
            func collect(_ s: XCUIElementSnapshot) {
                page.insert("\(s.label)|\(s.frame)")
                s.children.forEach(collect)
            }
            try web.snapshot().children.forEach(collect)
        }
        var findings: [String] = []
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion, .elementDetection, .contrast]) { issue in
            let el = issue.element
            let what = el.map { e in "\(e.elementType.rawValue) \(e.identifier.isEmpty ? e.label : e.identifier) \(e.frame)" }
                ?? "(no element: \(issue.detailedDescription))"
            let line = "\(issue.compactDescription): \(what)"
            let reason: String? = if let el, page.contains("\(el.label)|\(el.frame)") {
                "the page's own; §4.5 covers the page"
            } else {
                suppress(issue)
            }
            if let reason {
                print("AUDIT \(context) suppressed: \(line) -- \(reason)")
            } else {
                findings.append(line)
            }
            return true
        }
        return findings
    }

    /// Rotates and waits until the window has the orientation's shape.
    func rotate(_ app: XCUIApplication, to orientation: UIDeviceOrientation) async throws {
        XCUIDevice.shared.orientation = orientation
        for _ in 0..<25 {
            let f = app.windows.firstMatch.frame
            if (f.width > f.height) == orientation.isLandscape { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        // The rotation's own animation, after the frame has its new shape.
        try await Task.sleep(for: .milliseconds(600))
    }

    /// §4.3 and §4.4 together on what is on screen now, as findings, each
    /// prefixed with `context` ("<screen> portrait|landscape"). The audit's
    /// findings from its first run are held by `auditBaseline`.
    func screenFindings(_ app: XCUIApplication, _ context: String, insets: SafeInsets,
                        exempt: [String: String] = [:]) throws -> [String] {
        let screen = context.replacingOccurrences(of: " portrait", with: "")
            .replacingOccurrences(of: " landscape", with: "")
        let found = try obstructions(in: app, insets: insets, exempt: exempt).map { "\(context): \($0)" }
            + auditFindings(in: app, context: context) { issue in
                let key = Self.baselineKey(screen, issue)
                if let reason = Self.auditBaseline[key] { return reason }
                // The audit sometimes cannot resolve the element of a finding
                // it named in another run (seen: Settings' section headers,
                // as "SwiftUI.AccessibilityNode"). Such a finding can only be
                // matched by screen and kind.
                guard issue.element == nil else { return nil }
                let prefix = key.replacingOccurrences(of: "|(no element)", with: "|")
                return Self.auditBaseline.keys.contains { $0.hasPrefix(prefix) }
                    ? "baseline: unresolved element, and this screen has baselined findings of this kind" : nil
            }.map { "\(context): audit: \($0)" }
        let line = "SCREEN-SWEEP \(context): insets \(insets), \(found.count) finding(s)"
        print(line)
        add(XCTAttachment(string: ([line] + found).joined(separator: "\n")))
        return found
    }

    /// "screen|kind|id-or-label", kind being the finding's first word
    /// ("Contrast" covers both "failed" and "nearly passed", which a run can
    /// flip between).
    static func baselineKey(_ screen: String, _ issue: XCUIAccessibilityAuditIssue) -> String {
        let kind = issue.compactDescription.split(separator: " ").first.map(String.init) ?? ""
        let key = issue.element.map { $0.identifier.isEmpty ? $0.label : $0.identifier } ?? "(no element)"
        return "\(screen)|\(kind)|\(key)"
    }

    /// F10 §4.4's first run, 2026-09-27: every finding it reported on our own
    /// screens, held so that a *new* one fails. These are not intended; each
    /// is an open item in F10 §8. Remove an entry when its finding is fixed.
    nonisolated static let auditBaseline: [String: String] = {
        let contrast = "baseline: system or tinted colour under 4.5:1 (F10 §8, open)"
        let clipped = "baseline: may clip at larger Dynamic Type (F10 §8, open)"
        var b: [String: String] = [:]
        for key in ["login-button", "4.", "Then Latchkey finds the dashboard and opens it."] {
            b["gate|Contrast|\(key)"] = contrast
        }
        for key in ["nav-error-choose-gateway", "nav-error-retry", "nav-error-next", "Details"] {
            b["error page|Contrast|\(key)"] = contrast
        }
        for key in ["nav-error-title", "nav-error-cause", "nav-error-next", "nav-error-retry", "nav-error-choose-gateway"] {
            b["error page|Text|\(key)"] = clipped
        }
        for key in ["Cancel", "gateway-proxy-unhealthy", "gateway-sweep-done", "gateway-manual-use",
                    "Enter manually", "Gateways", "Search again"] {
            b["picker|Contrast|\(key)"] = contrast
        }
        b["picker|Text|gateway-manual-field"] = clipped
        for key in ["settings-done-button", "hostname-rename-warning", "Gateway", "Name"] {
            b["settings|Contrast|\(key)"] = contrast
        }
        for key in ["dash.tail-scale.ts.net", "", "(no element)"] {
            b["settings|Text|\(key)"] = clipped
        }
        return b
    }()
}
