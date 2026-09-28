// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  MainThreadStallProbe.swift
//  Latchkey
//
//  L1's instruments for F16 stage 3 (Testing builds only), with
//  `-UITestMainThreadMonitor`:
//
//  - `main-thread-max-stall-ms`: the longest the main queue took to run a
//    block posted to it late in a relay start, in ms. A background timer
//    posts one every 50 ms and measures how late it ran. Only blocks posted
//    inside a window count: it opens `-UITestMainThreadMonitor <s>` seconds
//    after a relay start begins, off the main thread, and closes when the
//    start ends (`TSNetManager.startRelayIfNeeded`). Not from the start
//    itself: in L1 the first start runs during the launch, and a cold
//    launch blocks the main thread for up to about 1.4 s on its own
//    (measured: gaps of 957 ms), which says nothing about the relay. A start
//    that blocked the main actor on its listener blocks it past the window
//    too, and shows as most of the window here.
//  - `relay-requests`: SOCKS requests the app's relay has parsed. The stub
//    proxy's journal shows a CONNECT whether WebKit dialled it through the
//    relay or directly, so this is what tells the two apart.
//
//  Both read live when a test asks, as `PresentationProbe` does.
//

#if LATCHKEY_TEST_HOOKS
import Foundation

nonisolated final class MainThreadStallMonitor: @unchecked Sendable {
    static let shared = MainThreadStallMonitor()

    private let lock = NSLock()
    private var maxStallNanos: UInt64 = 0
    private var openWindows = 0
    private var timer: DispatchSourceTimer?

    /// A measurement window: opened after a delay, on a background queue so
    /// a blocked main thread cannot hold it shut; closing it first means it
    /// never opens.
    final class Window: @unchecked Sendable {
        fileprivate var closed = false
        fileprivate var opened = false
    }

    /// Opens a window `seconds` after now, if `-UITestMainThreadMonitor`
    /// named a delay; otherwise nil.
    func window() -> Window? {
        guard let seconds = TestHooks.value("-UITestMainThreadMonitor").flatMap(Double.init) else { return nil }
        let w = Window()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            lock.withLock {
                guard !w.closed else { return }
                w.opened = true
                openWindows += 1
            }
        }
        return w
    }

    func close(_ w: Window) {
        lock.withLock {
            guard !w.closed else { return }
            w.closed = true
            if w.opened { openWindows -= 1 }
        }
    }

    var maxStallMs: Int {
        lock.withLock { Int(maxStallNanos / 1_000_000) }
    }

    func start() {
        lock.withLock {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
            t.schedule(deadline: .now(), repeating: .milliseconds(50))
            t.setEventHandler { [self] in
                guard lock.withLock({ openWindows > 0 }) else { return }
                let posted = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.main.async { [self] in
                    let late = DispatchTime.now().uptimeNanoseconds &- posted
                    lock.withLock { maxStallNanos = max(maxStallNanos, late) }
                }
            }
            t.resume()
            timer = t
        }
    }
}

#endif

#if LATCHKEY_TEST_HOOKS && canImport(UIKit)
import SwiftUI
import UIKit

struct MainThreadStallProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let stack = UIStackView(arrangedSubviews: [
            ProbeView(id: "main-thread-max-stall-ms") { "\(MainThreadStallMonitor.shared.maxStallMs)" },
            ProbeView(id: "relay-requests") { "\(SocksLogProxy.relayedRequestCount)" },
        ])
        stack.distribution = .fillEqually
        stack.isUserInteractionEnabled = false
        return stack
    }
    func updateUIView(_ view: UIView, context: Context) {}

    private final class ProbeView: UIView {
        private let read: () -> String
        init(id: String, read: @escaping () -> String) {
            self.read = read
            super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            isAccessibilityElement = true
            accessibilityIdentifier = id
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        override var accessibilityValue: String? {
            get { read() }
            set {}
        }
    }
}
#endif
