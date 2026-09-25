// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ShareSettingsSection.swift
//  Latchkey
//
//  Settings → Share (F3 §2): what is waiting, the last outcome of each, and
//  Retry / Delete. An empty list means everything shared has been confirmed
//  by a gateway. Shows kinds, sources, sizes and times -- the content only
//  as far as the owner needs to recognise it.
//

import SwiftUI

struct ShareSettingsSection: View {
    @ObservedObject var delivery: ShareDelivery
    /// Closes Settings, so the picker a Retry brings up can be shown.
    let dismissSettings: () -> Void

    var body: some View {
        Section {
            Text(delivery.waiting.isEmpty ? "Nothing waiting" : "\(delivery.waiting.count) waiting")
                .accessibilityLabel("\(delivery.waiting.count)")
                .accessibilityIdentifier("share-waiting-count")
            ForEach(delivery.waiting, id: \.id) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.name(item)).lineLimit(1)
                    Text(Self.detail(item)).font(.caption).foregroundStyle(.secondary)
                    if let error = item.lastError {
                        Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
                    }
                    HStack {
                        Button("Retry") {
                            dismissSettings()
                            delivery.retryFromSettings(item.id)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("share-settings-retry")
                        Spacer()
                        Button("Delete", role: .destructive) { delivery.delete(item.id) }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("share-settings-delete")
                    }
                    .font(.subheadline)
                }
            }
        } header: {
            Text("Share")
        } footer: {
            Text("Links and files shared to Latchkey wait here until a gateway confirms them. Anything older than 7 days is removed unsent.")
        }
        .accessibilityIdentifier("share-settings")
    }

    static func name(_ item: ShareItem) -> String {
        switch item.kind {
        case .link: return item.title ?? item.url ?? "Link"
        case .text: return String((item.text ?? "Text").prefix(60))
        case .document: return item.filename ?? "Document"
        }
    }

    static func detail(_ item: ShareItem) -> String {
        let size = ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)
        let when = item.createdAt.formatted(.relative(presentation: .named))
        let via: String
        switch item.source {
        case .urlScheme: via = "link"
        case .intent: via = "Shortcut"
        case .extension: via = "share sheet"
        }
        return "\(item.kind.rawValue.capitalized) · \(size) · via \(via) · \(when)"
    }
}
