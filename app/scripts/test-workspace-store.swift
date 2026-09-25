// Host tests for App/Workspace/WorkspaceStore.swift: what the app decides
// when workspaces.json is missing, damaged or merely old.
//
// The defect this exists to prevent: load() answered nil both for "no file"
// and for "a file that does not decode", and the manager treated nil as a
// first launch — it minted a new default workspace and saved over the file.
// The previous Workspaces/<id>/state directory, the tsnet node's identity,
// was orphaned with no log line; recovery costs a fresh tailnet login,
// tailnet-lock re-signing and new grants. Nothing in today's file triggers
// it; the next non-optional field anyone adds to WorkspaceDefinition does,
// on the first launch after the upgrade.
//
// Each row is one document. The assertion is the DECISION — freshStart /
// keep / preserve — not merely that decoding throws, and every row also
// drives save() at the file afterwards: a preserved file must be byte-for-
// byte untouched; a rejected entry's original must be kept in a copy.
//
// Everything happens in a mktemp directory. The store's own appSupportDir is
// never evaluated (load(from:)/save(to:) take explicit URLs), and the last
// check fails if a Latchkey directory appeared under this user's Application
// Support anyway.
import Foundation

let A = "11111111-1111-4111-8111-111111111111"
let B = "22222222-2222-4222-8222-222222222222"
let C = "33333333-3333-4333-8333-333333333333"
let DS = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"

/// A complete entry as today's build writes it, keyed so rows can drop or
/// override single fields.
let fullEntry: [(String, String)] = [
    ("id", "\"\(A)\""),
    ("displayName", "\"Latchkey\""),
    ("hostname", "\"latchkey-iphone\""),
    ("homePageURL", "\"https://gw.example.ts.net\""),
    ("controlURL", "\"https://controlplane.tailscale.com\""),
    ("ephemeral", "false"),
    ("dataStoreUUID", "\"\(DS)\""),
    ("lastKnownIdentity", "{\"loginName\":\"someone@example.com\",\"hostname\":\"latchkey-iphone\"}"),
    ("hasEverConnected", "true"),
]

func entry(id: String? = A, without: Set<String> = [], set: [String: String] = [:],
           extra: [(String, String)] = []) -> String {
    var fields = fullEntry.filter { !without.contains($0.0) }
    if let id { fields[0] = ("id", "\"\(id)\"") } else { fields.removeFirst() }
    fields = fields.map { (k, v) in (k, set[k] ?? v) }
    fields += extra
    return "{" + fields.map { "\"\($0.0)\": \($0.1)" }.joined(separator: ", ") + "}"
}

func doc(_ entries: [String], activeId: String? = "\"\(A)\"", extraTop: String = "") -> String {
    var top = "\"workspaces\": [" + entries.joined(separator: ", ") + "]"
    if let activeId { top += ", \"activeId\": \(activeId)" }
    if !extraTop.isEmpty { top += ", " + extraTop }
    return "{" + top + "}"
}

/// A row: the document, the decision it must produce, and any further
/// checks on the outcome (each string returned is a failure).
struct Row {
    let name: String
    let bytes: Data?          // nil: no file
    let want: WorkspaceStore.Decision
    let check: (WorkspaceStore.LoadOutcome) -> [String]
    /// Set up something a byte string cannot express (a directory, no
    /// read permission). Returns a cleanup to run before comparing bytes.
    let special: ((URL) -> () -> Void)?

    init(_ name: String, _ text: String?, _ want: WorkspaceStore.Decision,
         special: ((URL) -> () -> Void)? = nil,
         check: @escaping (WorkspaceStore.LoadOutcome) -> [String] = { _ in [] }) {
        self.name = name
        self.bytes = text.map { Data($0.utf8) }
        self.want = want
        self.check = check
        self.special = special
    }
}

/// Checks on the one entry a `keep` outcome holds.
func single(_ body: @escaping (WorkspaceDefinition, UUID?, [String]) -> [String]) -> (WorkspaceStore.LoadOutcome) -> [String] {
    return { outcome in
        guard case .loaded(let ws, let active, let repairs, _) = outcome, ws.count == 1 else {
            return ["expected exactly one loaded workspace"]
        }
        return body(ws[0], active, repairs)
    }
}

let complete = doc([entry()])
let rows: [Row] = [
    // Successes.
    Row("no file", nil, .freshStart),
    Row("complete entry, every field", complete, .keep(workspaces: 1, rejected: 0),
        check: single { d, active, repairs in
            var out: [String] = []
            if d.id.uuidString != A { out.append("id: \(d.id)") }
            if d.hostname != "latchkey-iphone" { out.append("hostname: \(d.hostname)") }
            if d.homePageURL != "https://gw.example.ts.net" { out.append("homePageURL: \(d.homePageURL)") }
            if d.dataStoreUUID.uuidString != DS { out.append("dataStoreUUID: \(d.dataStoreUUID)") }
            if d.lastKnownIdentity?.loginName != "someone@example.com" { out.append("lastKnownIdentity lost") }
            if !d.hasEverConnected { out.append("hasEverConnected lost") }
            if active?.uuidString != A { out.append("activeId: \(String(describing: active))") }
            if !repairs.isEmpty { out.append("nothing should need repair: \(repairs)") }
            return out
        }),
    Row("unknown extra keys, top level and entry (a newer build's file)",
        doc([entry(extra: [("knownGateways", "[\"https://gw.example.ts.net\"]"), ("allowWidgetCDNs", "true")])],
            extraTop: "\"schema\": 2"),
        .keep(workspaces: 1, rejected: 0)),
    Row("activeId absent", doc([entry()], activeId: nil), .keep(workspaces: 1, rejected: 0),
        check: single { _, active, _ in active == nil ? [] : ["activeId should be nil"] }),
    Row("lastKnownIdentity absent", doc([entry(without: ["lastKnownIdentity"])]), .keep(workspaces: 1, rejected: 0),
        check: single { d, _, _ in d.lastKnownIdentity == nil ? [] : ["identity should be nil"] }),
    Row("lastKnownIdentity null", doc([entry(set: ["lastKnownIdentity": "null"])]), .keep(workspaces: 1, rejected: 0),
        check: single { d, _, _ in d.lastKnownIdentity == nil ? [] : ["identity should be nil"] }),

    // Absent or null non-essential fields: the reviewer's failing documents.
    Row("dataStoreUUID absent", doc([entry(without: ["dataStoreUUID"])]), .keep(workspaces: 1, rejected: 0),
        check: single { d, _, repairs in
            var out: [String] = []
            if d.id.uuidString != A { out.append("the node's id must survive: \(d.id)") }
            if d.dataStoreUUID.uuidString == A { out.append("a fresh store, not the node's id") }
            if !repairs.contains(where: { $0.contains("dataStoreUUID") }) { out.append("the repair must be reported") }
            return out
        }),
    Row("ephemeral absent", doc([entry(without: ["ephemeral"])]), .keep(workspaces: 1, rejected: 0),
        check: single { d, _, repairs in
            var out: [String] = []
            if d.ephemeral { out.append("ephemeral must default to false: control deletes an ephemeral node that goes offline") }
            if !repairs.contains(where: { $0.contains("ephemeral") }) { out.append("the repair must be reported") }
            return out
        }),
    Row("ephemeral the wrong type (\"yes\")", doc([entry(set: ["ephemeral": "\"yes\""])]), .keep(workspaces: 1, rejected: 0),
        check: single { d, _, _ in d.ephemeral ? ["must default to false"] : [] }),
    Row("controlURL absent", doc([entry(without: ["controlURL"])]), .keep(workspaces: 1, rejected: 0),
        check: single { d, _, _ in d.controlURL == kDefaultControlURL ? [] : ["controlURL: \(d.controlURL)"] }),
    Row("homePageURL null", doc([entry(set: ["homePageURL": "null"])]), .keep(workspaces: 1, rejected: 0),
        check: single { d, _, _ in d.homePageURL == HomePage.defaultURL ? [] : ["homePageURL: \(d.homePageURL)"] }),
    Row("hostname absent", doc([entry(without: ["hostname"])]), .keep(workspaces: 1, rejected: 0),
        check: single { d, _, _ in d.hostname == WorkspaceDefinition.defaultHostName ? [] : ["hostname: \(d.hostname)"] }),
    Row("displayName absent", doc([entry(without: ["displayName"])]), .keep(workspaces: 1, rejected: 0),
        check: single { d, _, _ in d.displayName == WorkspaceDefinition.defaultDisplayName ? [] : ["displayName: \(d.displayName)"] }),
    Row("lastKnownIdentity the wrong type", doc([entry(set: ["lastKnownIdentity": "\"kiro\""])]), .keep(workspaces: 1, rejected: 0),
        check: single { d, _, _ in d.lastKnownIdentity == nil ? [] : ["identity should be nil"] }),
    Row("activeId the wrong type", doc([entry()], activeId: "7"), .keep(workspaces: 1, rejected: 0),
        check: single { _, active, _ in active == nil ? [] : ["activeId should be nil"] }),
    Row("id without hyphens", doc([entry(id: A.replacingOccurrences(of: "-", with: ""))]), .keep(workspaces: 1, rejected: 0),
        check: single { d, _, _ in d.id.uuidString == A ? [] : ["id: \(d.id)"] }),
    Row("id without hyphens, lower case", doc([entry(id: A.replacingOccurrences(of: "-", with: "").lowercased())]),
        .keep(workspaces: 1, rejected: 0),
        check: single { d, _, _ in d.id.uuidString == A ? [] : ["id: \(d.id)"] }),

    // F11 §5: hasEverConnected is absent from every file written before it
    // existed. Its default is the evidence — the entry's node state dir —
    // not false, or a returning user is introduced to the app again.
    Row("hasEverConnected absent, the node's state dir exists (an upgrade)",
        doc([entry(without: ["hasEverConnected"])]), .keep(workspaces: 1, rejected: 0),
        special: nodeStateDir(A),
        check: single { d, _, repairs in
            var out: [String] = []
            if !d.hasEverConnected { out.append("an install that has run before must not be re-introduced") }
            if !repairs.contains(where: { $0.contains("hasEverConnected") }) { out.append("the repair must be reported") }
            return out
        }),
    Row("hasEverConnected absent, no state dir", doc([entry(without: ["hasEverConnected"])]),
        .keep(workspaces: 1, rejected: 0),
        check: single { d, _, _ in d.hasEverConnected ? ["no node dir: nothing says this install has run"] : [] }),
    Row("hasEverConnected absent, another entry's state dir exists", doc([entry(without: ["hasEverConnected"])]),
        .keep(workspaces: 1, rejected: 0),
        special: nodeStateDir(B),
        check: single { d, _, _ in d.hasEverConnected ? ["the evidence is this entry's own dir"] : [] }),
    Row("hasEverConnected false, with a state dir", doc([entry(set: ["hasEverConnected": "false"])]),
        .keep(workspaces: 1, rejected: 0),
        special: nodeStateDir(A),
        check: single { d, _, repairs in
            var out: [String] = []
            if d.hasEverConnected { out.append("a stored false is kept; the dir is evidence only when the key is absent") }
            if !repairs.isEmpty { out.append("nothing to repair: \(repairs)") }
            return out
        }),

    // The list survives one bad entry.
    Row("one entry without an id among three", doc([entry(id: A), entry(id: nil), entry(id: C)]),
        .keep(workspaces: 2, rejected: 1),
        check: { outcome in
            guard case .loaded(let ws, _, _, let rejected) = outcome else { return ["not loaded"] }
            var out: [String] = []
            if ws.map(\.id.uuidString) != [A, C] { out.append("kept: \(ws.map(\.id.uuidString))") }
            if rejected.first?.contains("entry 1") != true { out.append("the rejection must name the entry: \(rejected)") }
            return out
        }),
    Row("one entry that is not an object among three", doc([entry(id: A), "\"junk\"", entry(id: C)]),
        .keep(workspaces: 2, rejected: 1)),
    Row("one entry with a garbage id among three", doc([entry(id: A), entry(id: "not-a-uuid"), entry(id: C)]),
        .keep(workspaces: 2, rejected: 1)),

    // Empty list: a decodable file with nothing in it is a fresh start.
    Row("empty list", doc([]), .freshStart),
    Row("empty list with a stale activeId", doc([], activeId: "\"\(B)\""), .freshStart),

    // Damaged files: preserve.
    Row("truncated mid-document", String(complete.prefix(complete.count / 2)), .preserve),
    Row("empty file (0 bytes)", "", .preserve),
    Row("not JSON", "hello\n", .preserve),
    Row("empty object {}", "{}", .preserve),
    Row("workspaces is null", "{\"workspaces\": null}", .preserve),
    Row("workspaces is not an array", "{\"workspaces\": \"x\"}", .preserve),
    Row("a top-level array", "[]", .preserve),
    Row("the only entry has no id", doc([entry(id: nil)]), .preserve),
    Row("the only entry's id is not a UUID", doc([entry(id: "latchkey")]), .preserve),
    Row("every one of three entries is unusable", doc([entry(id: nil), "1", entry(id: "?")]), .preserve),
    Row("a directory where the file should be", nil, .preserve,
        special: { url in
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return {}
        }),
    Row("a file the process may not read (mode 000)", complete, .preserve,
        special: { url in
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            return { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        }),
]

/// Creates `Workspaces/<id>/state` beside the file, as a previous build
/// leaves it.
func nodeStateDir(_ id: String) -> (URL) -> () -> Void {
    return { file in
        let dir = file.deletingLastPathComponent().appending(path: "Workspaces/\(id)/state")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return {}
    }
}

func siblings(of file: URL) -> [URL] {
    let dir = file.deletingLastPathComponent()
    let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return all.filter { $0.lastPathComponent.hasPrefix("workspaces.json.rejected-") }
}

// WorkspaceStore is @MainActor, as the whole app module is.
@MainActor
func runAll() {
var failures = 0
var failedRows: [String] = []
let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "workspace-store-tests-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.removeItem(at: root)
defer { try? FileManager.default.removeItem(at: root) }

let hostSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appending(path: "Latchkey")
let hostSupportExistedBefore = FileManager.default.fileExists(atPath: hostSupport.path)

let unreadableCasesNeedNonRoot = geteuid() == 0

print("== decisions, one document each")
for (n, row) in rows.enumerated() {
    if row.name.contains("mode 000"), unreadableCasesNeedNonRoot {
        print("  skip: \(row.name) (running as root)")
        continue
    }
    let dir = root.appending(path: "case-\(n)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appending(path: "workspaces.json")
    if let bytes = row.bytes { try! bytes.write(to: file) }
    let cleanup = row.special?(file) ?? {}

    var problems: [String] = []
    let outcome = WorkspaceStore.load(from: file)
    if outcome.decision != row.want {
        problems.append("decision \(outcome.decision), want \(row.want)")
        if case .unreadable(let reason) = outcome { problems.append("  (reason: \(reason))") }
    } else {
        problems += row.check(outcome)
    }

    // The write side of the same guarantee: what the manager would do next.
    let fresh = WorkspaceDefinition.makeDefault()
    let written = WorkspaceStore.save([fresh], activeId: fresh.id, to: file)
    cleanup()
    let after = try? Data(contentsOf: file)
    switch row.want {
    case .preserve:
        if written { problems.append("save() wrote over a file it could not read") }
        if row.bytes != nil, after != row.bytes { problems.append("the file's bytes changed") }
        if !siblings(of: file).isEmpty { problems.append("no copy should be made of a preserved file") }
    case .freshStart, .keep:
        if !written { problems.append("save() refused a writable file") }
        if case .loaded(let ws, _, _, let rejected) = WorkspaceStore.load(from: file),
           ws.map(\.id) == [fresh.id], rejected.isEmpty {
            // written and readable
        } else {
            problems.append("the saved file does not read back as the saved list")
        }
        let copies = siblings(of: file)
        if case .keep(_, let rejected) = row.want, rejected > 0 {
            if copies.count != 1 { problems.append("one copy of the original expected, found \(copies.count)") }
            else if (try? Data(contentsOf: copies[0])) != row.bytes { problems.append("the copy is not the original bytes") }
            // The next save finds a clean file: no second copy.
            WorkspaceStore.save([fresh], activeId: fresh.id, to: file)
            if siblings(of: file).count != 1 { problems.append("a second save must not copy again") }
        } else if !copies.isEmpty {
            problems.append("no copy expected, found \(copies.map(\.lastPathComponent))")
        }
    }

    if problems.isEmpty {
        print("  ok   \(row.name)")
    } else {
        failures += problems.count
        failedRows.append(row.name)
        print("  FAIL \(row.name)")
        for p in problems { print("       \(p)") }
    }
}

print("== the recovery workspace")
func expect(_ cond: Bool, _ what: String) {
    if cond { print("  ok   \(what)"); return }
    failures += 1
    failedRows.append(what)
    print("  FAIL \(what)")
}
let r1 = WorkspaceDefinition.makeRecovery(), r2 = WorkspaceDefinition.makeRecovery()
expect(r1.id == r2.id && r1.dataStoreUUID == r2.dataStoreUUID,
       "fixed ids: a sign-in made while degraded survives a relaunch")
expect(r1.id != WorkspaceDefinition.makeDefault().id, "not the default's random id")
expect(r1.hostname.hasSuffix("-recovery") && r1.hostname != WorkspaceDefinition.defaultHostName,
       "a distinct hostname, so it cannot take the real node's name: \(r1.hostname)")
expect(r1.id != r1.dataStoreUUID, "node dir and web store are different ids")

print("== round trip")
do {
    let dir = root.appending(path: "roundtrip")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appending(path: "workspaces.json")
    var d = WorkspaceDefinition.makeDefault()
    d.homePageURL = "https://gw.example.ts.net"
    d.lastKnownIdentity = WorkspaceIdentity(loginName: "someone@example.com", hostname: d.hostname)
    d.hasEverConnected = true
    let written = WorkspaceStore.save([d], activeId: d.id, to: file)
    guard case .loaded(let ws, let active, let repairs, let rejected) = WorkspaceStore.load(from: file), ws.count == 1 else {
        expect(false, "a file this build wrote reads back"); exit(1)
    }
    let back = ws[0]
    expect(written && back.id == d.id && back.dataStoreUUID == d.dataStoreUUID && back.hostname == d.hostname
           && back.homePageURL == d.homePageURL && back.controlURL == d.controlURL && back.ephemeral == d.ephemeral
           && back.lastKnownIdentity == d.lastKnownIdentity && back.hasEverConnected && active == d.id,
           "every field survives save → load")
    expect(repairs.isEmpty && rejected.isEmpty, "with nothing to repair: the keys written are the keys read")
}

print("== host safety")
expect(hostSupportExistedBefore || !FileManager.default.fileExists(atPath: hostSupport.path),
       "the test did not create \(hostSupport.path)")

if failures > 0 {
    print("\nFAILED: \(failures) problem(s) in \(failedRows.count) case(s):")
    for name in failedRows { print("  - \(name)") }
    exit(1)
}
print("\nworkspace store: all \(rows.count) documents decide correctly")
}

MainActor.assumeIsolated { runAll() }
