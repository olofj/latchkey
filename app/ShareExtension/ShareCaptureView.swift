// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ShareCaptureView.swift
//  ShareExtension
//
//  The small sheet in the share sheet (F3 §2 step 2): what is being shared,
//  a note, *Save for Latchkey*, and how many shares already wait. Then
//  "Saved. Open Latchkey to send it." -- and that nothing has been sent.
//

import SwiftUI

struct ShareCaptureView: View {
    @ObservedObject var model: ShareCaptureModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Latchkey")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if model.state != .saved {
                            Button("Cancel") { model.cancel() }
                                .accessibilityIdentifier("share-capture-cancel")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if model.state == .ready {
                            Button("Save for Latchkey") { model.save() }
                                .bold()
                                .accessibilityIdentifier("share-capture-save")
                        } else if model.state == .saving || model.state == .loading {
                            ProgressView()
                        }
                    }
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("share-capture")
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .saved:
            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill").font(.largeTitle).foregroundStyle(.tint)
                Text("Saved. Open Latchkey to send it.").font(.headline)
                Text("Nothing has been sent yet.").font(.subheadline).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("share-capture-saved")
        default:
            Form {
                if let c = model.captured {
                    Section { summary(c) }
                }
                if case .refused(let reason) = model.state {
                    Section {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .accessibilityIdentifier("share-capture-refused")
                    }
                } else if model.captured != nil {
                    Section("Note") {
                        TextField("Optional", text: $model.note, axis: .vertical)
                            .lineLimit(1...4)
                            .accessibilityIdentifier("share-capture-note")
                    }
                }
                if let advisory = model.advisory {
                    Section { Text(advisory).font(.footnote).foregroundStyle(.orange) }
                }
                if model.waitingCount > 0 {
                    Section {
                        Text(model.waitingCount == 1 ? "1 share is already waiting in Latchkey."
                                                     : "\(model.waitingCount) shares are already waiting in Latchkey.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("You pick the session in Latchkey. Nothing is sent from here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func summary(_ c: ShareCaptureModel.Captured) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch c.kind {
            case .link:
                Text(c.title ?? c.url ?? "Link").font(.headline).lineLimit(2)
                if c.title != nil, let url = c.url {
                    Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            case .text:
                Text(c.text ?? "").font(.subheadline).lineLimit(4)
            case .document:
                Text(c.filename ?? "File").font(.headline).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: c.byteCount, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("share-capture-item")
    }
}
