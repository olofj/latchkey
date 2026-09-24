// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  PageStateView.swift
//  Latchkey
//
//  What is drawn over the web view's area while the page is not showing
//  (F4 §3.1, §3.3, §3.4, §4.6). `EmptyView` once the page has committed.
//
//  Three things here are not stylistic choices:
//
//  1. The block is OPAQUE, on the system background. A control at opacity < 1
//     over a WKWebView gets no taps (found in M8), and every one of these
//     blocks carries a button the owner is meant to be able to press.
//  2. The web view is NOT removed from the hierarchy for these states (see
//     BrowserView): tearing it down mid-load cancels the very load being
//     described, and re-creating it on retry costs a makeUIView.
//  3. The 300 ms delay before anything appears. Below it a block that appears
//     and is immediately replaced reads as a flicker; a loopback commit on the
//     harness is well under it, so a healthy load never shows it at all, while
//     a real relayed path (measured: 190 ms RTT direct, more over DERP, and a
//     load is TCP + TLS + GET) is over it — and by then the owner IS waiting.
//

import SwiftUI

struct PageStateView: View {
    let state: PageState
    /// D3: the gateway is not in the tailnet. Owned by the banner above, whose
    /// Find and Change are the single presentation path (M5 review), so the body
    /// here explains and offers nothing.
    var gatewayMissing: Bool = false
    var onRetry: () -> Void = {}
    var onChooseGateway: () -> Void = {}

    /// Before this, nothing is drawn. `PageState.connecting`'s `since` is the
    /// first attempt's, so silent startup retries do not restart it.
    static let showDelay: Duration = .milliseconds(300)
    /// When "still trying" appears, and its button with it. Twice R39's 4 s
    /// per-probe budget, which was sized from a real relayed intercontinental
    /// path: a load that has not committed by then is not slow, it is stuck.
    static let connectingHintDelay: Duration = .seconds(8)
    /// Three status polls (5 s each). On a relaunch the peer list arrives in one
    /// or two.
    static let holdingHintDelay: Duration = .seconds(15)

    @State private var pastShowDelay = false

    var body: some View {
        switch state {
        case .connecting(let host, let port, let since, _):
            delayed(since: since) {
                block {
                    Waiting(title: "Connecting to \(PageFailureText.displayHost(host, port: port))…",
                            detail: "over your tailnet",
                            since: since,
                            identifier: "page-connecting",
                            hostIdentifier: "page-connecting-host")
                    hint(since: since, after: Self.connectingHintDelay, id: "page-connecting-hint",
                         text: "Still trying. A gateway on the tailnet normally answers within a "
                             + "few seconds. If this device is new, it may not be allowed to reach "
                             + "\(host) yet — whoever manages the tailnet needs this device's "
                             + "address, shown in Settings → Status.") {
                        Button("Choose another gateway", action: onChooseGateway)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("page-connecting-choose-gateway")
                    }
                }
            }
        case .holding(let host, let since):
            delayed(since: since) {
                block {
                    Waiting(title: "Waiting for the tailnet's peer list before opening \(host)…",
                            detail: nil,
                            since: since,
                            identifier: "page-holding",
                            hostIdentifier: nil)
                    // No button: there is nothing to retry, and the picker would
                    // find nothing without a peer list either.
                    hint(since: since, after: Self.holdingHintDelay, id: "page-holding-hint",
                         text: "Still waiting for the node's peer list. Settings → Status shows "
                             + "the node's state and how many peers it sees; Settings → Node log "
                             + "shows what it is doing.")
                }
            }
        case .failed(let failure):
            NavErrorPage(failure: failure, onRetry: onRetry, onChooseGateway: onChooseGateway)
        case .idle, .committed:
            if gatewayMissing {
                block {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This gateway isn't in your tailnet right now.")
                            .font(.headline)
                        Text("Latchkey checks again as the tailnet updates. *Find* lists the "
                             + "gateways it can see; *Change* lets you correct the name.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("page-gateway-missing")
                }
            }
        }
    }

    // MARK: - Pieces

    /// Nothing for `showDelay`, then the content. `task(id:)` restarts the wait
    /// whenever the state's `since` changes, so a new load gets a fresh delay
    /// and a startup retry (which keeps `since`) does not.
    @ViewBuilder
    private func delayed<Content: View>(since: ContinuousClock.Instant,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            if pastShowDelay { content() }
        }
        .task(id: since) {
            pastShowDelay = false
            try? await Task.sleep(for: Self.showDelay)
            if !Task.isCancelled { pastShowDelay = true }
        }
    }

    /// The opaque full-size container. Opaque because a control drawn at less
    /// than full opacity over a WKWebView receives no taps (M8).
    @ViewBuilder
    private func block<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 20) { content() }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.platformSystemBackground)
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func hint<Buttons: View>(since: ContinuousClock.Instant, after delay: Duration,
                                     id: String, text: String,
                                     @ViewBuilder buttons: @escaping () -> Buttons = { EmptyView() })
        -> some View {
        StalledHint(since: since, delay: delay, text: text, identifier: id, buttons: buttons)
    }

    /// Indicator, title, and a ticking duration.
    private struct Waiting: View {
        let title: String
        let detail: String?
        let since: ContinuousClock.Instant
        let identifier: String
        let hostIdentifier: String?

        var body: some View {
            VStack(spacing: 12) {
                ProgressView()
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier(hostIdentifier ?? identifier)
                // The number ticks; the accessibility LABEL does not, so
                // VoiceOver reads "elapsed" on focus and does not announce a new
                // value every second.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let seconds = PageState.elapsedSeconds(since: since)
                    Text(detail.map { "\($0) · \(seconds) s" } ?? "\(seconds) s")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("\(identifier)-elapsed")
                        .accessibilityLabel("elapsed")
                        .accessibilityValue("\(seconds) s")
                }
            }
            .accessibilityIdentifier(identifier)
        }
    }
}

/// "This is taking longer than it should", with what to do about it — shown once
/// `delay` has passed since `since` (F4 §4.10).
///
/// One view, used by the page block, the gateway picker and the tailnet gate.
/// The alternative was the same threshold-and-wording pattern written three
/// times, which is precisely how this codebase has produced its recurring class
/// of bug: a rule carried to one of its sites and not the others.
struct StalledHint<Buttons: View>: View {
    let since: ContinuousClock.Instant
    let delay: Duration
    let text: String
    let identifier: String
    @ViewBuilder let buttons: () -> Buttons

    init(since: ContinuousClock.Instant, delay: Duration, text: String, identifier: String,
         @ViewBuilder buttons: @escaping () -> Buttons = { EmptyView() }) {
        self.since = since
        self.delay = delay
        self.text = text
        self.identifier = identifier
        self.buttons = buttons
    }

    var body: some View {
        // Its own timeline, so the hint arrives without the whole block
        // redrawing on a schedule it does not need.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if PageState.hintIsDue(since: since, delay: delay) {
                VStack(spacing: 14) {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(identifier)
                    buttons()
                }
            }
        }
    }
}
