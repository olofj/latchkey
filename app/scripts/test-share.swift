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
json["version"] = 3
expect(ShareItem.decode(try! JSONSerialization.data(withJSONObject: json)) == .newerVersion(3),
       "version 3 is left alone, not misread")
// F18 §7: version 2 adds `destination`; a version-1 item reads as unaddressed.
var v1 = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
v1["version"] = 1
v1.removeValue(forKey: "destination")
if case .item(let old) = ShareItem.decode(try! JSONSerialization.data(withJSONObject: v1)) {
    expect(old.destination == nil && old.version == 1, "a version-1 item decodes, with no destination")
} else {
    expect(false, "a version-1 item still decodes")
}
var addressed = full
addressed.destination = ShareDestination(origin: "https://gw.example.ts.net", slotKey: "obsidian",
                                         slotTitle: "Obsidian", chosenAt: now)
expect(ShareItem.decode(try! addressed.encoded()) == .item(addressed), "an addressed item (v2) round-trips")
expect(String(data: try! addressed.encoded(), encoding: .utf8)!.contains("\"version\":2"), "written as version 2")
expect(ShareOutcome.addressedSessionGone(title: "obsidian")
       == "The session you queued for, obsidian, isn't there any more — pick one.", "the addressed-gone line")
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

print("== ShareInbox on disk (stage 2: the group container, then the app's own)")
let tmp = FileManager.default.temporaryDirectory.appending(path: "share-inbox-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: tmp) }
let groupRoot = tmp.appending(path: "group/ShareInbox"), appRoot = tmp.appending(path: "app/ShareInbox")
expect(ShareInboxStore.locations(appSupport: tmp.appending(path: "app"), groupContainer: tmp.appending(path: "g"))
       .map(\.lastPathComponent) == ["ShareInbox", "ShareInbox"]
       && ShareInboxStore.locations(appSupport: tmp.appending(path: "app"), groupContainer: tmp.appending(path: "g"))[0]
          .path.contains("/g/Library/Application Support/"),
       "the group container comes first, under Library/Application Support")
expect(ShareInboxStore.locations(appSupport: tmp, groupContainer: nil).count == 1,
       "without the entitlement, the app's own container only")
let both = ShareInbox(roots: [groupRoot, appRoot])
let appOnly = ShareInboxStore(root: appRoot)
func disk(_ id: String, age: TimeInterval = 0) -> ShareItem {
    ShareItem(id: id, kind: .link, url: "https://e.com/\(id)", byteCount: 10,
              createdAt: Date().addingTimeInterval(-age), source: .extension)
}
// A write that fails partway (the payload cannot be copied) leaves no item:
// item.json is written last, in staging, and only a whole item is renamed in.
let broken = ShareItem(id: "broken", kind: .document, filename: "x.pdf", byteCount: 5,
                       createdAt: Date(), source: .extension)
let brokenInbox = ShareInboxStore(root: tmp.appending(path: "broken/ShareInbox"))
do {
    try brokenInbox.add(broken, payloadFile: tmp.appending(path: "does-not-exist.pdf"))
    expect(false, "a missing payload fails the add")
} catch {
    expect(brokenInbox.items().isEmpty, "a failed write leaves no item behind (item.json is last): \(brokenInbox.items().map(\.id))")
}
try! appOnly.add(disk("old-app", age: 60))                 // a stage-1 item, already waiting
try! both.add(disk("from-ext"))
expect(FileManager.default.fileExists(atPath: groupRoot.appending(path: "from-ext/item.json").path),
       "a write goes to the first location (the group container)")
expect(both.items().map(\.id) == ["old-app", "from-ext"], "reads span both, oldest first: \(both.items().map(\.id))")
expect(both.summary().count == 2, "the summary counts both")
var moved = both.items()[0]
moved.state = .failed
try! both.update(moved)
expect(appOnly.items().first?.state == .failed, "an update lands where the item is")
both.delete("old-app")
expect(both.items().map(\.id) == ["from-ext"], "a delete finds the item wherever it is")
for i in 0..<19 { try! appOnly.add(disk("fill-\(i)")) }
do {
    try both.add(disk("twenty-first"))
    expect(false, "the cap counts both locations: a 21st item is refused")
} catch {
    expect((error as? ShareInboxStore.AddError) == .refused(.inboxFull(waiting: 20)),
           "the cap counts both locations: \(error)")
}
// Half-written items are invisible: a staged dir, and a dir with a payload but no item.json.
try! FileManager.default.createDirectory(at: groupRoot.appending(path: ".staging/half"), withIntermediateDirectories: true)
try! Data("{}".utf8).write(to: groupRoot.appending(path: ".staging/half/item.json"))
try! FileManager.default.createDirectory(at: groupRoot.appending(path: "nojson"), withIntermediateDirectories: true)
try! Data("%PDF-".utf8).write(to: groupRoot.appending(path: "nojson/payload"))
expect(!both.items().contains { ["half", "nojson"].contains($0.id) } && both.summary().count == 20,
       "an item without item.json, or still in .staging, does not exist")
// A real add leaves nothing in .staging.
let stagingLeft = (try? FileManager.default.contentsOfDirectory(atPath: appRoot.appending(path: ".staging").path)) ?? []
expect(stagingLeft.isEmpty, "a finished write leaves nothing staged: \(stagingLeft)")
try! appOnly.add(disk("ancient", age: 8 * 86400), waiting: (0, 0))
try! ShareInboxStore(root: groupRoot).add(disk("ancient-g", age: 8 * 86400), waiting: (0, 0))
expect(both.sweep(now: Date()) == 2 && !both.items().contains { $0.id.hasPrefix("ancient") },
       "the sweep takes 8-day items from both locations")

print("== ShareMirror (F18 §6.1)")
let slots: [[String: Any]] = [
    ["key": "obsidian", "title": "Obsidian", "surface": "", "folder_id": "f1", "running": true,
     "queue_depth": 2, "last_activity_ts": 100.0],
    ["key": "notes", "title": "", "surface": "orchestrator", "last_activity_ts": 300],
    ["key": "member-x", "title": "Member", "surface": "", "last_activity_ts": 900],
    ["key": "crew1", "title": "Crew", "surface": "crew", "last_activity_ts": 800],
    ["title": "no key"],
]
let listed = ShareSession.list(from: slots, folders: ["f1": "Work"])
expect(listed.map(\.key) == ["notes", "obsidian"],
       "the sidebar's filter: no member-*, no crew surface, newest first: \(listed.map(\.key))")
expect(listed[1].folder == "Work" && listed[1].running && listed[1].queueDepth == 2,
       "folder name resolved, running and queue depth kept")
expect(listed[0].title == "notes", "an untitled session shows its key")

var m = ShareMirror()
m.record(origin: "https://a.ts.net", label: "a", sessions: listed, at: now)
m.record(origin: "https://b.ts.net", label: "b", sessions: [], at: now.addingTimeInterval(-3600))
expect(m.current == "https://b.ts.net" && m.gateways.map(\.label) == ["b", "a"],
       "the latest recording is current and first")
m.remember(origin: "https://a.ts.net", .init(slotKey: "notes", slotTitle: "notes", at: now))
m.record(origin: "https://a.ts.net", label: "a", sessions: listed, at: now.addingTimeInterval(10))
expect(m.gateway("https://a.ts.net")?.lastDestination?.slotKey == "notes",
       "a re-listing keeps the gateway's last destination")
expect(m.gateways.count == 2, "a re-listing replaces, never duplicates")
let mirrorData = try! m.encoded()
expect(ShareMirror.decode(mirrorData) == m, "encode → decode is equal")
let text = String(data: mirrorData, encoding: .utf8)!
expect(!text.contains("\"url\":") && !text.contains("\"note\":") && !text.contains("\"text\":")
       && !text.contains("token") && !text.contains("cookie"),
       "the mirror holds titles and folders only: \(text.prefix(200))")
var newer = try! JSONSerialization.jsonObject(with: mirrorData) as! [String: Any]
newer["version"] = 2
expect(ShareMirror.decode(try! JSONSerialization.data(withJSONObject: newer)) == nil,
       "a newer mirror is offered as nothing, not misread")
expect(ShareMirror.decode(Data("nope".utf8)) == nil, "garbage is nothing")
var pruned = m
expect(pruned.retain(origins: ["https://b.ts.net"]) && pruned.gateways.map(\.label) == ["b"] && pruned.current == nil,
       "a forgotten gateway's entry goes, and it is no longer current")
expect(m.retain(origins: ["https://a.ts.net"]) && m.gateways.map(\.label) == ["a"] && m.current == "https://a.ts.net",
       "the kept gateway stays current")
expect(!m.retain(origins: ["https://a.ts.net"]), "retaining what is there changes nothing")

// The staleness rule: 24 h, then the list is hidden and the reason said.
let fresh = now.addingTimeInterval(30)
expect(m.gateway("https://a.ts.net")?.isStale(now: fresh) == false, "10 s old is fresh")
expect(m.gateway("https://a.ts.net")?.isStale(now: now.addingTimeInterval(10 + 24 * 3600 - 1)) == false,
       "a second under 24 h is still fresh")
expect(m.gateway("https://a.ts.net")?.isStale(now: now.addingTimeInterval(10 + 24 * 3600 + 1)) == true,
       "a second over 24 h is stale")
expect(m.offered(now: fresh).map(\.label) == ["a"] && m.offered(now: now.addingTimeInterval(30 * 3600)).isEmpty,
       "a stale gateway is not offered")
expect(ShareMirror.emptyReason(m, now: fresh) == nil, "a fresh list with sessions needs no excuse")
expect(ShareMirror.emptyReason(nil, now: fresh) == "Open Latchkey once so it can list your sessions.",
       "no mirror yet")
expect(ShareMirror.emptyReason(ShareMirror(), now: fresh) == "Open Latchkey once so it can list your sessions.",
       "an empty mirror reads as none")
expect(ShareMirror.emptyReason(m, now: now.addingTimeInterval(10 + 30 * 3600))
       == "Latchkey's session list is 30 h old. Open Latchkey to refresh it.",
       "a stale list says how old: \(ShareMirror.emptyReason(m, now: now.addingTimeInterval(10 + 30 * 3600)) ?? "nil")")
var empty = ShareMirror()
empty.record(origin: "https://chonk.ts.net", label: "chonk", sessions: [], at: now)
expect(ShareMirror.emptyReason(empty, now: fresh) == "chonk has no sessions.", "a gateway with no sessions")
var mixed = empty
mixed.record(origin: "https://a.ts.net", label: "a", sessions: listed, at: now)
mixed.current = "https://chonk.ts.net"
expect(mixed.offered(now: fresh).map(\.label) == ["chonk", "a"], "the current gateway comes first")
expect(ShareMirror.emptyReason(mixed, now: fresh) == nil, "another gateway's sessions are enough")

print("== The share order and labels (issue #5)")
func sess(_ key: String, _ title: String, folder: String? = nil, at: Double) -> ShareSession {
    ShareSession(key: key, title: title, folder: folder, running: false, queueDepth: 0, lastActivity: at)
}
let aOrigin = "https://a.ts.net", bOrigin = "https://b.ts.net:8443"
var two = ShareMirror()
two.record(origin: bOrigin, label: "b", sessions: [sess("b1", "Beta", at: 50), sess("b2", "Bravo", at: 40)], at: now)
two.remember(origin: bOrigin, .init(slotKey: "b2", slotTitle: "Bravo", at: now))
// The foreground re-list of gateway a, after the share to b: a is current.
two.record(origin: aOrigin, label: "a",
           sessions: [sess("a1", "Alpha", at: 900), sess("a2", "Apple", at: 800)], at: now.addingTimeInterval(5))
let keysOf = { (m: ShareMirror) in m.offers(now: fresh).map { "\($0.session.key)" } }
expect(two.current == aOrigin, "the re-list made a current")
expect(keysOf(two) == ["b2", "a1", "a2", "b1"],
       "the last share target first across gateways, then activity, not a's listing first: \(keysOf(two))")
expect(two.offers(now: fresh).filter(\.isLast).map(\.session.key) == ["b2"], "one last-time row")
two.remember(origin: aOrigin, .init(slotKey: "a2", slotTitle: "Apple", at: now.addingTimeInterval(20)))
two.remember(origin: bOrigin, .init(slotKey: "b1", slotTitle: "Beta", at: now.addingTimeInterval(10)))
expect(keysOf(two) == ["a2", "b1", "b2", "a1"], "most recent share first, the older ones after it: \(keysOf(two))")
expect(two.offers(now: fresh).filter(\.isLast).map(\.session.key) == ["a2"],
       "still one last-time row with a last destination on each gateway")
two.record(origin: bOrigin, label: "b", sessions: [sess("b1", "Beta", at: 50)], at: now.addingTimeInterval(30))
expect(two.gateway(bOrigin)?.sharedAt == ["b1": now.addingTimeInterval(10)],
       "a session that went is pruned from the share times: \(two.gateway(bOrigin)?.sharedAt ?? [:])")
// A mirror written before the share times: its last destination still leads.
var old = ShareMirror()
old.gateways = [ShareMirror.Gateway(origin: aOrigin, label: "a", fetchedAt: now,
                                    sessions: [sess("a1", "Alpha", at: 900), sess("a2", "Apple", at: 800)],
                                    lastDestination: .init(slotKey: "a2", slotTitle: "Apple", at: now))]
var oldJSON = try! JSONSerialization.jsonObject(with: try! old.encoded()) as! [String: Any]
var oldGateways = oldJSON["gateways"] as! [[String: Any]]
oldGateways[0].removeValue(forKey: "sharedAt")
oldJSON["gateways"] = oldGateways
let oldDecoded = ShareMirror.decode(try! JSONSerialization.data(withJSONObject: oldJSON))
expect(oldDecoded.map(keysOf) == ["a2", "a1"], "a mirror without share times decodes and orders by its last destination")
expect(ShareSession.shareOrdered([sess("x", "X", at: 3), sess("y", "Y", at: 2), sess("z", "Z", at: 1)]) {
           ["z": now, "y": now.addingTimeInterval(-60)][$0] }.map(\.key) == ["z", "y", "x"],
       "the picker's order: shared to, most recent first, then the listing's own order")
// Labels: the host with its port when several gateways are offered, and the
// key when a title and folder repeat on one gateway.
expect(ShareMirror.hostLabel(origin: bOrigin) == "b.ts.net:8443" && ShareMirror.hostLabel(origin: aOrigin) == "a.ts.net",
       "the port is named when the origin has one")
var twins = ShareMirror()
twins.record(origin: aOrigin, label: "a", sessions: [sess("k1", "Inbox", folder: "Notes", at: 3),
                                                     sess("k2", "Inbox", folder: "Notes", at: 2),
                                                     sess("k3", "Inbox", folder: "Work", at: 1)], at: now)
let twinOffers = twins.offers(now: fresh)
expect(twinOffers.filter(\.namesKey).map(\.session.key) == ["k1", "k2"] && !twinOffers.contains(where: \.namesGateway),
       "same title and folder name their keys; a different folder is enough; one gateway is not named")
expect(two.offers(now: fresh).allSatisfy(\.namesGateway), "several gateways: every row names its host")

// On disk: the group container when there is one, else the app's own;
// atomic, and gone with the test reset.
let mirrorTmp = FileManager.default.temporaryDirectory.appending(path: "share-mirror-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: mirrorTmp) }
expect(ShareMirrorStore.location(appSupport: mirrorTmp.appending(path: "app"), groupContainer: mirrorTmp.appending(path: "g"))
       .path.hasSuffix("/g/Library/Application Support/ShareMirror/mirror.json"), "the group container's file")
expect(ShareMirrorStore.location(appSupport: mirrorTmp.appending(path: "app"), groupContainer: nil)
       .path.hasSuffix("/app/ShareMirror/mirror.json"), "the app's own without the entitlement")
let mirrorStore = ShareMirrorStore(file: ShareMirrorStore.location(appSupport: mirrorTmp, groupContainer: nil))
expect(mirrorStore.load() == nil, "nothing on disk reads as no mirror")
mirrorStore.update { $0.record(origin: "https://a.ts.net", label: "a", sessions: listed, at: now) }
expect(mirrorStore.load()?.gateways.first?.sessions.map(\.key) == ["notes", "obsidian"], "written and read back")
let stamp = try? FileManager.default.attributesOfItem(atPath: mirrorStore.file.path)[.modificationDate] as? Date
mirrorStore.update { $0.retain(origins: ["https://a.ts.net"]) }
let stamp2 = try? FileManager.default.attributesOfItem(atPath: mirrorStore.file.path)[.modificationDate] as? Date
expect(stamp == stamp2, "an update that changes nothing writes nothing")
mirrorStore.removeAll()
expect(mirrorStore.load() == nil && !FileManager.default.fileExists(atPath: mirrorStore.file.deletingLastPathComponent().path),
       "the reset removes the directory")

print(failures == 0 ? "share: all \(checks) checks passed" : "share: \(failures) of \(checks) FAILED")
if failures != 0 { exit(1) }
