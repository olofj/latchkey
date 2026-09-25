// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  GatewayPickerView.swift
//  Latchkey
//
//  Choose the KiroCrew gateway (PLAN M5.3). Shown instead of the dashboard
//  until a gateway is chosen, and on demand when the chosen one is
//  unreachable (M5.5). Discovered gateways stream in as their probes answer;
//  manual entry is always there, for a gateway discovery cannot see.
//
//  A single gateway found on the first run is chosen without asking: the
//  picker would offer no choice, and signing in happens in the token sheet
//  either way. (M5.3 also asked that it "already has a session"; that cannot
//  be known before loading it, and the answer does not change what to load.)
//

import SwiftUI
import TailscaleKit

struct GatewayPickerView: View {
    @ObservedObject var discovery: GatewayDiscovery
    @ObservedObject var model: TSNetModel
    /// The gateway to probe first (the one already chosen, if any).
    let savedHost: String?
    /// Choose automatically when exactly one gateway is found.
    let autoSelectSingle: Bool
    /// Sweep on appear even if an earlier sweep finished (Find, Settings):
    /// the discovery object outlives the picker, and a stale result -- maybe
    /// the unreachable gateway itself -- is not what Find asked for (M5 review).
    var sweepOnAppear: Bool = false
    /// Called with the gateway's origin, `https://<fqdn>`.
    let onSelect: (String) -> Void
    var onCancel: (() -> Void)?

    @State private var manual = ""
    @State private var manualError: String?
    @State private var autoSelected = false
    @State private var shownAt = ContinuousClock.now
    /// Collapsed by default: on a tailnet where every peer is the owner's, the
    /// skipped list is empty, and an always-open section would be clutter for
    /// the common case (F7 §8, Olof's to confirm).
    @State private var showingSkipped = false

    /// Seconds since `since`. Whole seconds: tenths read as a stopwatch and
    /// invite watching it, which is the opposite of the point.
    private func seconds(since: ContinuousClock.Instant) -> Int {
        max(0, Int((ContinuousClock.now - since).components.seconds))
    }

    private func computers(_ n: Int) -> String {
        n == 1 ? "1 computer" : "\(n) computers"
    }

    /// Whole seconds of a `Duration`. `GatewayDiscovery`'s own `milliseconds`
    /// extension is file-private, deliberately, so this does its own arithmetic
    /// rather than widening that one's scope.
    private func wholeSeconds(_ d: Duration) -> Int { max(0, Int(d.components.seconds)) }

    /// How long the last sweep took, in whole seconds.
    private var lastSweepSeconds: Int {
        discovery.lastSweep.map { wholeSeconds($0.elapsed) } ?? 0
    }

    /// Seconds before the picker admits the wait is unusual. Three status polls
    /// (5 s each): a node normally reaches a state well inside one (F4 §4.1).
    private static let waitingHintDelay = 15

    private var refreshLabel: String {
        if discovery.phase == .probing { return "Searching…" }
        return discovery.sweepTruncated ? "Keep searching" : "Search again"
    }

    /// What the picker says when a finished sweep found nothing (F4 §3.5 P4,
    /// P7; F7 §4.2). Two parts: what was checked, then what to do about it.
    ///
    /// F4 and F7 both specified this row and were written a few hours apart, F4
    /// first and without knowing about truncation. Merged rather than letting
    /// the later one win silently: F4's answered/unanswered split is the part
    /// that tells the owner whether the tailnet or the gateway is the problem,
    /// and F7's rule is that no sentence may name a number that was not probed.
    /// So the split is always shown, and the count is `probedCount` with the
    /// candidate total beside it only when they differ.
    private var noneFound: (summary: String, advice: String) {
        let peers = discovery.peerCount
        if discovery.candidateCount == 0 {
            return ("No computer on your tailnet could be a gateway "
                    + "(0 candidates among \(peers) peer\(peers == 1 ? "" : "s")).",
                    "Latchkey searches again by itself when peers appear. "
                    + "Enter one below if you know its name.")
        }
        let t = lastSweepSeconds
        let answered = discovery.answeredCount
        let unanswered = discovery.unansweredCount
        let split = "\(answered) answered but "
            + (answered == 1 ? "isn't a Kiro Crew gateway" : "aren't Kiro Crew gateways")
            + "; \(unanswered) didn't answer at all."
        let summary = discovery.sweepTruncated
            ? "Checked \(discovery.probedCount) of \(computers(discovery.candidateCount)) in \(t) s "
                + "— the search ran out of time. \(split)"
            : "Checked \(computers(discovery.probedCount)) in \(t) s. \(split)"
        var advice: String
        if unanswered > 0 {
            advice = "A computer that doesn't answer at all is usually one this device isn't "
                + "allowed to reach yet. If your gateway is among them, whoever manages the "
                + "tailnet needs this device's address: Settings → Status. Searching again "
                + "won't change that by itself."
        } else {
            advice = "Every computer answered, so the tailnet is fine; none of them is a "
                + "Kiro Crew gateway. Enter yours below if it isn't listed as a peer."
        }
        if discovery.sweepTruncated {
            advice += " Keep searching to try the rest."
        }
        return (summary, advice)
    }

    /// P6: every probe failed *and* the node's own loopback did not answer.
    private var proxyUnhealthyText: String {
        let t = lastSweepSeconds
        return "Nothing answered in \(t) s, and the tailnet node itself isn't passing traffic "
            + "yet (its own proxy didn't answer either). Search again in a moment; if it keeps "
            + "happening, Settings → Node log."
    }

    private var ready: Bool { model.localStatus != nil && model.proxyConfiguration != nil }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // P1 (F4 §3.5): the picker used to sit here with a disabled
                    // Search again and no word about what it was waiting for.
                    if !ready {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Waiting for the tailnet node… \(seconds(since: shownAt)) s")
                                        .foregroundStyle(.secondary)
                                }
                                if seconds(since: shownAt) >= Self.waitingHintDelay {
                                    Text("Still waiting. Settings → Status shows the node's state.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier("gateway-waiting-node-hint")
                                }
                            }
                        }
                        .accessibilityIdentifier("gateway-waiting-node")
                    }
                    // P2/P3: whenever a sweep is running, whether or not rows are
                    // already listed. It was conditioned on `gateways.isEmpty`, so
                    // a re-scan over existing rows showed nothing at all and the
                    // only sign of work was a greyed-out button. Determinate,
                    // because the total is known: a spinner for 12 s says only
                    // "something is happening", which is what the owner already
                    // suspects.
                    if discovery.phase == .probing {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            VStack(alignment: .leading, spacing: 6) {
                                ProgressView(value: Double(discovery.probedCount),
                                             total: Double(max(discovery.candidateCount, 1)))
                                Text("Checking \(computers(discovery.candidateCount)) on your tailnet · "
                                     + "\(discovery.probedCount) of \(discovery.candidateCount) done · "
                                     + "\(discovery.startedAt.map { seconds(since: $0) } ?? 0) s")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("gateway-searching")
                    }
                    ForEach(discovery.gateways) { gateway in
                        Button {
                            onSelect(gateway.url)
                        } label: {
                            Label(gateway.host, systemImage: "server.rack")
                                .font(.body.monospaced())
                        }
                        .accessibilityIdentifier("gateway-\(gateway.host)")
                    }
                    if discovery.phase == .finished && discovery.gateways.isEmpty {
                        // No case may name a number it did not probe (F7 §4.2).
                        // This used to report candidateCount as "checked", but
                        // the sweep abandons whatever is pending at the 12 s
                        // deadline — so on a large tailnet it claimed sixty
                        // machines when it checked about twenty-four. The advice
                        // is a separate row because it is the part worth reading
                        // twice, and it differs by *why* nothing answered.
                        VStack(alignment: .leading, spacing: 6) {
                            Text(noneFound.summary)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("gateway-none")
                            Text(noneFound.advice)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("gateway-none-hint")
                        }
                    }
                    if !discovery.skipped.isEmpty {
                        // Offered rather than hidden: a gateway declined for its
                        // owner or its OS is exactly the machine someone on a
                        // shared tailnet is looking for, and the filters stay on
                        // by default because a personal tailnet is mostly phones.
                        DisclosureGroup(isExpanded: $showingSkipped) {
                            ForEach(discovery.skipped, id: \.host) { peer in
                                Button {
                                    discovery.probeAnyway(peer.host)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(peer.host).font(.body.monospaced())
                                        Text(peer.reason).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityIdentifier("gateway-skipped-\(peer.host)")
                            }
                        } label: {
                            Text(discovery.skipped.count == 1
                                 ? "1 computer was not checked"
                                 : "\(discovery.skipped.count) computers were not checked")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("gateway-skipped-summary")
                        }
                    }
                    if discovery.phase == .proxyUnhealthy {
                        Text(proxyUnhealthyText)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("gateway-proxy-unhealthy")
                    }
                    // In the list, not the toolbar: the dashboard's gear sits
                    // over the navigation bar's trailing corner (M5 review).
                    Button {
                        // Continue from where a truncated sweep stopped, so a
                        // large tailnet's tail is reachable at all; a finished
                        // sweep starts over as before (F7 §4.3).
                        discovery.start(savedHost: savedHost, shownAt: .now,
                                        continueFrom: discovery.sweepTruncated
                                            ? discovery.nextCandidateIndex : 0)
                    } label: {
                        // Three labels, because the button makes three different
                        // promises: it is working, it will continue where it
                        // stopped, or it will start over. "Search again" for all
                        // three left the second indistinguishable from the third.
                        Label(refreshLabel, systemImage: "arrow.clockwise")
                    }
                    .disabled(discovery.phase == .probing || !ready)
                    .accessibilityIdentifier("gateway-refresh")
                } header: {
                    Text("Gateways")
                }

                Section {
                    TextField("gateway, or gateway.example.ts.net", text: $manual)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit(useManual)
                        .accessibilityIdentifier("gateway-manual-field")
                    Button("Use this gateway", action: useManual)
                        .disabled(!GatewayCandidates.isPlausibleGatewayName(manual, suffix: suffix))
                        .accessibilityIdentifier("gateway-manual-use")
                    if let manualError {
                        Text(manualError)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("gateway-manual-error")
                    }
                } header: {
                    Text("Enter manually")
                }
            }
            .accessibilityIdentifier("gateway-picker")
            .navigationTitle("Choose a gateway")
            .toolbar {
                if let onCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                // For UI tests: the sweep's end, and what it found.
                if discovery.phase == .finished || discovery.phase == .proxyUnhealthy {
                    // Format: sweep-done:<gateways>:<answered>:<unanswered>.
                    // Appended to, never reordered: existing tests read only the
                    // first field and must keep working (F4 §4.8).
                    Text("sweep-done:\(discovery.gateways.count):\(discovery.answeredCount):\(discovery.unansweredCount)")
                        .accessibilityIdentifier("gateway-sweep-done")
                        .opacity(0.01)
                }
#if LATCHKEY_TEST_HOOKS
                // F16: the chaos hook's progress ("damaged", then "recovered"
                // once the loopback is replaced), which the dashboard's own
                // copy of this element cannot show while the picker is up.
                if TSNetManager.tcpChaosTestRequested(), let status = model.tcpChaosTestStatus {
                    Text(status)
                        .accessibilityIdentifier("tcp-chaos-test-status")
                        .opacity(0.01)
                }
#endif
            }
        }
        .onAppear {
            shownAt = .now
            if sweepOnAppear, ready { discovery.start(savedHost: savedHost, shownAt: shownAt) }
        }
        // Start once the node has a status and a proxy to probe through.
        .task(id: ready) {
            if ready, discovery.phase == .idle {
                discovery.start(savedHost: savedHost, shownAt: shownAt)
            }
        }
        // Nothing outlives the picker: a sweep it no longer shows is stopped.
        .onDisappear { discovery.cancel() }
        // A sweep that ran on a status fetched before the peers arrived finds
        // no candidates, and nothing would start another (M5 review): sweep
        // again when the peer list changes after an empty sweep.
        .onChange(of: model.localStatus?.Peer?.count ?? 0) { _, _ in
            if discovery.phase == .finished, discovery.candidateCount == 0 {
                discovery.start(savedHost: savedHost, shownAt: shownAt)
            }
        }
        .onChange(of: discovery.phase) { _, phase in
            guard autoSelectSingle, !autoSelected, phase == .finished,
                  discovery.gateways.count == 1 else { return }
            autoSelected = true
            onSelect(discovery.gateways[0].url)
        }
    }

    private var suffix: String? { model.localStatus?.CurrentTailnet?.MagicDNSSuffix }

    /// Only a host the tailnet carries: anything else would load direct, off
    /// the tailnet, and become the sign-in origin (M5 review). The check is
    /// `GatewayCandidates.manualGateway`'s, shared with Settings → Gateway,
    /// and it fails closed -- the version that lived here let a host that
    /// did not re-parse, or a missing policy, through.
    private func useManual() {
        switch GatewayCandidates.manualGateway(manual, suffix: suffix, policy: model.proxyPolicy) {
        case .success(let origin):
            manualError = nil
            onSelect(origin)
        case .failure(let refusal):
            manualError = refusal.message
        }
    }

}
