// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  NodeStartFailureView.swift
//  Latchkey
//
//  G7 (F8 §2): the node could not be created. Two parts, because the gate
//  has two places since F11: the words scroll inside `StatusView`, and the
//  controls — Try now and Logs — are pinned below them by
//  `ConnectionGateView`, where the sign-in button sits otherwise, so no text
//  size can push them off screen (F11 §4.3). *Start a new node* is the last
//  line of the words on purpose: not a button to hit by accident (F8 §2,
//  rule 3).
//

import SwiftUI

struct NodeStartFailureText: View {
    let failure: NodeStartFailure
    /// Nil hides *Start a new node*: a logging refusal is not fixed by a new
    /// identity, and offering one there would cost the node for nothing.
    let startNewNode: (() async throws -> URL)?

    @State private var confirmingNewNode = false
    @State private var newNodeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NodeStartFailure.title)
                .font(.headline)
            Text(failure.cause)
                .accessibilityIdentifier("node-start-failed-cause")
            Text(NodeStartFailure.nothingDeleted)
                .accessibilityIdentifier("node-start-nothing-deleted")
            countdown

            if let startNewNode, failure.stage == .node {
                Button("Start a new node") { confirmingNewNode = true }
                    .font(.subheadline)
                    .padding(.top, 8)
                    .accessibilityIdentifier("node-start-new-node")
                    .confirmationDialog("Start a new node?", isPresented: $confirmingNewNode,
                                        titleVisibility: .visible) {
                        Button("Start a new node", role: .destructive) {
                            Task {
                                do {
                                    _ = try await startNewNode()
                                    newNodeError = nil
                                } catch {
                                    newNodeError = "The old node's files could not be moved aside, so nothing was changed: \(error.localizedDescription)"
                                    logger.log("NODE START, NEW NODE refused: \(error)")
                                }
                            }
                        }
                        .accessibilityIdentifier("node-start-new-node-confirm")
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This device will join your tailnet as a new node: you sign in again, it may need approval — and signing, with tailnet lock — and it needs its access granted again. The old node stays in the admin console until you remove it. Its files are kept on this device, renamed aside; nothing is deleted.")
                    }
                Text("Only if the above keeps failing. Your current node's files are kept, renamed aside, and you would sign in to the tailnet again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let newNodeError {
                    Text(newNodeError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("node-start-failed")
    }

    /// Rule 2: a retry is visible and counted, or it is a hang.
    @ViewBuilder private var countdown: some View {
        if let delay = failure.nextRetryIn {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let due = failure.failedAt.addingTimeInterval(Double(delay.components.seconds))
                let left = max(0, Int(due.timeIntervalSince(context.date).rounded(.up)))
                Text("Trying again in \(left) s.")
                    .accessibilityIdentifier("node-start-retry-countdown")
                    .accessibilityValue("attempt=\(failure.attempt) next=\(delay.components.seconds)")
            }
        } else if failure.stage == .node {
            Text("Latchkey has stopped retrying by itself. It tries again when you return to the app.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("node-start-retry-stopped")
        }
    }
}

/// Try now and Logs, pinned below the gate's scrolling words.
struct NodeStartFailureActions: View {
    let onRetry: () -> Void
    @State private var showingLogs = false

    var body: some View {
        HStack(spacing: 12) {
            StatusButton(text: "Try now", action: onRetry)
                .accessibilityIdentifier("node-start-retry-now")
            StatusButton(text: "Logs", action: { showingLogs = true }, color: .gray)
                .accessibilityIdentifier("node-start-logs")
        }
        .sheet(isPresented: $showingLogs) {
            // Filtered to this failure's lines; clearing shows everything.
            LogViewer(dismissAction: { showingLogs = false }, initialFilter: "node start")
        }
    }
}
