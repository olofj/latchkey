// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ShareCaptureModel.swift
//  ShareExtension
//
//  What is being shared, read from the host app's item providers, and the
//  write to the inbox (F3 §4.2, §4.3).
//
//  Memory: the extension process is killed at about 120 MB, and a document
//  may be 50 MB. Files are taken with `loadFileRepresentation`, which hands
//  over a temporary FILE, valid only inside its handler; the handler checks
//  its size and copies it (an APFS clone on one volume) into this process's
//  temporary directory. `loadDataRepresentation` and `loadItem` are NOT used
//  for files: both deliver the bytes as `Data`, in memory. On Save the copy
//  is cloned into the inbox by `ShareInboxStore.add` and removed here.
//
//  The destination is never chosen here (F3 §3): the app picks it from the
//  gateway's live list.
//

import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import os

nonisolated let shareLog = Logger(subsystem: "net.lixom.latchkey", category: "share-extension")

@MainActor
final class ShareCaptureModel: ObservableObject {
    enum State: Equatable {
        case loading
        case ready
        /// Nothing can be saved; the reason, for the owner.
        case refused(String)
        case saving
        case saved
    }

    struct Captured: Equatable {
        var kind: ShareItem.Kind
        var url: String?
        var title: String?
        var text: String?
        var filename: String?
        var utType: String?
        var byteCount: Int64
        /// This process's copy of a document, until Save or Cancel.
        var file: URL?
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var captured: Captured?
    @Published var note = ""
    @Published private(set) var waitingCount = 0
    @Published private(set) var advisory: String?

    var finish: ((Bool) -> Void)?

    /// The group container only: the extension's own container is invisible
    /// to the app, so an item written there would never be sent.
    private let inbox: ShareInbox? = {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShareInboxStore.appGroup)
        return ShareInboxStore.groupRoot(container).map { ShareInbox(roots: [$0]) }
    }()

    func load(_ items: [NSExtensionItem]) {
        guard let inbox else {
            shareLog.log("Share extension: no App Group container; nothing can be saved")
            state = .refused("Latchkey's shared inbox isn't available in this build. Use the Send to Latchkey shortcut instead.")
            return
        }
        // The sweep before every write (F3 §4.3): only items past their
        // lifetime and a crashed writer's staging go. Never a pending item.
        let swept = inbox.sweep(now: Date())
        if swept > 0 { shareLog.log("Share extension: swept \(swept) item(s)") }
        waitingCount = inbox.summary().count

        let title = items.lazy.compactMap { ($0.attributedContentText ?? $0.attributedTitle)?.string }
            .first { !$0.isEmpty }
        let providers = items.flatMap { $0.attachments ?? [] }
        if let p = providers.first(where: { Self.isWebURL($0) }) {
            loadLink(p, title: title)
        } else if let p = providers.first(where: { Self.isFile($0) }) {
            loadFile(p)
        } else if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            loadText(p)
        } else {
            state = .refused("Latchkey can take a link, text or one file.")
        }
    }

    // MARK: - Reading the providers

    static func isWebURL(_ p: NSItemProvider) -> Bool {
        p.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            && !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }

    static func isFile(_ p: NSItemProvider) -> Bool {
        p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || (p.registeredContentTypes.contains { $0.conforms(to: .data) }
                && !p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier))
    }

    private func loadLink(_ p: NSItemProvider, title: String?) {
        _ = p.loadObject(ofClass: URL.self) { [weak self] url, _ in
            let link = url?.absoluteString
            Task { @MainActor in
                guard let self else { return }
                guard let link, ShareURL.isWebLink(link), link.utf8.count <= ShareURL.maxURLBytes else {
                    self.state = .refused("Only web links (http or https) can be shared.")
                    return
                }
                let t = title.map { String($0.prefix(ShareURL.maxTitleBytes / 4)) }
                self.ready(Captured(kind: .link, url: link, title: t == link ? nil : t,
                                    byteCount: Int64(link.utf8.count + (t?.utf8.count ?? 0))))
            }
        }
    }

    private func loadText(_ p: NSItemProvider) {
        _ = p.loadObject(ofClass: String.self) { [weak self] text, _ in
            Task { @MainActor in
                guard let self else { return }
                guard let text, !text.isEmpty, text.utf8.count <= ShareURL.maxTextBytes else {
                    self.state = .refused("That text is empty or longer than 64 KB.")
                    return
                }
                self.ready(Captured(kind: .text, text: text, byteCount: Int64(text.utf8.count)))
            }
        }
    }

    private func loadFile(_ p: NSItemProvider) {
        let type = p.registeredContentTypes.first { $0.conforms(to: .data) && $0 != .fileURL } ?? .data
        let suggested = p.suggestedName
        // A file on disk, never Data: see the header.
        _ = p.loadFileRepresentation(for: type, openInPlace: false) { [weak self] url, _, error in
            // Inside the handler: the temporary file is gone once it returns.
            let result = Self.copyOut(url, suggestedName: suggested, type: type)
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let c): self.ready(c)
                case .failure(let reason): self.state = .refused(reason.text)
                }
            }
        }
    }

    struct Refusal: Error { let text: String }

    /// Size first, then a copy into this process's temporary directory. No
    /// byte of the file passes through memory.
    nonisolated static func copyOut(_ url: URL?, suggestedName: String?, type: UTType) -> Result<Captured, Refusal> {
        guard let url else { return .failure(Refusal(text: "The file couldn't be read.")) }
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if size > ShareInboxPolicy.maxDocumentBytes {
            shareLog.log("Share extension: refused a file at capture: over 50 MB")
            return .failure(Refusal(text: ShareInboxPolicy.sentence(for: .tooLarge(byteCount: size))))
        }
        var name = url.lastPathComponent
        if let suggestedName, !suggestedName.isEmpty {
            let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : url.pathExtension
            name = suggestedName.hasSuffix("." + ext) || ext.isEmpty ? suggestedName : suggestedName + "." + ext
        }
        let filename = ShareItem.sanitisedFilename(name)
        let dir = FileManager.default.temporaryDirectory.appending(path: "capture-\(UUID().uuidString)")
        let copy = dir.appending(path: filename)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            return .failure(Refusal(text: "The file couldn't be copied."))
        }
        return .success(Captured(kind: .document, filename: filename, utType: type.identifier,
                                 byteCount: size, file: copy))
    }

    private func ready(_ c: Captured) {
        captured = c
        guard let inbox else { return }
        let waiting = inbox.summary()
        let ext = c.filename.map { ShareItem(id: "", kind: .document, filename: $0, byteCount: 0,
                                             createdAt: Date(), source: .extension).fileExtension } ?? ""
        switch ShareInboxPolicy.admit(byteCount: c.byteCount, fileExtension: ext,
                                      inboxCount: waiting.count, inboxBytes: waiting.bytes) {
        case .refused(let r):
            state = .refused(ShareInboxPolicy.sentence(for: r))
        case .admitted(let a):
            advisory = a
            state = .ready
        }
    }

    // MARK: - Save / Cancel

    func save() {
        guard state == .ready, let c = captured, let inbox else { return }
        state = .saving
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = ShareItem(id: UUID().uuidString, kind: c.kind, url: c.url, title: c.title, text: c.text,
                             note: trimmed.isEmpty ? nil : String(trimmed.prefix(ShareURL.maxTextBytes)),
                             filename: c.filename, utType: c.utType, byteCount: c.byteCount,
                             createdAt: Date(), source: .extension)
        let file = c.file
        Task.detached {
            let outcome: Result<Void, Refusal>
            do {
                try inbox.add(item, payloadFile: file)
                outcome = .success(())
            } catch ShareInboxStore.AddError.refused(let r) {
                outcome = .failure(Refusal(text: ShareInboxPolicy.sentence(for: r)))
            } catch {
                outcome = .failure(Refusal(text: "Couldn't save the share on this phone."))
            }
            if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            await MainActor.run {
                switch outcome {
                case .success:
                    shareLog.log("Share extension: saved \(item.id) (\(item.kind.rawValue), \(item.byteCount) B)")
                    self.state = .saved
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        self.finish?(true)
                    }
                case .failure(let r):
                    self.state = .refused(r.text)
                }
            }
        }
    }

    func cancel() {
        if let file = captured?.file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        finish?(false)
    }
}
