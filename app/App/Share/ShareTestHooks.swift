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
//    -UITestResetShare            an empty inbox, no remembered session and
//                                 no session mirror
//    -UITestSeedShare <spec>      kind:bytes[:age=<days>d][:name=<file>][:dest=<key>]
//                                 kind pdf (a `%PDF-` header) or bin; the
//                                 name defaults to shared.<kind>; dest
//                                 addresses it to <key> on the test gateway
//                                 (F18 §6.2), as the Shortcut's drop-down does
//    -UITestIntentDeliver         with a dest= seed: the item goes the
//                                 Shortcut's way, `ShareDelivery.performIntent`
//                                 in this process (F18 §4 C), rather than
//                                 through the inbox and the picker
//

#if LATCHKEY_TEST_HOOKS
import Foundation

enum ShareTestHooks {
    /// Applies the hooks. Returns the seeded item, its destination and its
    /// payload file when `-UITestIntentDeliver` asks for the intent's path;
    /// the caller runs it once it exists. Otherwise the seed is in the store.
    static func apply(store: ShareInbox, defaults: ShareDefaults, mirror: ShareMirrorStore,
                      onSeeded: () -> Void) -> (item: ShareItem, destination: ShareDestination, payload: URL)? {
        if TestHooks.flag("-UITestResetShare") {
            store.removeAll()
            defaults.removeAll()
            mirror.removeAll()
        }
        guard let spec = TestHooks.value("-UITestSeedShare") else { return nil }
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count >= 2, ["pdf", "bin"].contains(parts[0]), let bytes = Int64(parts[1]), bytes >= 0 else {
            logger.log("Share: -UITestSeedShare \(spec) is not kind:bytes[:age=Nd][:name=…][:dest=…]")
            return nil
        }
        var age: TimeInterval = 0
        var name = "shared.\(parts[0])"
        var destination: ShareDestination?
        for p in parts.dropFirst(2) {
            if p.hasPrefix("age="), p.hasSuffix("d"), let d = Double(p.dropFirst(4).dropLast()) { age = d * 86400 }
            if p.hasPrefix("name=") { name = String(p.dropFirst(5)) }
            if p.hasPrefix("dest="), let home = TestHooks.value("-UITestHomePage"),
               let origin = GatewayAddress.origin(of: home) {
                destination = ShareDestination(origin: origin, slotKey: String(p.dropFirst(5)),
                                               slotTitle: String(p.dropFirst(5)), chosenAt: Date())
            }
        }
        let id = UUID().uuidString
        var item = ShareItem(id: id, kind: .document, url: nil, title: nil, text: nil, note: nil,
                             filename: ShareItem.sanitisedFilename(name),
                             utType: parts[0] == "pdf" ? "com.adobe.pdf" : "public.data",
                             byteCount: bytes, createdAt: Date().addingTimeInterval(-age), source: .intent)
        item.destination = destination
        // What the intent does: the size first, before any byte exists.
        if case .refused(let r) = ShareInboxPolicy.admit(byteCount: bytes, fileExtension: item.fileExtension,
                                                          inboxCount: store.summary().count,
                                                          inboxBytes: store.summary().bytes) {
            logger.log("Share: refused \(id) at capture: \(ShareDelivery.describe(r))")
            return nil
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "seed-\(id)")
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { return nil }
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
        if let destination, TestHooks.flag("-UITestIntentDeliver") {
            // The intent's path admits it itself (an APFS clone of the seed
            // file); the seed file is left for it and is in tmp anyway.
            item.destination = nil
            return (item, destination, file)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try store.add(item, payloadFile: file)
            onSeeded()
            logger.log("Share: received \(id) (document, \(bytes) B) via test seed\(destination == nil ? "" : ", addressed")")
        } catch {
            logger.log("Share: the test seed was not stored: \(error)")
        }
        return nil
    }
}
#endif
