// Host test for F10 §4.2: the fake dashboard must be no more forgiving than
// the product, in the dimensions that change layout.
//
// The bug this exists to prevent: F9. The shipped frontend asks for
// edge-to-edge layout (`viewport-fit=cover`) and insets its own chrome with
// `env(safe-area-inset-*)`; the fake asked for neither, so it could never be
// clipped by the Dynamic Island, and no L1 test could have seen the page
// drawn under it. A fixture simpler than the product hides exactly the bugs
// that reach the owner.
//
// Both documents are READ, never run: the fake's `PAGE` literal out of
// testing/harness/dashboard.py, and the installed KiroCrew frontend's
// index.html plus the same-origin stylesheets it links (the product keeps its
// CSS there; index.html mentions env() only in a comment, which is why
// comments are stripped before searching).
//
//   test-fixture-parity <dashboard.py> <kiro_crew/static/dist>
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: test-fixture-parity <dashboard.py> <kiro_crew/static/dist>")
    exit(2)
}
let fakePath = args[1]
let distDir = args[2]
let realIndex = distDir + "/index.html"

guard FileManager.default.fileExists(atPath: realIndex) else {
    print("  SKIP: fixture parity NOT CHECKED -- the real frontend is not installed at \(realIndex)")
    print("        (install KiroCrew into ~/.kiro/crew-venv, or set KIRO_CREW_DIST)")
    exit(0)
}

var failures = 0
func fail(_ s: String) { print("  FAIL: \(s)"); failures += 1 }

func read(_ path: String) -> String {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("  FAIL: cannot read \(path)")
        exit(1)
    }
    return s
}

func matches(_ pattern: String, in s: String) -> [[String]] {
    let re = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
        (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
    }
}

func stripping(_ pattern: String, from s: String) -> String {
    let re = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
}

/// What a document declares and consumes, as far as layout is concerned.
struct Layout {
    var viewportFit: String?          // nil when the key is absent
    var interactiveWidget: String?
    var insetUses: Int                // env(safe-area-inset-*) in its CSS
    var viewport: String?             // the whole content attribute, for the message
}

func layout(html raw: String, stylesheetsUnder dir: String?) -> Layout {
    let html = stripping("<!--.*?-->", from: raw)
    var viewport: String?
    if let meta = matches(#"<meta\b[^>]*\bname\s*=\s*["']?viewport["']?[^>]*>"#, in: html).first?[0],
       let content = matches(#"\bcontent\s*=\s*(?:"([^"]*)"|'([^']*)')"#, in: meta).first {
        viewport = content[1].isEmpty ? content[2] : content[1]
    }
    var keys: [String: String] = [:]
    for part in (viewport ?? "").split(whereSeparator: { $0 == "," || $0 == ";" }) {
        let kv = part.split(separator: "=", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        if kv.count == 2 { keys[kv[0]] = kv[1] }
    }

    // The CSS the document applies: inline <style> blocks, style="" attributes,
    // and linked same-origin stylesheets. Not scripts: a string in JS is not a
    // layout rule.
    var css = matches(#"<style\b[^>]*>(.*?)</style>"#, in: html).map { $0[1] }
    css += matches(#"\bstyle\s*=\s*(?:"([^"]*)"|'([^']*)')"#, in: html).map { $0[1] + $0[2] }
    for link in matches(#"<link\b[^>]*>"#, in: html).map({ $0[0] }) {
        guard !matches(#"\brel\s*=\s*["']?stylesheet"#, in: link).isEmpty,
              let href = matches(#"\bhref\s*=\s*["']([^"']+)["']"#, in: link).first?[1],
              !href.contains("://"), !href.hasPrefix("//") else { continue }
        guard let dir else {
            fail("the fake links a local stylesheet (\(href)); this test reads only its PAGE literal")
            continue
        }
        let path = dir + "/" + href.drop(while: { $0 == "/" }).split(separator: "?")[0]
        guard FileManager.default.fileExists(atPath: path) else {
            fail("the real frontend links \(href), which is not at \(path)")
            continue
        }
        css.append(read(path))
    }
    let uses = css.map { matches(#"env\(\s*safe-area-inset-(top|right|bottom|left)"#,
                                 in: stripping(#"/\*.*?\*/"#, from: $0)).count }
        .reduce(0, +)
    return Layout(viewportFit: keys["viewport-fit"], interactiveWidget: keys["interactive-widget"],
                  insetUses: uses, viewport: viewport)
}

// The fake's document is dashboard.py's PAGE literal: what `/` serves.
let py = read(fakePath)
guard let page = matches(#"(?m)^PAGE = """(.*?)""""#, in: py).first?[1] else {
    print("  FAIL: no PAGE = \"\"\"...\"\"\" literal in \(fakePath)")
    exit(1)
}
let fake = layout(html: page, stylesheetsUnder: nil)
let real = layout(html: read(realIndex), stylesheetsUnder: distDir)

print("  real: viewport \"\(real.viewport ?? "(none)")\", \(real.insetUses) env(safe-area-inset-*) in its CSS")
print("  fake: viewport \"\(fake.viewport ?? "(none)")\", \(fake.insetUses) env(safe-area-inset-*) in its CSS")

// Instrument check: a parser that cannot find what is certainly in the
// product proves nothing about the fake. F9 measured all three in 0.6.0.
if real.viewport == nil { fail("found no viewport meta in the real frontend: the parser is broken") }
if real.viewportFit == nil && real.insetUses == 0 {
    fail("the real frontend neither declares viewport-fit nor uses env(): the parser is broken, or KiroCrew changed -- re-read F10 §4.2")
}

func show(_ v: String?) -> String { v ?? "(absent)" }
if fake.viewportFit != real.viewportFit {
    fail("viewport-fit: product \(show(real.viewportFit)), fake \(show(fake.viewportFit))"
         + " -- the fake must ask for the same layout the product does")
}
if fake.interactiveWidget != real.interactiveWidget {
    fail("interactive-widget: product \(show(real.interactiveWidget)), fake \(show(fake.interactiveWidget))"
         + " -- it decides what the keyboard does to the layout viewport")
}
if (fake.insetUses > 0) != (real.insetUses > 0) {
    fail("env(safe-area-inset-*): product uses it \(real.insetUses)x, fake \(fake.insetUses)x"
         + " -- the fake must consume the insets the way the product does")
}

if failures > 0 {
    print("fixture-parity: \(failures) FAILED")
    exit(1)
}
print("fixture-parity: ok (viewport-fit \(show(real.viewportFit)), interactive-widget \(show(real.interactiveWidget)), both consume env())")
