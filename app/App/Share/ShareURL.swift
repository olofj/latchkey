// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ShareURL.swift
//  Latchkey
//
//  `latchkey://share?url=…&title=…&text=…` → an inbox item (F3 §4.2, stage 1).
//  Pure, so scripts/test-share.sh checks it on the host.
//
//  Any app, and any web page, can open this URL, so it is read as hostile:
//   - only an http(s) link is taken -- never `javascript:`, `data:`, `file:`;
//   - each field has a cap, and anything over it refuses the whole share
//     rather than sending a cut-off link;
//   - a parameter naming a gateway or a session is ignored. The destination
//     is chosen in the app, from the live list, by the owner. There is no
//     auto-send from a URL, ever.
//   - it carries links and text only; a document comes by the App Intent.
//

import Foundation

nonisolated enum ShareURL {
    static let scheme = "latchkey"
    static let host = "share"
    static let maxURLBytes = 8 * 1024
    static let maxTitleBytes = 1024
    static let maxTextBytes = 64 * 1024

    /// The item `url` asks to share, or nil if it is not a share URL or
    /// breaks a rule above.
    static func parse(_ url: URL, id: String, now: Date) -> ShareItem? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func field(_ name: String) -> String? {
            let v = items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (v?.isEmpty ?? true) ? nil : v
        }
        let link = field("url"), title = field("title"), text = field("text")
        if let link {
            guard link.utf8.count <= maxURLBytes, isWebLink(link) else { return nil }
        }
        if let title, title.utf8.count > maxTitleBytes { return nil }
        if let text, text.utf8.count > maxTextBytes { return nil }
        guard link != nil || text != nil else { return nil }
        let bytes = [link, title, text].compactMap { $0?.utf8.count }.reduce(0, +)
        return ShareItem(id: id, kind: link != nil ? .link : .text,
                         url: link, title: title, text: text,
                         byteCount: Int64(bytes), createdAt: now, source: .urlScheme)
    }

    /// An absolute http(s) URL with a host: what a browser's share sheet
    /// hands over.
    static func isWebLink(_ s: String) -> Bool {
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty
        else { return false }
        return true
    }
}
