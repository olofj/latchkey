// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ShareMessage.swift
//  Latchkey
//
//  The text a share posts to the session (F3 §4.6; Olof, §6: "the title and
//  the URL, plus a note if typed", and for a document "the artifact itself
//  with a note", as the chat window would send it). Pure, so
//  scripts/test-share.sh checks it on the host.
//
//  A document reaches the agent the way the dashboard's own composer sends
//  one: an `[attached_file 1] <path>` token naming the path the gateway's
//  upload returned, exactly as returned. The composer puts the token lines
//  AFTER the typed text, joined by a single newline (`fileTokens-*.js`,
//  identical in 0.6.0 and 0.7.0: `[text, tokens].join("\n")`); so does this
//  (F3 §9).
//

import Foundation

nonisolated enum ShareMessage {
    static func compose(_ item: ShareItem, uploadedPath: String? = nil) -> String {
        let note = clean(item.note)
        var blocks: [String] = []
        switch item.kind {
        case .link:
            blocks.append([clean(item.title), clean(item.url)].compactMap { $0 }.joined(separator: "\n"))
            if let text = clean(item.text) { blocks.append(text) }
            if let note { blocks.append(note) }
        case .text:
            if let text = clean(item.text) { blocks.append(text) }
            if let note { blocks.append(note) }
        case .document:
            // The composer's join, not the blank line the other shapes use.
            return [note, uploadedPath.map { attachmentToken($0) }].compactMap { $0 }.joined(separator: "\n")
        }
        return blocks.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func attachmentToken(_ path: String, index: Int = 1) -> String {
        "[attached_file \(index)] \(path)"
    }

    private static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        // Trailing whitespace per line and at the ends: nothing the owner
        // typed is otherwise changed.
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                var l = line
                while let last = l.last, last == " " || last == "\t" || last == "\r" { l = l.dropLast() }
                return l
            }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}
