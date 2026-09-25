// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ShareIntents.swift
//  Latchkey
//
//  "Send to Latchkey" (F3 §4.2, stage 1): the App Intent the owner's
//  Shortcut calls from the share sheet. It runs IN THE APP'S PROCESS with the
//  app brought to the front (`.foreground(.immediate)`), writes one item to
//  the inbox and returns; the picker then comes up the way it does for any
//  other item. Nothing is sent from here.
//
//  This is what carries documents without a share extension or an App
//  Group: Shortcuts hands the file over as an `IntentFile`, either on disk
//  (copied into the inbox -- an APFS clone, no bytes through memory) or as
//  data, written straight to the inbox. The 50 MB check comes before either.
//
//  The destination is never a parameter: it is chosen in the app, from the
//  gateway's live list (F3 §3).
//

import AppIntents
import Foundation
import UniformTypeIdentifiers

struct SendToSessionIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Send to Latchkey"
    nonisolated static let description = IntentDescription(
        "Sends a link, text or a file to a session on your KiroCrew gateway. Latchkey opens, and you pick the session there.")
    nonisolated static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "URL") var url: URL?
    @Parameter(title: "Title") var title: String?
    @Parameter(title: "Text") var text: String?
    @Parameter(title: "File", supportedContentTypes: [.item]) var file: IntentFile?
    @Parameter(title: "Note") var note: String?

    struct Refused: Error, CustomLocalizedStringResourceConvertible {
        let reason: String
        var localizedStringResource: LocalizedStringResource { "\(reason)" }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let id = UUID().uuidString
        let now = Date()
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        func refuse(_ reason: String) -> Refused {
            logger.log("Share: the intent was refused: \(reason.hasPrefix("Files over") ? "over 50 MB" : "invalid input")")
            return Refused(reason: reason)
        }

        if let file {
            let name = ShareItem.sanitisedFilename(file.filename)
            var item = ShareItem(id: id, kind: .document, url: nil, title: title, text: nil,
                                 note: note?.isEmpty == true ? nil : note, filename: name,
                                 utType: file.type?.identifier, byteCount: 0, createdAt: now, source: .intent)
            if let source = file.fileURL {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                item.byteCount = size
                // The size is known before a byte is copied: refuse early.
                if size > ShareInboxPolicy.maxDocumentBytes {
                    throw refuse(ShareInboxPolicy.sentence(for: .tooLarge(byteCount: size)))
                }
                if let reason = ShareDelivery.shared.admit(item, payloadFile: source) { throw refuse(reason) }
            } else {
                let data = file.data
                item.byteCount = Int64(data.count)
                if let reason = ShareDelivery.shared.admit(item, payloadData: data) { throw refuse(reason) }
            }
            return .result()
        }

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
        let item = ShareItem(id: id, kind: link != nil ? .link : .text, url: link,
                             title: title?.isEmpty == true ? nil : title, text: body,
                             note: note?.isEmpty == true ? nil : note,
                             byteCount: Int64(bytes), createdAt: now, source: .intent)
        if let reason = ShareDelivery.shared.admit(item) { throw refuse(reason) }
        return .result()
    }
}
