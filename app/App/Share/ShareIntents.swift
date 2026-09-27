// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ShareIntents.swift
//  Latchkey
//
//  "Send to Latchkey" (F3 §4.2, stage 1; F18 option C): the App Intent the
//  owner's Shortcut calls from the share sheet's actions list. It runs IN
//  THE APP'S PROCESS, where the node is (F18 §2.6), and from iOS 26 it may
//  run there in the BACKGROUND: `[.background, .foreground(.dynamic)]`, so
//  the share finishes inside the share sheet -- "Sent to obsidian" -- with
//  no switch into Latchkey.
//
//  The `destination` parameter is the session drop-down (F18 §6.3). Its
//  options come from the mirror the app writes after every listing
//  (`ShareMirror`): titles and folders, never a credential, hidden once
//  older than a day. A choice from it is only ever a proposal: the run
//  re-lists and posts only if the key is still there (F3 §4.5's trap).
//
//  When the run cannot finish -- the node or the page not up inside the
//  budget, sign-in needed, the session gone -- it calls
//  `continueInForeground`: the app comes up and the addressed item goes the
//  way any waiting item goes (option B). It never posts an unverified key
//  and never loses the item.
//
//  Documents: Shortcuts hands the file over as an `IntentFile`, either on
//  disk (copied into the inbox, an APFS clone) or as data. The 50 MB check
//  comes before either.
//
//  Every phase logs its time under one prefix, `ShareIntent:`, so a single
//  device run gives F18 §9 Q2's numbers.
//

import AppIntents
import Foundation
import UniformTypeIdentifiers

/// One session in the Shortcut's drop-down, from the mirror.
nonisolated struct ShareDestinationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Session"
    static let defaultQuery = ShareDestinationQuery()

    /// `<origin> <key>`: a key is unique per gateway, not across them.
    let id: String
    let origin: String
    let gatewayLabel: String
    let slotKey: String
    let slotTitle: String
    let folder: String?
    let running: Bool
    /// The last session shared to on its gateway: offered first.
    let isLast: Bool
    /// Whether more than one gateway is offered, so the label says which.
    let namesGateway: Bool

    init(_ s: ShareSession, gateway: ShareMirror.Gateway, namesGateway: Bool) {
        id = "\(gateway.origin) \(s.key)"
        origin = gateway.origin
        gatewayLabel = gateway.label
        slotKey = s.key
        slotTitle = s.title
        folder = s.folder
        running = s.running
        isLast = gateway.lastDestination?.slotKey == s.key
        self.namesGateway = namesGateway
    }

    var displayRepresentation: DisplayRepresentation {
        var parts: [String] = []
        if let folder { parts.append(folder) }
        if namesGateway { parts.append(gatewayLabel) }
        if running { parts.append("busy") }
        if isLast { parts.append("last time") }
        return DisplayRepresentation(title: "\(slotTitle)",
                                     subtitle: parts.isEmpty ? nil : "\(parts.joined(separator: " · "))")
    }

    var destination: ShareDestination {
        ShareDestination(origin: origin, slotKey: slotKey, slotTitle: slotTitle, chosenAt: Date())
    }

    /// What the drop-down offers now: fresh gateways, the current one
    /// first, the last destination first within it, newest activity next.
    static func offered(_ mirror: ShareMirror?, now: Date) -> [ShareDestinationEntity] {
        guard let mirror else { return [] }
        let gateways = mirror.offered(now: now)
        let several = gateways.count > 1
        return gateways.flatMap { g in
            g.sessions.map { ShareDestinationEntity($0, gateway: g, namesGateway: several) }
                .sorted { a, b in a.isLast && !b.isLast }
        }
    }
}

nonisolated struct ShareDestinationQuery: EntityQuery {
    private static func mirror() async -> ShareMirror? {
        let store = await MainActor.run { ShareMirrorStore.app(appSupport: WorkspaceStore.appSupportDir) }
        return store.load()
    }

    func entities(for identifiers: [String]) async throws -> [ShareDestinationEntity] {
        let all = ShareDestinationEntity.offered(await Self.mirror(), now: Date())
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [ShareDestinationEntity] {
        ShareDestinationEntity.offered(await Self.mirror(), now: Date())
    }

    /// F18 §10: the last session used, so a new action starts on it.
    func defaultResult() async -> ShareDestinationEntity? {
        ShareDestinationEntity.offered(await Self.mirror(), now: Date()).first
    }
}

struct SendToSessionIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Send to Latchkey"
    nonisolated static let description = IntentDescription(
        "Sends a link, text or a file to a session on your KiroCrew gateway, from the share sheet. Pick the session here; Latchkey opens only if it cannot finish in the background.")
    nonisolated static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "URL") var url: URL?
    @Parameter(title: "Title") var title: String?
    @Parameter(title: "Text") var text: String?
    @Parameter(title: "File", supportedContentTypes: [.item]) var file: IntentFile?
    @Parameter(title: "Note") var note: String?
    @Parameter(title: "Session") var destination: ShareDestinationEntity?

    struct Refused: Error, CustomLocalizedStringResourceConvertible {
        let reason: String
        var localizedStringResource: LocalizedStringResource { "\(reason)" }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let id = UUID().uuidString
        let now = Date()
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        func refuse(_ reason: String) -> Refused {
            logger.log("Share: the intent was refused: \(reason.hasPrefix("Files over") ? "over 50 MB" : "invalid input")")
            return Refused(reason: reason)
        }

        // The destination: chosen in the Shortcut, or asked for now from
        // the mirror. An empty list says why (F18 §5) and refuses.
        let chosen: ShareDestinationEntity
        if let destination {
            chosen = destination
        } else {
            let mirror = ShareMirrorStore.app(appSupport: WorkspaceStore.appSupportDir).load()
            let offered = ShareDestinationEntity.offered(mirror, now: now)
            if let why = ShareMirror.emptyReason(mirror, now: now) ?? (offered.isEmpty ? "No session to send to." : nil) {
                logger.log("ShareIntent: no session to offer (\(mirror == nil ? "no mirror" : "empty or stale"))")
                throw Refused(reason: why)
            }
            chosen = try await $destination.requestDisambiguation(among: offered, dialog: "Which session?")
        }

        let item: ShareItem
        var payloadFile: URL?
        var payloadData: Data?
        var scopedSource: URL?
        defer { if let scopedSource { scopedSource.stopAccessingSecurityScopedResource() } }
        if let file {
            let name = ShareItem.sanitisedFilename(file.filename)
            var doc = ShareItem(id: id, kind: .document, url: nil, title: title, text: nil,
                                note: note?.isEmpty == true ? nil : note, filename: name,
                                utType: file.type?.identifier, byteCount: 0, createdAt: now, source: .intent)
            if let source = file.fileURL {
                if source.startAccessingSecurityScopedResource() { scopedSource = source }
                let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                doc.byteCount = size
                // The size is known before a byte is copied: refuse early.
                if size > ShareInboxPolicy.maxDocumentBytes {
                    throw refuse(ShareInboxPolicy.sentence(for: .tooLarge(byteCount: size)))
                }
                payloadFile = source
            } else {
                let data = file.data
                doc.byteCount = Int64(data.count)
                payloadData = data
            }
            item = doc
        } else {
            // A link: the URL parameter, or text that is nothing but a web link.
            var link = url.map(\.absoluteString)
            var body = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            if link == nil, let b = body, ShareURL.isWebLink(b), !b.contains(where: \.isWhitespace) {
                link = b
                body = nil
            }
            if let l = link, !ShareURL.isWebLink(l) { throw refuse("Only web links (http or https) can be shared.") }
            if body?.isEmpty == true { body = nil }
            guard link != nil || body != nil else { throw refuse("There is nothing to send.") }
            if (link?.utf8.count ?? 0) > ShareURL.maxURLBytes || (body?.utf8.count ?? 0) > ShareURL.maxTextBytes
                || (title?.utf8.count ?? 0) > ShareURL.maxTitleBytes {
                throw refuse("That is too long to share.")
            }
            let bytes = [link, title, body].compactMap { $0?.utf8.count }.reduce(0, +)
            item = ShareItem(id: id, kind: link != nil ? .link : .text, url: link,
                             title: title?.isEmpty == true ? nil : title, text: body,
                             note: note?.isEmpty == true ? nil : note,
                             byteCount: Int64(bytes), createdAt: now, source: .intent)
        }

        let outcome = await ShareDelivery.shared.performIntent(item, to: chosen.destination,
                                                               payloadFile: payloadFile, payloadData: payloadData)
        switch outcome {
        case .refused(let reason):
            throw refuse(reason)
        case .delivered(let result, let title):
            if case .queued = result {
                return .result(dialog: "Queued: \(title) is mid-turn; the gateway will run it next.")
            }
            return .result(dialog: "Sent to \(title).")
        case .failed(let result):
            let host = chosen.gatewayLabel
            return .result(dialog: "\(ShareOutcome.sentence(for: result, gatewayHost: host)) Kept in Latchkey, under Settings → Share.")
        case .needsForeground(let reason):
            // Option B: the app comes up and finishes the addressed item.
            try await continueInForeground("Latchkey needs to open to finish this share: \(reason).")
            ShareDelivery.shared.fallBackToForeground()
            return .result(dialog: "Finishing in Latchkey.")
        }
    }
}
