// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ShareDelivery.swift
//  Latchkey
//
//  Takes what was shared out of the inbox and delivers it to a session on
//  the gateway (F3 §4.5): list → pick → verify → upload → post → show.
//
//  Only the app delivers, only in the foreground, and only AS THE PAGE (F3
//  §4.4): every request is a page-world `fetch` in the app's content world,
//  so the cookies, the Origin, the split tunnel and ATS are the page's own
//  and no credential leaves WebKit (R32's line).
//
//  Ordering, which the L2 test exists to hold: nothing is asked of the
//  gateway until ALL of these are true -- the app is active, the workspace
//  has a gateway, the page's origin is that gateway, and the session layer
//  says `.active` (the page's own `/api/auth/me` answered 200). Never on
//  `scenePhase == .active` alone.
//
//  "Sent" is the gateway's word, never the app's: the result is shown only
//  after `POST /api/chat` answered, and "queued" is said as queued.
//
//  A slot key is posted only if it is in a list fetched moments before: the
//  gateway silently CREATES a session for an unknown key (F3 §4.5).
//
//  F18: an item may arrive ADDRESSED -- the session chosen in the Shortcut's
//  drop-down, from the mirror this class writes after every listing. Such an
//  item is a picker whose choice is already made: re-list, post if the key
//  is still there, else the picker with the "isn't there any more" line. The
//  Shortcut's background run (`performIntent`) does the same in this process
//  without a scene, and hands over to the foreground when it cannot finish.
//

import Combine
import Foundation
import SwiftUI
import TailscaleKit
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class ShareDelivery: ObservableObject {
    static let shared = ShareDelivery()

    enum Phase: Equatable {
        case idle
        /// Waiting for a precondition, said in words.
        case waiting(String)
        case listing
        case picking
        case working(String)
        case done(ShareOutcome)
    }

    /// Everything in the inbox this build can read, oldest first.
    @Published private(set) var waiting: [ShareItem] = []
    /// The item on the picker, if any.
    @Published private(set) var current: ShareItem?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var sessions: [ShareSession] = []
    @Published var selectedKey: String?
    @Published var note = ""
    /// A line above the list: the remembered session is gone, or the last
    /// share went to another gateway.
    @Published private(set) var notice: String?
    @Published private(set) var elsewhere: (origin: String, title: String)?
    /// The picker wants to be up. The host decides when it may be (one sheet
    /// at a time: Settings and the sign-in sheet come first).
    @Published var isPickerRequested = false
    /// The last outcome's label, for the test instrument (`share-last-result`)
    /// and Settings: counted, so a result that flashes by is not missed.
    @Published private(set) var lastResult = "none"
    /// How many items were admitted this launch (the test instrument).
    @Published private(set) var receivedCount = 0
    /// Whether the picker shows the gateway picker in its place.
    @Published var choosingGateway = false
    /// F18: the current item is addressed to this session (its title), so
    /// the sheet shows the send and no list. Nil once it needs a pick.
    @Published private(set) var addressedTitle: String?

    /// How long a foreground may wait for the page before the owner is told
    /// the gateway is unreachable (F3 §4.4).
    static let pageWait: Duration = .seconds(20)
    static let requestTimeout: Duration = .seconds(10)
    static let uploadTimeout: Duration = .seconds(180)
    /// Raw bytes per page-world call: 50 MB is 13 calls of ~5.6 MB strings.
    nonisolated static let chunkBytes = 4 * 1024 * 1024

    let store: ShareInbox
    let defaults: ShareDefaults
    /// F18 §6.1: what the Shortcut's drop-down reads.
    let mirror: ShareMirrorStore

    private weak var workspace: Workspace?
    private var observers: Set<AnyCancellable> = []
    /// Items the Shortcut's background run owns: `advance` leaves them be.
    private var held: Set<String> = []
    /// One cheap re-list per foreground, once the page is `.active` and no
    /// item is on the picker (F18 §6.1).
    private var mirrorRefreshDue = true
    private var mirrorRefreshTask: Task<Void, Never>?
    /// Set by the scene-phase change; SwiftUI reports `.active` before
    /// `UIApplication.applicationState` says so, and a foreground that read
    /// only the latter never brought up what the extension had saved.
    private var sceneActive = false
    /// A cold launch by the share URL reaches `.active` with no scene-phase
    /// change to hear, so the application state counts too.
    private var appActive: Bool {
#if canImport(UIKit)
        sceneActive || UIApplication.shared.applicationState == .active
#else
        true
#endif
    }
    /// The key the owner already chose, when a send stopped for sign-in: the
    /// send resumes by itself once the session is back (F3 §2).
    private var resumeKey: String?
    /// The key of the last send, for Retry.
    private var lastKey: String?
    private var pageWaitTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    /// Items put aside for this foreground (Later): they come back on the next.
    private var deferred: Set<String> = []
    /// Failed items already retried automatically in this foreground.
    private var retriedThisForeground: Set<String> = []
    /// Items whose `POST /api/chat` has left and not yet answered. The
    /// gateway may already have them, so Later cannot take them back: the
    /// send runs on and its answer is recorded, and until then they are not
    /// offered again (issue #1).
    private var posting: Set<String> = []

    private init() {
        let appSupport = WorkspaceStore.appSupportDir
        store = ShareInbox.app(appSupport: appSupport)
        defaults = ShareDefaults(file: appSupport.appending(path: "share-defaults.json"))
        mirror = ShareMirrorStore.app(appSupport: appSupport)
#if LATCHKEY_TEST_HOOKS
        let intentSeed = ShareTestHooks.apply(store: store, defaults: defaults, mirror: mirror) { [weak self] in
            self?.receivedCount += 1
        }
#endif
        try? store.prepare()
        let swept = store.sweep(now: Date())
        logger.log("Share: inbox in \(store.hasGroup ? "the App Group container and the app's own" : "the app's own container only (no App Group)")")
        if swept > 0 {
            AppDiagnostics.shared.sharesSwept += swept
        }
        // Always, so "no sweep" and "swept nothing" read differently.
        logger.log("Share: swept \(swept) item(s)")
        reload()
#if LATCHKEY_TEST_HOOKS
        // -UITestIntentDeliver: the seeded item goes the Shortcut's way,
        // in this process, as the intent's background run would take it.
        if let seed = intentSeed {
            Task { [weak self] in
                guard let self else { return }
                let outcome = await self.performIntent(seed.item, to: seed.destination, payloadFile: seed.payload)
                try? FileManager.default.removeItem(at: seed.payload)
                if case .needsForeground = outcome { self.fallBackToForeground() }
            }
        }
#endif
    }

    // MARK: - Entry points

    /// `latchkey://share?…` (F3 §4.2). Links and text only; no destination
    /// is ever taken from the URL.
    func receive(url: URL) {
        guard let item = ShareURL.parse(url, id: UUID().uuidString, now: Date()) else {
            logger.log("Share: ignored a share URL that breaks the rules (scheme, size or content)")
            return
        }
        admit(item)
    }

    /// Adds an item from any entry point in the app process. Returns the
    /// refusal's sentence, if refused.
    @discardableResult
    func admit(_ item: ShareItem, payloadFile: URL? = nil, payloadData: Data? = nil) -> String? {
        do {
            let advisory = try store.add(item, payloadFile: payloadFile, payloadData: payloadData)
            receivedCount += 1
            AppDiagnostics.shared.sharesReceived += 1
            logger.log("Share: received \(item.id) (\(item.kind.rawValue), \(item.byteCount) B) via \(item.source.rawValue)\(advisory == nil ? "" : "; the gateway may refuse \(item.fileExtension)")")
            reload()
            advance()
            return nil
        } catch ShareInboxStore.AddError.refused(let refusal) {
            logger.log("Share: refused \(item.id) at capture: \(Self.describe(refusal))")
            return ShareInboxPolicy.sentence(for: refusal)
        } catch {
            logger.log("Share: could not store \(item.id): \(error)")
            return "Couldn't save the share on this phone."
        }
    }

    nonisolated static func describe(_ refusal: ShareInboxPolicy.Refusal) -> String {
        switch refusal {
        case .tooLarge: return "over 50 MB"
        case .inboxFull(let n): return "inbox full (\(n) waiting)"
        }
    }

    // MARK: - Lifecycle

    /// The dashboard for `workspace` is on screen. Called again whenever the
    /// workspace changes.
    func attach(_ workspace: Workspace) {
        guard self.workspace !== workspace else { return }
        self.workspace = workspace
        observers.removeAll()
        workspace.session.$state
            .removeDuplicates()
            .sink { [weak self] _ in
                // After the change is published, not while it is. A cold
                // launch attaches before the app is active and before the
                // page is signed in; this is the moment a waiting item can
                // come up.
                Task { @MainActor in
                    guard let self else { return }
                    if self.current == nil { self.advance() } else { self.preconditionsChanged() }
                    self.refreshMirrorIfDue()
                }
            }
            .store(in: &observers)
        workspace.homePage.$url
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.preconditionsChanged() } }
            .store(in: &observers)
        // F18 §6.1: a gateway's mirror entry goes with the gateway.
        workspace.$definition
            .map(\.knownGatewayOrigins)
            .removeDuplicates()
            .sink { [weak self] origins in
                Task { @MainActor in self?.mirror.update { $0.retain(origins: origins) } }
            }
            .store(in: &observers)
        advance()
    }

    func sceneBecameActive() {
        sceneActive = true
        deferred.removeAll()
        retriedThisForeground.removeAll()
        mirrorRefreshDue = true
        reload()
        if current != nil { preconditionsChanged() } else { advance() }
        refreshMirrorIfDue()
    }

    func sceneLeftForeground() {
        sceneActive = false
        pageWaitTask?.cancel()
        pageWaitTask = nil
    }

    // MARK: - The queue

    func reload() {
        waiting = store.items()
    }

    /// Brings up the next item, if nothing is on the picker.
    func advance() {
        guard current == nil, appActive else { return }
        guard let next = waiting.first(where: { item in
            guard !deferred.contains(item.id), !posting.contains(item.id), !held.contains(item.id) else { return false }
            if item.state == .failed {
                return ShareInboxPolicy.retriesAutomatically(item) && !retriedThisForeground.contains(item.id)
            }
            return true
        }) else { return }
        if next.state == .failed { retriedThisForeground.insert(next.id) }
        present(next)
    }

    private func present(_ item: ShareItem) {
        current = item
        note = item.note ?? ""
        sessions = []
        selectedKey = nil
        notice = nil
        elsewhere = nil
        choosingGateway = false
        lastKey = nil
        addressedTitle = item.destination.map { $0.slotTitle ?? $0.slotKey }
        phase = .waiting("Connecting to the gateway…")
        isPickerRequested = true
        preconditionsChanged()
    }

    /// The key an addressed item goes to on THIS gateway, or nil for the
    /// picker (unaddressed, or addressed to another gateway).
    private func addressedKey(_ item: ShareItem) -> String? {
        guard let d = item.destination, let origin = gatewayOrigin, d.origin == origin else { return nil }
        return d.slotKey
    }

    /// "1 of 3".
    var position: (index: Int, total: Int) {
        let total = max(waiting.count, 1)
        let index = (current.flatMap { c in waiting.firstIndex { $0.id == c.id } } ?? 0) + 1
        return (min(index, total), total)
    }

    // MARK: - Preconditions (F3 §4.4, "Ordering")

    private var gatewayOrigin: String? {
        guard let workspace, workspace.homePage.hasGateway else { return nil }
        return GatewayAddress.origin(of: workspace.homePage.url)
    }

    private var page: BrowserViewModel? { workspace?.tabManager.currentTab?.viewModel }

    /// What delivery is waiting for, or nil when it may talk to the gateway.
    private var blocker: String? {
        guard appActive else { return "Waiting for Latchkey to be in front." }
        return pageBlocker
    }

    /// The page's part of `blocker`: what the Shortcut's background run
    /// waits for, since it never has the app in front.
    private var pageBlocker: String? {
        guard let workspace, let origin = gatewayOrigin else { return "Choose a gateway first." }
        guard let pageOrigin = page?.sessionOrigin?.absoluteString,
              GatewayAddress.origin(of: pageOrigin) == origin else { return "Waiting for the gateway…" }
        switch workspace.session.state {
        case .active: return nil
        case .needsToken: return "Waiting for sign-in."
        case .unknown: return "Waiting for the gateway…"
        }
    }

    private func preconditionsChanged() {
        guard current != nil else { return }
        switch phase {
        case .waiting, .done(.signedOut):
            break
        default:
            return
        }
        if let blocker {
            phase = .waiting(blocker)
            if workspace?.session.state != .needsToken { startPageWait() } else { pageWaitTask?.cancel() }
            return
        }
        pageWaitTask?.cancel()
        if let key = resumeKey {
            // The owner already pressed Send; sign-in was all it waited for.
            resumeKey = nil
            logger.log("Share: signed in again; resuming \(current?.id ?? "?")")
            send(to: key)
        } else if let item = current, let key = addressedKey(item) {
            // F18 §6.2: the choice is made. `deliver` re-lists and posts
            // only if the key is still there; else the picker comes up.
            logger.log("Share: \(item.id) is addressed to \(key); sending without the picker")
            send(to: key)
        } else {
            addressedTitle = nil
            list()
        }
    }

    private func startPageWait() {
        guard pageWaitTask == nil || pageWaitTask?.isCancelled == true else { return }
        pageWaitTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pageWait)
            guard !Task.isCancelled, let self else { return }
            self.pageWaitTask = nil
            guard case .waiting = self.phase, self.blocker != nil,
                  self.workspace?.session.state != .needsToken else { return }
            self.finish(.unreachable, key: nil)
        }
    }

    // MARK: - List (step 1)

    private func list() {
        guard let item = current, let origin = gatewayOrigin else { return }
        phase = .listing
        runTask?.cancel()
        runTask = Task { [weak self] in
            guard let self else { return }
            switch await self.fetchSessions(shareId: item.id) {
            case .failure(let failure):
                self.finish(failure.outcome, key: nil)
            case .success(let fetched):
                let listed = self.shareOrdered(fetched, origin: origin)
                self.sessions = listed
                let host = ShareMirror.hostLabel(origin: origin)
                logger.log("Share: listed \(listed.count) session(s) on \(host)")
                self.writeMirror(origin: origin, sessions: listed)
                let remembered = self.defaults.lastDestination(origin: origin)
                if let remembered, listed.contains(where: { $0.key == remembered.slotKey }) {
                    self.selectedKey = remembered.slotKey
                } else if remembered != nil {
                    self.selectedKey = nil
                    self.notice = ShareOutcome.sessionGone.sentence
                }
                if let other = self.defaults.newerElsewhere(than: origin) {
                    self.elsewhere = (other.origin, other.destination.slotTitle ?? other.destination.slotKey)
                }
                self.phase = .picking
            }
        }
    }

    struct Failure: Error { let outcome: ShareOutcome }

    /// `shareId` is the `X-Latchkey-Share` header: the item's id, or
    /// `mirror` for the foreground re-list.
    private func fetchSessions(shareId: String) async -> Result<[ShareSession], Failure> {
        let slots = await call("/api/chat/slots", method: "GET", shareId: shareId)
        if let failure = ShareOutcome.failure(slots) { return .failure(Failure(outcome: failure)) }
        guard let array = (try? JSONSerialization.jsonObject(with: Data(slots.body.utf8))) as? [[String: Any]] else {
            return .failure(Failure(outcome: .refused(status: slots.status ?? 0, text: "The gateway's session list could not be read.")))
        }
        // Folder names are a nicety: a failure here costs the names only.
        let folders = await call("/api/chat/folders", method: "GET", shareId: shareId)
        var folderNames: [String: String] = [:]
        if ShareOutcome.failure(folders) == nil,
           let list = (try? JSONSerialization.jsonObject(with: Data(folders.body.utf8))) as? [[String: Any]] {
            for f in list {
                if let id = f["id"] as? String, let name = f["name"] as? String { folderNames[id] = name }
            }
        }
        return .success(ShareSession.list(from: array, folders: folderNames))
    }

    // MARK: - The mirror (F18 §6.1)

    /// The picker's order (issue #5): last shared to first, from the
    /// mirror's share times, the remembered destination standing in for a
    /// gateway the mirror has not seen shared to; then gateway activity.
    private func shareOrdered(_ sessions: [ShareSession], origin: String) -> [ShareSession] {
        let known = mirror.load()?.gateway(origin)
        let remembered = defaults.lastDestination(origin: origin)
        return ShareSession.shareOrdered(sessions) { key in
            known?.sharedAt(key) ?? (remembered?.slotKey == key ? remembered?.at : nil)
        }
    }

    /// After every successful listing: the titles and folders the Shortcut's
    /// drop-down offers, and the last destination beside them.
    private func writeMirror(origin: String, sessions: [ShareSession]) {
        let label = ShareMirror.hostLabel(origin: origin)
        let last = defaults.lastDestination(origin: origin)
        mirror.update { m in
            m.record(origin: origin, label: label, sessions: sessions, at: Date())
            if let last { m.remember(origin: origin, .init(slotKey: last.slotKey, slotTitle: last.slotTitle, at: last.at)) }
        }
    }

    /// The one extra request per foreground: a re-list once the page is
    /// active, unless an item is up (its own listing writes the mirror). A
    /// refusal here is logged and nothing more -- it is not the owner's
    /// share, so it asks for no sign-in.
    private func refreshMirrorIfDue() {
        guard mirrorRefreshDue, current == nil, blocker == nil, let origin = gatewayOrigin,
              mirrorRefreshTask == nil else { return }
        mirrorRefreshDue = false
        mirrorRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.mirrorRefreshTask = nil }
            switch await self.fetchSessions(shareId: "mirror") {
            case .success(let listed):
                self.writeMirror(origin: origin, sessions: listed)
                logger.log("Share: mirror refreshed: \(listed.count) session(s) on \(URL(string: origin)?.host ?? origin)")
            case .failure(let f):
                logger.log("Share: mirror not refreshed: \(Self.logReason(f.outcome))")
            }
        }
    }

    // MARK: - Send (steps 3-7)

    func sendSelected() {
        guard let key = selectedKey, sessions.contains(where: { $0.key == key }) else { return }
        send(to: key)
    }

    private func send(to key: String) {
        guard let item = current else { return }
        lastKey = key
        notice = nil
        let noteText = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var sending = item
        sending.note = noteText.isEmpty ? nil : noteText
        sending.state = .sending
        sending.lastAttemptAt = Date()
        try? store.update(sending)
        current = sending
        runTask?.cancel()
        runTask = Task { [weak self] in
            guard let self, let outcome = await self.deliver(sending, to: key) else { return }
            let posted = self.posting.remove(sending.id) != nil
            if self.current?.id == sending.id, !Task.isCancelled {
                self.finish(outcome, key: key)
            } else if posted {
                // Later, or the sheet swiped away, after the post left.
                self.settle(outcome, item: sending)
            }
        }
    }

    /// The outcome, or nil when Later stopped the send before anything was
    /// posted. Up to the post, Later cancels; from the post on, it cannot:
    /// `callAsyncJavaScript` runs to its end whatever happens to the task.
    private func deliver(_ item: ShareItem, to key: String) async -> ShareOutcome? {
        // 3. verify: the key must be in a list fetched just now.
        phase = .working("Checking the session")
        let verified = await fetchSessions(shareId: item.id)
        guard !Task.isCancelled else { return nil }
        switch verified {
        case .failure(let f):
            return f.outcome
        case .success(let fresh):
            if let origin = gatewayOrigin {
                sessions = shareOrdered(fresh, origin: origin)
                writeMirror(origin: origin, sessions: fresh)
            } else {
                sessions = fresh
            }
            guard fresh.contains(where: { $0.key == key }) else { return .sessionGone }
        }
        // 4. upload.
        var uploadedPath: String?
        if item.kind == .document {
            switch await upload(item) {
            case .success(let path): uploadedPath = path
            case .failure(let f): return f.outcome
            }
        }
        // 5. post. No suspension between the check and the insert, so
        // close() sees either a send it may stop or one it must leave be.
        guard !Task.isCancelled else { return nil }
        posting.insert(item.id)
        phase = .working("Sending")
        let message = ShareMessage.compose(item, uploadedPath: uploadedPath)
        let body = (try? JSONSerialization.data(withJSONObject: ["message": message, "slot": key]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let response = await call("/api/chat?ws=1", method: "POST", body: body, item: item)
        return ShareOutcome.post(response, slot: key)
    }

    private func upload(_ item: ShareItem) async -> Result<String, ShareOutcome.UploadFailure> {
        let url = store.payloadURL(item.id)
        let total = Int((item.byteCount + Int64(Self.chunkBytes) - 1) / Int64(Self.chunkBytes))
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure(.init(outcome: .refused(status: 0, text: "The shared file is missing on this phone.")))
        }
        defer { try? handle.close() }
        var index = 0
        while true {
            let chunk: Data? = await Task.detached { try? handle.read(upToCount: Self.chunkBytes) }.value
            guard let chunk, !chunk.isEmpty else { break }
            // Later: the rest is not staged, and the phase is no longer ours.
            guard !Task.isCancelled else { return .failure(.init(outcome: .uploadInterrupted(done: index, of: total))) }
            phase = .working("Uploading \(index + 1) of \(max(total, index + 1))")
            let encoded = await Task.detached { chunk.base64EncodedString() }.value
            let staged = await page?.shareCall(PageScriptSources.shareStageChunk,
                                               arguments: ["id": item.id, "index": index, "chunk": encoded])
            guard (staged as? NSNumber)?.intValue == index + 1 else {
                return .failure(.init(outcome: .uploadInterrupted(done: index, of: max(total, index + 1))))
            }
            index += 1
        }
        let result = await page?.shareCall(PageScriptSources.shareUpload,
                                           arguments: ["id": item.id, "filename": item.filename ?? "file",
                                                       "parts": index,
                                                       "timeoutMs": Int(Self.uploadTimeout.components.seconds) * 1000])
        let response = Self.response(result)
        if response.status == -1 {
            return .failure(.init(outcome: .uploadInterrupted(done: index, of: max(total, index))))
        }
        let outcome = ShareOutcome.upload(response)
        if case .success = outcome {
            logger.log("Share: uploaded \(item.id) (\(item.byteCount) B) as \(item.fileExtension.isEmpty ? "(none)" : item.fileExtension)")
        }
        return outcome
    }

    private func call(_ path: String, method: String, body: String? = nil, item: ShareItem) async -> ShareOutcome.Response {
        await call(path, method: method, body: body, shareId: item.id)
    }

    private func call(_ path: String, method: String, body: String? = nil, shareId: String) async -> ShareOutcome.Response {
        var args: [String: Any] = ["path": path, "method": method, "shareId": shareId,
                                   "timeoutMs": Int(Self.requestTimeout.components.seconds) * 1000]
        args["body"] = body ?? NSNull()
        return Self.response(await page?.shareCall(PageScriptSources.shareFetch, arguments: args))
    }

    nonisolated static func response(_ value: Any?) -> ShareOutcome.Response {
        guard let dict = value as? [String: Any] else { return .init(status: nil) }
        return .init(status: (dict["status"] as? NSNumber)?.intValue,
                     body: dict["body"] as? String ?? "",
                     authRequired: (dict["auth"] as? Bool) ?? false)
    }

    // MARK: - Finish (step 7)

    private func finish(_ outcome: ShareOutcome, key: String?) {
        guard var item = current else { return }
        lastResult = outcome.label
        switch outcome {
        case .sent(let slot), .queued(let slot):
            confirm(item, outcome, slot: slot)
            phase = .done(outcome)
            reload()
            showSession(slot)
            // The result stays long enough to be read, then the next item
            // comes up, or the page is left to show the message arriving.
            Task { [weak self, id = item.id] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.current?.id == id, case .done = self.phase else { return }
                self.close()
            }
        case .signedOut:
            // Kept, and resumed without a tap once signed in again (F3 §2).
            resumeKey = key
            item.state = .pending
            try? store.update(item)
            current = item
            phase = .waiting("Waiting for sign-in.")
            logger.log("Share: \(item.id) waits for sign-in")
            workspace?.session.requireSignIn()
        case .sessionGone where key != nil:
            // Nothing was posted. Back to the picker, nothing selected. An
            // addressed item loses its address here (F18 §6.2), so the
            // picker is a real one and a relaunch does not try it again.
            item.state = .pending
            if let d = item.destination {
                notice = ShareOutcome.addressedSessionGone(title: d.slotTitle ?? d.slotKey)
                item.destination = nil
            } else {
                notice = outcome.sentence
            }
            addressedTitle = nil
            try? store.update(item)
            current = item
            selectedKey = nil
            phase = .picking
            logger.log("Share: \(item.id): the chosen session is gone; nothing posted")
        default:
            current = markFailed(item, outcome)
            phase = .done(outcome)
            reload()
        }
    }

    /// The answer to a post the owner walked away from: recorded as
    /// `finish` records it, with nothing shown and no navigation, since the
    /// sheet has gone and another item may be on it.
    private func settle(_ outcome: ShareOutcome, item: ShareItem) {
        lastResult = outcome.label
        // Deleted from Settings while the post was out: nothing to record.
        guard store.items().contains(where: { $0.id == item.id }) else { return }
        switch outcome {
        case .sent(let slot), .queued(let slot):
            confirm(item, outcome, slot: slot)
        case .signedOut, .sessionGone:
            // Not posted: kept, for the next foreground.
            var kept = item
            kept.state = .pending
            try? store.update(kept)
            logger.log("Share: \(item.id) was put aside mid-send and not posted (\(outcome.code))")
        default:
            _ = markFailed(item, outcome)
        }
        reload()
    }

    /// The gateway has it: the item is done with.
    private func confirm(_ item: ShareItem, _ outcome: ShareOutcome, slot: String) {
        store.delete(item.id)
        if let origin = gatewayOrigin {
            let title = sessions.first { $0.key == slot }?.title
            let now = Date()
            defaults.remember(origin: origin, .init(slotKey: slot, slotTitle: title, at: now))
            mirror.update { $0.remember(origin: origin, .init(slotKey: slot, slotTitle: title, at: now)) }
        }
        if case .queued = outcome {
            AppDiagnostics.shared.sharesQueued += 1
            logger.log("Share: sent \(item.id) to \(slot) (queued)")
        } else {
            AppDiagnostics.shared.sharesSent += 1
            logger.log("Share: sent \(item.id) to \(slot)")
        }
    }

    private func markFailed(_ item: ShareItem, _ outcome: ShareOutcome) -> ShareItem {
        var item = item
        item.state = .failed
        item.attempts += 1
        item.lastError = outcome.code
        item.lastAttemptAt = Date()
        try? store.update(item)
        AppDiagnostics.shared.sharesFailed += 1
        logger.log("Share: failed \(item.id): \(Self.logReason(outcome))")
        return item
    }

    /// A failure for the log: codes and statuses, never the gateway's text
    /// (it can quote a filename).
    nonisolated static func logReason(_ outcome: ShareOutcome) -> String {
        switch outcome {
        case .refused(let status, _): return "refused (\(status))"
        case .uploadInterrupted(let done, let total): return "upload interrupted (\(done) of \(total))"
        default: return outcome.code
        }
    }

    /// Step 6: the dashboard shows the session. A same-origin load of
    /// `/chat?sid=<key>`: the SPA reads `sid` when a document loads and
    /// selects that session once its list arrives. A `pushState` from
    /// outside is honoured only after an in-app navigation, and not on a
    /// phone-sized layout (F3 §9), so the load is the dependable path.
    private func showSession(_ key: String, prefill: String? = nil) {
        guard let origin = gatewayOrigin, var c = URLComponents(string: origin) else { return }
        c.path = "/chat"
        c.queryItems = [URLQueryItem(name: "sid", value: key)]
            + (prefill.map { [URLQueryItem(name: "prefill", value: $0)] } ?? [])
        guard let url = c.url else { return }
        page?.load(url: url)
    }

    // MARK: - The Shortcut's run (F18 §4 C)

    /// What `performIntent` ends in: the intent's dialog is written from it.
    enum IntentOutcome: Equatable {
        /// Refused at capture (size, inbox full): nothing stored.
        case refused(String)
        /// The gateway has it: sent, or queued behind a running turn.
        case delivered(ShareOutcome, title: String)
        /// The gateway refused, or nothing answered. Kept, failed; Retry is
        /// in Settings → Share and on the next foreground.
        case failed(ShareOutcome)
        /// It cannot finish without the app in front (the node or the page
        /// did not come up in time, sign-in, the session gone): the item
        /// waits in the inbox, still addressed, and option B takes over.
        case needsForeground(String)
    }

    /// The whole run, node start included. What iOS itself allows a
    /// background intent is unmeasured (F18 §9 Q2); the `ShareIntent:`
    /// lines this logs per phase are the instrument for a device run.
    static let intentBudget: Duration = .seconds(25)

    /// The Shortcut's run, in this process, with or without a scene: admit
    /// the item, bring the node up, bring the page up off-screen if need
    /// be, then `deliver` -- which re-lists and posts only if the key is
    /// there. Each phase gets what is left of `budget`.
    func performIntent(_ item: ShareItem, to destination: ShareDestination,
                       payloadFile: URL? = nil, payloadData: Data? = nil,
                       budget: Duration = ShareDelivery.intentBudget) async -> IntentOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start + budget
        var addressed = item
        addressed.destination = destination
        func elapsed(_ since: ContinuousClock.Instant = start) -> Int { Self.milliseconds(clock.now - since) }
        // Not offered to the picker while this run owns it.
        held.insert(item.id)
        defer { held.remove(item.id) }
        if let reason = admit(addressed, payloadFile: payloadFile, payloadData: payloadData) {
            return .refused(reason)
        }
#if canImport(UIKit)
        let appState = UIApplication.shared.applicationState == .active ? "active" : "not active"
#else
        let appState = "n/a"
#endif
        logger.log("ShareIntent: begin \(item.id) to \(destination.slotKey) (app \(appState))")
        func handOver(_ reason: String) -> IntentOutcome {
            var kept = addressed
            kept.state = .pending
            try? store.update(kept)
            reload()
            logger.log("ShareIntent: needs foreground after \(elapsed()) ms: \(reason)")
            return .needsForeground(reason)
        }

        // A background launch has no view to hand over a workspace.
        if workspace == nil, let ws = WorkspaceManager.current?.activeWorkspace { attach(ws) }
        guard let workspace, let origin = gatewayOrigin else { return handOver("no gateway is chosen") }
        guard destination.origin == origin else { return handOver("the share is addressed to another gateway") }
        guard current == nil else { return handOver("another share is on the picker") }

        // 1. The node.
        let nodeStart = clock.now
        node: while true {
            switch workspace.model.state {
            case .Running:
                break node
            case .NeedsLogin, .NeedsMachineAuth:
                return handOver("the tailnet needs a login")
            default:
                if workspace.model.startFailure != nil { return handOver("the node could not start") }
                if clock.now >= deadline { return handOver("the node did not come up in \(elapsed(nodeStart)) ms") }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        logger.log("ShareIntent: node up in \(elapsed(nodeStart)) ms")

        // 2. The page, signed in. With no scene it is created here, off
        // screen; the view that appears later takes this same one.
        let pageStart = clock.now
        guard let tab = workspace.tabManager.currentTab else { return handOver("no page") }
        if !tab.hasWebView {
            _ = tab.viewModel.makeWebView()
            logger.log("ShareIntent: page created off-screen")
        }
        while let why = pageBlocker {
            if workspace.session.state == .needsToken { return handOver("sign-in is needed") }
            if clock.now >= deadline { return handOver("the page was not ready in \(elapsed(pageStart)) ms (\(why))") }
            try? await Task.sleep(for: .milliseconds(100))
        }
        logger.log("ShareIntent: page ready in \(elapsed(pageStart)) ms")

        // 3. Re-list, verify, upload, post.
        let postStart = clock.now
        addressed.state = .sending
        addressed.lastAttemptAt = Date()
        try? store.update(addressed)
        let outcome = await deliver(addressed, to: destination.slotKey)
        posting.remove(item.id)
        if current == nil { phase = .idle }
        guard let outcome else { return handOver("the send was interrupted") }
        logger.log("ShareIntent: post in \(elapsed(postStart)) ms: \(Self.logReason(outcome))")
        switch outcome {
        case .sent(let slot), .queued(let slot):
            let title = sessions.first { $0.key == slot }?.title ?? destination.slotTitle ?? slot
            lastResult = outcome.label
            confirm(addressed, outcome, slot: slot)
            reload()
            showSession(slot)
            logger.log("ShareIntent: done in \(elapsed()) ms: \(outcome.code)")
            return .delivered(outcome, title: title)
        case .sessionGone:
            // Kept addressed: the foreground picker says which session went.
            return handOver("the session isn't there any more")
        case .signedOut:
            workspace.session.requireSignIn()
            return handOver("sign-in is needed")
        case .unreachable, .refused, .uploadInterrupted:
            lastResult = outcome.label
            _ = markFailed(addressed, outcome)
            reload()
            logger.log("ShareIntent: done in \(elapsed()) ms: failed")
            return .failed(outcome)
        }
    }

    /// After `continueInForeground`, or the test hook's stand-in for it:
    /// the addressed item goes the way any waiting item goes (option B).
    func fallBackToForeground() {
        reload()
        if current == nil { advance() }
    }

    nonisolated static func milliseconds(_ d: Duration) -> Int {
        Int(d.components.seconds) * 1000 + Int(d.components.attoseconds / 1_000_000_000_000_000)
    }

    // MARK: - Owner actions

    func retry() {
        guard current != nil else { return }
        if let key = lastKey, !sessions.isEmpty {
            send(to: key)
        } else {
            phase = .waiting("Connecting to the gateway…")
            preconditionsChanged()
        }
    }

    /// The prefill fallback (F3 §4.9): the session opens with the text in
    /// its composer for 30 s, and the owner taps the page's own Send. The
    /// item stays until he deletes it: the app cannot know he sent it.
    func openPrefilled() {
        guard let item = current, let key = lastKey else { return }
        logger.log("Share: \(item.id) opened prefilled in \(key)")
        let text = ShareMessage.compose(item)
        close()
        showSession(key, prefill: text)
    }

    /// Later: the item stays, and comes back on the next foreground. A
    /// send whose post has left is not stopped: it finishes out of sight
    /// and records its answer (`settle`), so a delivered item is never
    /// offered again.
    func close() {
        if let item = current {
            deferred.insert(item.id)
            if posting.contains(item.id) {
                runTask = nil
                logger.log("Share: \(item.id) put aside mid-post; its answer will be recorded")
            } else if item.state == .sending {
                var kept = item
                kept.state = .pending
                try? store.update(kept)
            }
        }
        runTask?.cancel()
        pageWaitTask?.cancel()
        resumeKey = nil
        current = nil
        phase = .idle
        isPickerRequested = false
        reload()
        // The next waiting item, if any, once this sheet is gone.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.advance()
        }
    }

    func discard() {
        if let item = current {
            store.delete(item.id)
            logger.log("Share: deleted \(item.id)")
        }
        close()
    }

    /// Settings → Share.
    func delete(_ id: String) {
        store.delete(id)
        logger.log("Share: deleted \(id)")
        if current?.id == id { close() } else { reload() }
    }

    func retryFromSettings(_ id: String) {
        guard current == nil, !posting.contains(id), let item = waiting.first(where: { $0.id == id }) else { return }
        present(item)
    }

    func chooseGateway(_ origin: String) {
        choosingGateway = false
        guard let workspace else { return }
        sessions = []
        selectedKey = nil
        phase = .waiting("Waiting for the gateway…")
        workspace.selectGateway(origin)
        preconditionsChanged()
    }

    var gatewayHost: String? { gatewayOrigin.map(ShareMirror.hostLabel(origin:)) }
    var workspaceForPicker: Workspace? { workspace }
}

extension BrowserViewModel {
    /// Runs one of the share's page scripts in the app's content world, as
    /// the page (F3 §4.5). Its result, or nil when there is no page or the
    /// call threw; the scripts bound their own requests.
    func shareCall(_ script: String, arguments: [String: Any]) async -> Any? {
        await sessionCall(script, arguments: arguments)
    }
}
