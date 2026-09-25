// Host tests for F3's pure parts: ShareItem, ShareInboxPolicy, ShareURL,
// ShareMessage and ShareOutcome (F3 §7, host rows).
import Foundation

var failures = 0
var checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  FAIL \(what)") }
}

let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
let MB: Int64 = 1024 * 1024

func item(_ kind: ShareItem.Kind, url: String? = nil, title: String? = nil, text: String? = nil,
          note: String? = nil, filename: String? = nil) -> ShareItem {
    ShareItem(id: "i1", kind: kind, url: url, title: title, text: text, note: note, filename: filename,
              byteCount: 1, createdAt: now, source: .urlScheme)
}

print("== ShareMessage")
expect(ShareMessage.compose(item(.link, url: "https://example.com/a", title: "A title", note: "read this"))
       == "A title\nhttps://example.com/a\n\nread this",
       "link: title, URL, blank line, note")
expect(ShareMessage.compose(item(.link, url: "https://example.com/a", title: "A title"))
       == "A title\nhttps://example.com/a", "link with no note: no blank line, nothing trailing")
expect(ShareMessage.compose(item(.link, url: "https://example.com/a")) == "https://example.com/a",
       "link with no title: the URL alone")
expect(ShareMessage.compose(item(.link, url: "https://example.com/a", title: "T", note: "   \n "))
       == "T\nhttps://example.com/a", "a whitespace-only note is no note")
expect(ShareMessage.compose(item(.text, text: "some words", note: "why"))
       == "some words\n\nwhy", "text: the text, blank line, note")
expect(ShareMessage.compose(item(.text, text: "line one  \nline two\t", note: nil))
       == "line one\nline two", "no trailing whitespace on any line")
let doc = item(.document, note: "summarise", filename: "report.pdf")
let docMessage = ShareMessage.compose(doc, uploadedPath: "/srv/up/abc/report.pdf")
expect(docMessage.contains("[attached_file 1] /srv/up/abc/report.pdf"),
       "document: the gateway's token grammar with the path exactly as returned: \(docMessage)")
expect(docMessage == "summarise\n[attached_file 1] /srv/up/abc/report.pdf",
       "document: the note, then the token on the next line (the composer's order and join): \(docMessage)")
expect(ShareMessage.compose(item(.document, filename: "r.pdf"), uploadedPath: "/p/r.pdf")
       == "[attached_file 1] /p/r.pdf", "document with no note: the token alone")
expect(!docMessage.hasSuffix("\n") && !docMessage.hasSuffix(" "), "no trailing whitespace")

print("== ShareOutcome")
typealias R = ShareOutcome.Response
expect(ShareOutcome.post(R(status: 200, body: #"{"ok":true,"slot":"obsidian","mid":"m1"}"#), slot: "obsidian")
       == .sent(slot: "obsidian"), "{ok, slot} is sent")
expect(ShareOutcome.post(R(status: 200, body: #"{"ok":true,"queued":true,"queue_id":"q1"}"#), slot: "obsidian")
       == .queued(slot: "obsidian"), "{ok, queued} is QUEUED, not sent")
expect(ShareOutcome.post(R(status: 200, body: #"{"ok":true,"queued":true}"#), slot: "b").label == "queued:b",
       "and its label says so")
expect(ShareOutcome.post(R(status: 403, body: #"{"error":"Token required","code":"forbidden"}"#, authRequired: true),
                         slot: "a") == .signedOut, "403 + X-Auth-Required is signed out")
expect(ShareOutcome.post(R(status: 403, body: "CSRF check failed: request origin not allowed."), slot: "a")
       == .refused(status: 403, text: nil), "a bare 403 is a refusal")
expect(ShareOutcome.post(R(status: 403, body: "CSRF check failed"), slot: "a").label == "failed:refused-403",
       "labelled refused-403")
expect(ShareOutcome.offersPrefill(.refused(status: 403, text: nil), kind: .link), "a bare 403 offers prefill for a link")
expect(!ShareOutcome.offersPrefill(.refused(status: 403, text: nil), kind: .document), "never for a document")
expect(!ShareOutcome.offersPrefill(.unreachable, kind: .link), "not for other failures")
expect(ShareOutcome.post(R(status: nil), slot: "a") == .unreachable, "no answer is unreachable")
expect(ShareOutcome.post(R(status: 0), slot: "a").label == "failed:unreachable", "status 0 is unreachable too")
expect(ShareOutcome.post(R(status: 200, body: "<html>"), slot: "a") == .refused(status: 200, text: nil),
       "a 2xx that is not the receipt is not sent")
expect(ShareOutcome.post(R(status: 200, body: #"{"ok":false,"error":"nope"}"#), slot: "a")
       == .refused(status: 200, text: "nope"), "ok:false is not sent")
expect(ShareOutcome.post(R(status: 409, body: #"{"error":"Slot is reserved"}"#), slot: "a").label
       == "failed:Slot is reserved", "a 409 keeps the gateway's words")
switch ShareOutcome.upload(R(status: 200, body: #"{"paths":["/srv/up/x.pdf"]}"#)) {
case .success(let p): expect(p == "/srv/up/x.pdf", "upload: the first path, as returned")
case .failure: expect(false, "upload: 200 with paths is a success")
}
switch ShareOutcome.upload(R(status: 413, body: #"{"error":"File too large (max 1MB)"}"#)) {
case .success: expect(false, "413 is not a success")
case .failure(let f): expect(f.outcome.label == "failed:File too large (max 1MB)", "413 keeps the gateway's text: \(f.outcome.label)")
}
switch ShareOutcome.upload(R(status: 400, body: #"{"error":"Unsupported file type: .bin","code":"unsupported_file_type"}"#)) {
case .success: expect(false, "400 is not a success")
case .failure(let f): expect(f.outcome.label == "failed:Unsupported file type: .bin", "400 keeps the gateway's text")
}
switch ShareOutcome.upload(R(status: 200, body: #"{"paths":[]}"#)) {
case .success: expect(false, "an empty paths list is not a success")
case .failure: expect(true, "")
}
switch ShareOutcome.upload(R(status: 0)) {
case .success: expect(false, "no answer is not a success")
case .failure(let f): expect(f.outcome == .unreachable, "upload with no answer: unreachable")
}
expect(ShareOutcome.sent(slot: "a").isDelivered && ShareOutcome.queued(slot: "a").isDelivered,
       "sent and queued are delivered")
expect(!ShareOutcome.unreachable.isDelivered && !ShareOutcome.signedOut.isDelivered
       && !ShareOutcome.refused(status: 413, text: "x").isDelivered, "nothing else is")
expect(ShareOutcome.sentence(for: .unreachable, gatewayHost: "chonk").contains("Couldn't reach chonk"),
       "unreachable names the gateway")
expect(ShareOutcome.sentence(for: .queued(slot: "a"), gatewayHost: nil).hasPrefix("Queued"),
       "queued says queued")
expect(ShareOutcome.sentence(for: .refused(status: 400, text: "Unsupported file type: .bin"), gatewayHost: nil)
       == "Unsupported file type: .bin", "a refusal is the gateway's text, verbatim")
expect(ShareOutcome.sentence(for: .sessionGone, gatewayHost: nil).contains("isn't there any more"),
       "a gone session says so")
expect(ShareOutcome.uploadInterrupted(done: 3, of: 13).sentence == "Upload failed after 3 of 13 chunks.",
       "an interrupted upload says how far")
expect(ShareOutcome.unreachable.code == ShareOutcome.unreachableCode, "a failed item keeps the code")

print("== ShareInboxPolicy")
expect(ShareInboxPolicy.admit(byteCount: 50 * MB, fileExtension: ".pdf", inboxCount: 0, inboxBytes: 0)
       == .admitted(advisory: nil), "exactly 50 MB is admitted")
expect(ShareInboxPolicy.admit(byteCount: 50 * MB + 1, fileExtension: ".pdf", inboxCount: 0, inboxBytes: 0)
       == .refused(.tooLarge(byteCount: 50 * MB + 1)), "one byte over 50 MB is refused")
expect(ShareInboxPolicy.admit(byteCount: 10, fileExtension: "", inboxCount: 19, inboxBytes: 0)
       == .admitted(advisory: nil), "a 20th item is admitted")
expect(ShareInboxPolicy.admit(byteCount: 10, fileExtension: "", inboxCount: 20, inboxBytes: 0)
       == .refused(.inboxFull(waiting: 20)), "a 21st item is refused")
expect(ShareInboxPolicy.admit(byteCount: MB, fileExtension: ".pdf", inboxCount: 3, inboxBytes: 199 * MB)
       == .admitted(advisory: nil), "up to 200 MB in the inbox")
expect(ShareInboxPolicy.admit(byteCount: MB + 1, fileExtension: ".pdf", inboxCount: 3, inboxBytes: 199 * MB)
       == .refused(.inboxFull(waiting: 3)), "into the 201st MB is refused")
if case .admitted(let advisory?) = ShareInboxPolicy.admit(byteCount: 10, fileExtension: ".bin", inboxCount: 0, inboxBytes: 0) {
    expect(advisory.contains(".bin"), "an advisory names the extension")
} else {
    expect(false, ".bin is admitted with an advisory, not refused")
}
expect(ShareInboxPolicy.admit(byteCount: 10, fileExtension: ".PDF", inboxCount: 0, inboxBytes: 0)
       == .admitted(advisory: nil), "extensions compare case-insensitively")
expect(ShareInboxPolicy.sentence(for: .tooLarge(byteCount: 1)).contains("50 MB"), "too large names the limit")
expect(ShareInboxPolicy.sentence(for: .inboxFull(waiting: 20)).contains("20 shares waiting"), "full names the count")
let day: TimeInterval = 86400
let swept = ShareInboxPolicy.sweep(items: [("old", now.addingTimeInterval(-8 * day)),
                                           ("six", now.addingTimeInterval(-6 * day)),
                                           ("new", now)], now: now)
expect(swept == ["old"], "the sweep takes an 8-day item and keeps a 6-day one: \(swept)")
let staging = ShareInboxPolicy.sweepStaging([("crashed", now.addingTimeInterval(-11 * 60)),
                                             ("writing", now.addingTimeInterval(-60))], now: now)
expect(staging == ["crashed"], "a staging dir older than 10 minutes is swept, a live writer's is not: \(staging)")
var failed = item(.link, url: "https://e.com")
failed.state = .failed
failed.lastError = ShareOutcome.unreachableCode
failed.attempts = 4
expect(ShareInboxPolicy.retriesAutomatically(failed), "unreachable, 4 attempts: retried on the next foreground")
failed.attempts = 5
expect(!ShareInboxPolicy.retriesAutomatically(failed), "after 5 automatic attempts, only by Retry")
failed.attempts = 1
failed.lastError = "Unsupported file type: .bin"
expect(!ShareInboxPolicy.retriesAutomatically(failed), "a refusal is never retried by itself")

print("== ShareURL")
func parse(_ s: String) -> ShareItem? { ShareURL.parse(URL(string: s)!, id: "u1", now: now) }
let ok = parse("latchkey://share?url=https%3A%2F%2Fexample.com%2Fa-XYZ&title=A")
expect(ok?.kind == .link && ok?.url == "https://example.com/a-XYZ" && ok?.title == "A" && ok?.source == .urlScheme,
       "accepts an https link with a title")
expect(parse("latchkey://share?url=http://example.com/")?.kind == .link, "accepts http")
expect(parse("latchkey://share?url=javascript:alert(1)") == nil, "refuses javascript:")
expect(parse("latchkey://share?url=javascript://example.com/%250Aalert(1)") == nil,
       "refuses javascript: even with a host in it")
expect(parse("latchkey://share?url=data:text/html,hi") == nil, "refuses data:")
expect(parse("latchkey://share?url=file:///etc/passwd") == nil, "refuses file:")
expect(parse("latchkey://share?url=ftp://example.com/x") == nil, "refuses ftp:")
expect(parse("latchkey://share?url=https://") == nil, "refuses a link with no host")
expect(parse("latchkey://share?text=hello")?.kind == .text, "text alone is a text share")
expect(parse("latchkey://share") == nil && parse("latchkey://share?title=only") == nil,
       "nothing to share: refused")
expect(parse("latchkey://other?url=https://e.com") == nil && parse("https://share?url=https://e.com") == nil,
       "only latchkey://share")
let longURL = "https://e.com/" + String(repeating: "a", count: ShareURL.maxURLBytes)
expect(parse("latchkey://share?url=\(longURL)") == nil, "a URL over 8 KB is refused")
let longTitle = String(repeating: "t", count: ShareURL.maxTitleBytes + 1)
expect(parse("latchkey://share?url=https://e.com&title=\(longTitle)") == nil, "a title over 1 KB is refused")
let okTitle = String(repeating: "t", count: ShareURL.maxTitleBytes)
expect(parse("latchkey://share?url=https://e.com&title=\(okTitle)") != nil, "a title of exactly 1 KB is taken")
let longText = String(repeating: "x", count: ShareURL.maxTextBytes + 1)
expect(parse("latchkey://share?text=\(longText)") == nil, "text over 64 KB is refused")
let steered = parse("latchkey://share?url=https://e.com&gateway=https://evil.ts.net&slot=obsidian&sid=x&autoSend=1")
let steeredJSON = String(data: (try? steered?.encoded()) ?? Data(), encoding: .utf8) ?? ""
expect(steered != nil && !steeredJSON.contains("evil") && !steeredJSON.contains("obsidian") && !steeredJSON.contains("autoSend"),
       "gateway=, slot=, sid= and autoSend= are ignored, never stored: \(steeredJSON)")

print("== ShareItem")
var full = ShareItem(id: "abc", kind: .document, url: nil, title: "T", text: nil, note: "n",
                     filename: "report.pdf", utType: "com.adobe.pdf", byteCount: 1234, createdAt: now,
                     source: .intent)
full.state = .failed
full.attempts = 2
full.lastError = "unreachable"
full.lastAttemptAt = now.addingTimeInterval(1.5)
let data = try! full.encoded()
expect(ShareItem.decode(data) == .item(full), "encode → decode is equal, dates to the sub-second")
var json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
json["somethingNew"] = ["x": 1]
expect(ShareItem.decode(try! JSONSerialization.data(withJSONObject: json)) == .item(full),
       "an unknown field is ignored")
json["version"] = 2
expect(ShareItem.decode(try! JSONSerialization.data(withJSONObject: json)) == .newerVersion(2),
       "version 2 is left alone, not misread")
var noSource = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
noSource.removeValue(forKey: "source")
expect(ShareItem.decode(try! JSONSerialization.data(withJSONObject: noSource)) == .unreadable,
       "an item without its source is unreadable, not guessed")
expect(String(data: data, encoding: .utf8)!.contains("\"source\":\"intent\""), "the source is written")
expect(ShareItem.decode(Data("not json".utf8)) == .unreadable, "garbage is unreadable")
expect(ShareItem.sanitisedFilename("my report (final).pdf") == "my_report__final_.pdf", "sanitised as the gateway does")
expect(ShareItem.sanitisedFilename("../../etc/passwd") == "_.._etc_passwd", "no path survives")
expect(ShareItem.sanitisedFilename("") == "file", "an empty name becomes file")
expect(full.fileExtension == ".pdf", "the extension, with its dot")
expect(item(.document, filename: "README").fileExtension == "", "no extension")

print(failures == 0 ? "share: all \(checks) checks passed" : "share: \(failures) of \(checks) FAILED")
if failures != 0 { exit(1) }
