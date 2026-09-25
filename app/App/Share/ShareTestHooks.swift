// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ShareTestHooks.swift
//  Latchkey
//
//  Test builds only (R15). XCUITest cannot drive the App Intent or a share
//  extension, so documents enter the inbox here, written exactly as the
//  intent writes them -- through the same admission (F3 §7, "Seeding
//  without the extension"):
//
//    -UITestResetShare            an empty inbox and no remembered session
//    -UITestSeedShare <spec>      kind:bytes[:age=<days>d][:name=<file>]
//                                 kind pdf (a `%PDF-` header) or bin; the
//                                 name defaults to shared.<kind>
//

#if LATCHKEY_TEST_HOOKS
import Foundation

enum ShareTestHooks {
    static func apply(store: ShareInbox, defaults: ShareDefaults, onSeeded: () -> Void) {
        if TestHooks.flag("-UITestResetShare") {
            store.removeAll()
            defaults.removeAll()
        }
        guard let spec = TestHooks.value("-UITestSeedShare") else { return }
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count >= 2, ["pdf", "bin"].contains(parts[0]), let bytes = Int64(parts[1]), bytes >= 0 else {
            logger.log("Share: -UITestSeedShare \(spec) is not kind:bytes[:age=Nd][:name=…]")
            return
        }
        var age: TimeInterval = 0
        var name = "shared.\(parts[0])"
        for p in parts.dropFirst(2) {
            if p.hasPrefix("age="), p.hasSuffix("d"), let d = Double(p.dropFirst(4).dropLast()) { age = d * 86400 }
            if p.hasPrefix("name=") { name = String(p.dropFirst(5)) }
        }
        let id = UUID().uuidString
        let item = ShareItem(id: id, kind: .document, url: nil, title: nil, text: nil, note: nil,
                             filename: ShareItem.sanitisedFilename(name),
                             utType: parts[0] == "pdf" ? "com.adobe.pdf" : "public.data",
                             byteCount: bytes, createdAt: Date().addingTimeInterval(-age), source: .intent)
        // What the intent does: the size first, before any byte exists.
        if case .refused(let r) = ShareInboxPolicy.admit(byteCount: bytes, fileExtension: item.fileExtension,
                                                          inboxCount: store.summary().count,
                                                          inboxBytes: store.summary().bytes) {
            logger.log("Share: refused \(id) at capture: \(ShareDelivery.describe(r))")
            return
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "seed-\(id)")
        defer { try? FileManager.default.removeItem(at: file) }
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { return }
        // One 1 MiB block, built once: the 50 MB seed is 50 writes of it.
        let block = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        var left = bytes
        var first = true
        while left > 0 {
            var chunk = block.prefix(Int(min(left, Int64(block.count))))
            if first, parts[0] == "pdf" {
                let header = Data("%PDF-1.4\n".utf8)
                chunk.replaceSubrange(0..<min(header.count, chunk.count), with: header.prefix(chunk.count))
            }
            first = false
            try? handle.write(contentsOf: chunk)
            left -= Int64(chunk.count)
        }
        try? handle.close()
        do {
            try store.add(item, payloadFile: file)
            onSeeded()
            logger.log("Share: received \(id) (document, \(bytes) B) via test seed")
        } catch {
            logger.log("Share: the test seed was not stored: \(error)")
        }
    }
}
#endif
