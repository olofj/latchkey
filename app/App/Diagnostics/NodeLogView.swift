// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  NodeLogView.swift
//  Latchkey
//
//  tsnet's own log, on the device (PLAN M8.3, revision R29): magicsock,
//  DERP, control and loopback lines that the app's own log never sees. Read
//  from the local, capped files the vendored libtailscale keeps (NodeLog);
//  redacted; never uploaded (D1). A filter and Copy, like the app log, and a
//  switch to the process's raw stderr (a Go panic from the last run).
//

import Combine
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct NodeLogView: View {
    var dismissAction: () -> Void

    @State private var source: NodeLog.Source = .tsnet
    @State private var filter = ""
    @State private var lines: [String] = []
    @State private var copied = false
    private let tick = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    private var shown: [String] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return f.isEmpty ? lines : lines.filter { $0.lowercased().contains(f) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Log", selection: $source) {
                    Text("tsnet").tag(NodeLog.Source.tsnet)
                    Text("stderr").tag(NodeLog.Source.stderr)
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top], 10)
                .accessibilityIdentifier("node-log-source")
                TextField("Filter (e.g. magicsock, derp, control)", text: $filter)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout)
                    .padding(10)
                    .accessibilityIdentifier("node-log-filter")
                Divider()
                if lines.isEmpty {
                    ContentUnavailableView(source == .tsnet ? "No node log yet" : "Nothing on stderr",
                                           systemImage: "doc.text",
                                           description: Text(source == .tsnet
                                                             ? "tsnet writes here once the node has started."
                                                             : "A Go panic from the last run would show here."))
                } else {
                    ScrollViewReader { proxy in
                        List(Array(shown.enumerated()), id: \.offset) { item in
                            Text(item.element)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .id(item.offset)
                        }
                        .listStyle(.plain)
                        .onAppear { proxy.scrollTo(shown.count - 1, anchor: .bottom) }
                    }
                }
                Text("\(shown.count) of \(lines.count) lines · stays on this device")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .accessibilityIdentifier("node-log-count")
            }
            .navigationTitle("Node log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: dismissAction)
                        .accessibilityIdentifier("node-log-done-button")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = shown.joined(separator: "\n")
                        copied = true
                    }
                    .disabled(shown.isEmpty)
                }
            }
        }
        .accessibilityIdentifier("node-log-view")
        .task(id: source) { await reload() }
        .onReceive(tick) { _ in Task { await reload() } }
    }

    private func reload() async {
        let dir = WorkspaceStore.logsDir
        let source = source
        let read = await Task.detached(priority: .utility) { NodeLog.tail(in: dir, source: source) }.value
        // The switch may have moved on while this read ran.
        if source == self.source, read != lines { lines = read }
    }
}
