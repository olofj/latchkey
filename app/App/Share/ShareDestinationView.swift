// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ShareDestinationView.swift
//  Latchkey
//
//  The destination picker (F3 §4.7): what is being shared, the gateway, its
//  sessions newest first with the last one used already selected, a note,
//  Send -- then the gateway's answer, in its own words.
//
//  A SHEET over the dashboard, presented from the root beside the sign-in
//  sheet and Settings, and never with them (the one-sheet rule, M4/M5). It
//  draws nothing over the page and changes nothing about the page's frame:
//  twice a change to the web view's insets shipped a broken screen (F13's
//  black page, F15). The session suite checks the page's frame is the same
//  before and after a share with the keyboard up.
//

import SwiftUI

struct ShareDestinationView: View {
    @ObservedObject var delivery: ShareDelivery
    @FocusState private var noteFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if delivery.choosingGateway, let workspace = delivery.workspaceForPicker {
                    GatewayPickerView(discovery: workspace.discovery, model: workspace.model,
                                      savedHost: delivery.gatewayHost,
                                      autoSelectSingle: false,
                                      sweepOnAppear: true,
                                      onSelect: { delivery.chooseGateway($0) },
                                      onCancel: { delivery.choosingGateway = false })
                } else {
                    picker
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("share-picker")
    }

    private var picker: some View {
        List {
            Section {
                itemSummary
                if let host = delivery.gatewayHost {
                    HStack {
                        Label(host, systemImage: "server.rack")
                            .font(.subheadline)
                            .accessibilityIdentifier("share-gateway")
                        Spacer()
                        Button("Change gateway…") { delivery.choosingGateway = true }
                            .font(.subheadline)
                            .disabled(isWorking)
                            .accessibilityIdentifier("share-change-gateway")
                    }
                }
                if let elsewhere = delivery.elsewhere {
                    Button("Last time: \(elsewhere.title) on \(URL(string: elsewhere.origin)?.host ?? elsewhere.origin) — switch?") {
                        delivery.chooseGateway(elsewhere.origin)
                    }
                    .font(.footnote)
                    .accessibilityIdentifier("share-switch-gateway")
                }
            } header: {
                let p = delivery.position
                if p.total > 1 { Text("\(p.index) of \(p.total)") }
            }

            if let notice = delivery.notice {
                Section {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .accessibilityIdentifier("share-notice")
                }
            }

            switch delivery.phase {
            case .waiting(let text):
                Section { status(text, spinning: true) }
            case .listing:
                Section { status("Listing sessions", spinning: true) }
            case .picking, .working:
                sessionList
                Section("Note") {
                    TextField("Optional", text: $delivery.note, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($noteFocused)
                        .disabled(isWorking)
                        .accessibilityIdentifier("share-note")
                }
            case .done(let outcome):
                Section { result(outcome) }
            case .idle:
                EmptyView()
            }
        }
        .navigationTitle("Share to a session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(isDone ? "Done" : "Later") { delivery.close() }
                    .accessibilityIdentifier("share-cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                if case .working(let text) = delivery.phase {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text(text).font(.footnote)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("share-progress")
                } else if delivery.phase == .picking {
                    Button("Send") {
                        noteFocused = false
                        delivery.sendSelected()
                    }
                    .bold()
                    .disabled(delivery.selectedKey == nil)
                    .accessibilityIdentifier("share-send")
                }
            }
        }
    }

    private var isWorking: Bool {
        if case .working = delivery.phase { return true }
        return false
    }

    private var isDone: Bool {
        if case .done = delivery.phase { return true }
        return false
    }

    @ViewBuilder private var itemSummary: some View {
        if let item = delivery.current {
            VStack(alignment: .leading, spacing: 2) {
                switch item.kind {
                case .link:
                    Text(item.title ?? item.url ?? "Link").font(.headline).lineLimit(2)
                    if item.title != nil, let url = item.url {
                        Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                case .text:
                    Text(item.text ?? "").font(.subheadline).lineLimit(3)
                case .document:
                    Text(item.filename ?? "Document").font(.headline).lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("share-item")
        }
    }

    private var sessionList: some View {
        Section("Session") {
            if delivery.sessions.isEmpty {
                Text("No sessions on this gateway. Start one in the dashboard first.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(delivery.sessions) { session in
                Button {
                    delivery.selectedKey = session.key
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title).foregroundStyle(.primary)
                            if let folder = session.folder {
                                Text(folder).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if session.running {
                            Text(session.queueDepth > 0 ? "busy · \(session.queueDepth) queued" : "busy")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        if delivery.selectedKey == session.key {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .disabled(isWorking)
                .accessibilityIdentifier("share-session-\(session.key)")
                .accessibilityAddTraits(delivery.selectedKey == session.key ? .isSelected : [])
            }
            // What is selected, for the UI tests: the key, or "none".
            Text(delivery.selectedKey ?? "none")
                .font(.system(size: 1)).opacity(0.01)
                .accessibilityLabel(delivery.selectedKey ?? "none")
                .accessibilityIdentifier("share-destination-selected")
                .listRowBackground(Color.clear)
                .frame(height: 1)
        }
    }

    private func status(_ text: String, spinning: Bool) -> some View {
        HStack(spacing: 8) {
            if spinning { ProgressView() }
            Text(text).font(.subheadline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("share-status")
    }

    @ViewBuilder private func result(_ outcome: ShareOutcome) -> some View {
        let delivered = outcome.isDelivered
        Label(ShareOutcome.sentence(for: outcome, gatewayHost: delivery.gatewayHost),
              systemImage: delivered ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(delivered ? Color.green : Color.orange)
            .accessibilityLabel(outcome.label)
            .accessibilityIdentifier("share-result")
        if !delivered {
            if ShareOutcome.offersPrefill(outcome, kind: delivery.current?.kind ?? .document) {
                Button("Open the session with it prefilled") { delivery.openPrefilled() }
                    .accessibilityIdentifier("share-prefill")
            }
            Button("Retry") { delivery.retry() }
                .accessibilityIdentifier("share-retry")
            Button("Delete", role: .destructive) { delivery.discard() }
                .accessibilityIdentifier("share-delete")
        }
    }
}
