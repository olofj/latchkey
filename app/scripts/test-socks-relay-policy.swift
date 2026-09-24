// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Host tests for App/Network/SocksRelayPolicy.swift and, over loopback, the
// real TSNet/SocksLogProxy.swift (revision R30).
//
// Run:  make test-policy     (or: scripts/test-socks-relay-policy.sh)

import Foundation
import Network

var failures = 0
var checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  FAIL \(what)") }
}

let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
func session(_ id: UInt64, idle: TimeInterval) -> SocksRelayCapacity.Session {
    SocksRelayCapacity.Session(id: id, lastActivity: t0.addingTimeInterval(-idle))
}

print("== capacity")
let cap = SocksRelayCapacity(maxSessions: 3, idleGrace: 60)
expect(cap.admit([], now: t0) == .accept, "empty: accept")
expect(cap.admit([session(1, idle: 0), session(2, idle: 1000)], now: t0) == .accept,
       "below the cap: accept, whatever is idle")
expect(cap.admit([session(1, idle: 0), session(2, idle: 5), session(3, idle: 59.9)], now: t0) == .refuse,
       "at the cap with every session live: refuse")
expect(cap.admit([session(1, idle: 0), session(2, idle: 60), session(3, idle: 5)], now: t0)
       == .acceptEvicting(id: 2, idle: 60), "at the cap, one silent for exactly the grace: evict it")
expect(cap.admit([session(1, idle: 70), session(2, idle: 500), session(3, idle: 65)], now: t0)
       == .acceptEvicting(id: 2, idle: 500), "several silent: the quietest goes")
expect(cap.admit([session(1, idle: 0), session(2, idle: 5), session(3, idle: 59.9), session(4, idle: 61)], now: t0)
       == .acceptEvicting(id: 4, idle: 61), "over the cap (sessions admitted before it fell): still one out, one in")
expect(SocksRelayCapacity(maxSessions: 0).admit([], now: t0) == .refuse, "a cap of zero refuses everything")
let defaults = SocksRelayCapacity()
expect(defaults.maxSessions == 64 && defaults.idleGrace == 60, "defaults: 64 sessions, 60 s grace")

print("== transport failures")
for code in [NSURLErrorBadURL, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost] {
    expect(SocksRelayRecovery.isTransportFailure(domain: NSURLErrorDomain, code: code), "\(code) is a transport failure")
}
expect(!SocksRelayRecovery.isTransportFailure(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
       "a timeout is not: a slow gateway is not a dead listener")
expect(!SocksRelayRecovery.isTransportFailure(domain: "WebKitErrorDomain", code: NSURLErrorBadURL),
       "-1000 in another domain is not")
expect(SocksRelayRecovery.isTransportFailure(URLError(.badURL)) && !SocksRelayRecovery.isTransportFailure(URLError(.serverCertificateUntrusted)),
       "the Error overload agrees")

print("== verdict")
func evidence(code: Int = NSURLErrorCannotConnectToHost, domain: String = NSURLErrorDomain,
              relayInUse: Bool = true, running: Bool = true, recovering: Bool = false,
              upstream: Bool = true, accepted: Bool = false,
              listener: SocksRelayRecovery.ListenerProbe? = nil) -> SocksRelayRecovery.Evidence {
    SocksRelayRecovery.Evidence(
        failure: SocksRelayRecovery.PageFailure(domain: domain, code: code, navigationStartedAt: t0),
        relayInUse: relayInUse, nodeRunning: running, loopbackRecoveryInFlight: recovering,
        upstreamAnswers: upstream, relayAcceptedSinceNavigation: accepted, listener: listener)
}
func leaves(_ e: SocksRelayRecovery.Evidence, _ fragment: String) -> Bool {
    if case .leave(let reason) = SocksRelayRecovery.decide(e) { return reason.contains(fragment) }
    return false
}
for code in [NSURLErrorBadURL, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost] {
    expect(SocksRelayRecovery.decide(evidence(code: code)) == .probe,
           "\(code), Running, loopback answers, relay saw nothing, not yet probed: probe")
    expect(SocksRelayRecovery.decide(evidence(code: code, listener: .refused)) == .restart,
           "\(code), the same, and the listener refused the probe: restart")
    expect(SocksRelayRecovery.decide(evidence(code: code, listener: .timedOut)) == .restart,
           "\(code), the same, and the probe timed out: restart")
    expect(leaves(evidence(code: code, listener: .answers), "the listener answers"),
           "\(code), the same, but the listener answers the probe: leave (a pooled connection, or a load that never dialed)")
}
expect(leaves(evidence(relayInUse: false), "not in use"), "-NoSocksLog, or a listener that never started: leave")
expect(leaves(evidence(code: NSURLErrorTimedOut), "not a transport failure"), "a timeout: leave")
expect(leaves(evidence(code: NSURLErrorBadURL, domain: "WebKitErrorDomain"), "not a transport failure"), "another domain: leave")
expect(leaves(evidence(running: false), "not Running"), "node not Running: leave (nothing to reach anyway)")
expect(leaves(evidence(recovering: true), "loopback recovery"), "loopback recovery in flight: it replaces the relay itself")
expect(leaves(evidence(upstream: false), "not answering"), "tsnet's loopback dead: leave, that is the status poll's to repair")
expect(leaves(evidence(accepted: true), "accepted the request"),
       "the relay accepted the load (a dead gateway is also -1000): the failure lies beyond it")
expect(leaves(evidence(accepted: true, listener: .refused), "accepted the request"),
       "and that verdict does not wait for a probe, even one in hand")
expect(leaves(evidence(relayInUse: false, listener: .refused), "not in use"),
       "a refused probe of a relay not in use restarts nothing")
expect(evidence(listener: nil).probed(.refused).listener == .refused
       && evidence(accepted: true).probed(.answers).relayAcceptedSinceNavigation,
       "probed(_:) adds the finding and keeps the rest")
expect(SocksRelayRecovery.decide(probe: .refused) == .restart && SocksRelayRecovery.decide(probe: .timedOut) == .restart,
       "an unprompted probe (foreground, unanswered session check) that fails: restart")
if case .leave(let why) = SocksRelayRecovery.decide(probe: .answers) {
    expect(why.contains("answers"), "an unprompted probe that is answered: leave, saying so")
} else {
    expect(false, "an unprompted probe that is answered: leave")
}

print("== budget")
var budget = SocksRelayRecovery.Budget()
expect(budget.allow(now: t0) && budget.allow(now: t0.addingTimeInterval(5)), "two restarts a minute")
expect(!budget.allow(now: t0.addingTimeInterval(10)) && !budget.allow(now: t0.addingTimeInterval(59)),
       "the third inside the window is refused")
expect(budget.recent.count == 2, "a refusal does not consume budget")
expect(budget.allow(now: t0.addingTimeInterval(60)) && !budget.allow(now: t0.addingTimeInterval(61))
       && budget.allow(now: t0.addingTimeInterval(65)), "the budget refills as restarts age out")

// MARK: - The relay itself, over loopback

/// Accepts and holds every connection; never speaks. What an idle tsnet
/// listener looks like to the relay.
nonisolated final class FakeUpstream: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "kr-test-upstream")
    private let lock = NSLock()
    private var held: [NWConnection] = []
    private let accepted = DispatchSemaphore(value: 0)
    private let ready = DispatchSemaphore(value: 0)

    init() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params)
    }

    func start() -> UInt16 {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            lock.lock()
            held.append(connection)
            lock.unlock()
            accepted.signal()
        }
        listener.stateUpdateHandler = { [self] state in
            if case .ready = state { ready.signal() }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        return listener.port?.rawValue ?? 0
    }

    /// One accept, consumed.
    func waitForAccept(_ seconds: TimeInterval = 5) -> Bool {
        accepted.wait(timeout: .now() + seconds) == .success
    }

    func stop() {
        listener.cancel()
        lock.lock()
        for c in held { c.cancel() }
        held.removeAll()
        lock.unlock()
    }
}

/// Echoes every chunk back and counts the bytes: an upstream that answers.
nonisolated final class EchoUpstream: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "kr-test-echo")
    private let lock = NSLock()
    private var held: [NWConnection] = []
    private var receivedCount = 0
    private let accepted = DispatchSemaphore(value: 0)
    private let ready = DispatchSemaphore(value: 0)

    init() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params)
    }

    func start() -> UInt16 {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            lock.lock()
            held.append(connection)
            lock.unlock()
            echo(connection)
            accepted.signal()
        }
        listener.stateUpdateHandler = { [self] state in
            if case .ready = state { ready.signal() }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        return listener.port?.rawValue ?? 0
    }

    private func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                lock.lock(); receivedCount += data.count; lock.unlock()
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
            if !isComplete && error == nil { echo(connection) }
        }
    }

    var received: Int {
        lock.lock()
        defer { lock.unlock() }
        return receivedCount
    }

    func waitForAccept(_ seconds: TimeInterval = 5) -> Bool {
        accepted.wait(timeout: .now() + seconds) == .success
    }

    func stop() {
        listener.cancel()
        lock.lock()
        for c in held { c.cancel() }
        held.removeAll()
        lock.unlock()
    }
}

/// A client of the relay that reports when the relay closes on it.
nonisolated final class Client: @unchecked Sendable {
    private let connection: NWConnection
    private let readySem = DispatchSemaphore(value: 0)
    private let closedSem = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var closedFlag = false
    private static let queue = DispatchQueue(label: "kr-test-client")

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any, using: .tcp)
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                readySem.signal()
                watchForClose()
            case .failed, .cancelled:
                markClosed()
            case .waiting:
                // A refused connect (nothing listening on the port) parks an
                // NWConnection in `.waiting` for a better path, not `.failed`.
                // For these tests that is "closed".
                markClosed()
            default:
                break
            }
        }
        connection.start(queue: Self.queue)
    }

    private func watchForClose() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                lock.lock(); receivedCount += data.count; lock.unlock()
            }
            if isComplete || error != nil { markClosed() } else { watchForClose() }
        }
    }

    private var receivedCount = 0
    /// Bytes the relay delivered back to this client.
    var received: Int {
        lock.lock()
        defer { lock.unlock() }
        return receivedCount
    }

    private func markClosed() {
        lock.lock()
        let first = !closedFlag
        closedFlag = true
        lock.unlock()
        if first { closedSem.signal() }
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closedFlag
    }

    func waitReady(_ seconds: TimeInterval = 5) -> Bool { readySem.wait(timeout: .now() + seconds) == .success }
    func waitClosed(_ seconds: TimeInterval = 5) -> Bool { closedSem.wait(timeout: .now() + seconds) == .success }
    func cancel() { connection.cancel() }

    /// A byte through the relay: traffic, as the cap's `lastActivity` sees it.
    func send(_ byte: UInt8) {
        connection.send(content: Data([byte]), completion: .contentProcessed { _ in })
    }
}

/// Polls `condition` for up to `seconds`: the relay finishes sessions on its
/// own queue, a beat after the client hangs up.
func eventually(_ seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() >= deadline { return false }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return true
}

/// `SocksLogProxy.probe`, waited for.
func probe(_ port: UInt16, timeout: TimeInterval = 2) -> SocksRelayRecovery.ListenerProbe? {
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    nonisolated(unsafe) var outcome: SocksRelayRecovery.ListenerProbe?
    SocksLogProxy.probe(port: port, timeout: timeout) { found in
        lock.lock(); outcome = found; lock.unlock()
        done.signal()
    }
    guard done.wait(timeout: .now() + timeout + 2) == .success else { return nil }
    lock.lock(); defer { lock.unlock() }
    return outcome
}

/// `restartListener(completion:)`, waited for.
func restart(_ relay: SocksLogProxy) -> UInt16? {
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    nonisolated(unsafe) var port: UInt16?
    relay.restartListener { found in
        lock.lock(); port = found; lock.unlock()
        done.signal()
    }
    guard done.wait(timeout: .now() + SocksLogProxy.startTimeout + 2) == .success else { return nil }
    lock.lock(); defer { lock.unlock() }
    return port
}

/// A port nothing listens on: bound, released, and asked for from the OS,
/// which does not hand it out again at once.
func unusedPort() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
            bind(fd, p, len) == 0 && getsockname(fd, p, &len) == 0
        }
    }
    guard bound else { return 0 }
    return UInt16(bigEndian: addr.sin_port)
}

print("== the relay: refusing at the cap")
let upstream = try! FakeUpstream()
let upstreamPort = upstream.start()
expect(upstreamPort != 0, "the fake upstream listens")
let beforeStart = Date()
let strict = SocksLogProxy(upstreamHost: "127.0.0.1", upstreamPort: upstreamPort,
                           capacity: SocksRelayCapacity(maxSessions: 2, idleGrace: 3600))
let strictPort = strict.start() ?? 0
expect(strictPort != 0, "the relay listens: \(logger.lines.last ?? "-")")
expect(!strict.hasAcceptedSession(since: .distantPast), "nothing accepted yet")
let c1 = Client(port: strictPort)
expect(upstream.waitForAccept(), "the first client is relayed to the upstream")
let c2 = Client(port: strictPort)
expect(upstream.waitForAccept(), "so is the second")
expect(strict.activeSessionCount == 2, "two sessions live: \(strict.activeSessionCount)")
expect(strict.hasAcceptedSession(since: beforeStart), "accepted since before the relay started")
expect(!strict.hasAcceptedSession(since: Date().addingTimeInterval(10)), "nothing accepted from the future")
let c3 = Client(port: strictPort)
expect(c3.waitClosed(), "the third, with both live inside the grace, is closed by the relay")
expect(!upstream.waitForAccept(0.5), "and never reaches the upstream")
expect(strict.activeSessionCount == 2, "the two live sessions are untouched: \(strict.activeSessionCount)")
expect(!c1.isClosed && !c2.isClosed, "neither live client was disturbed")
expect(logger.lines.contains { $0.contains("sockslog: at capacity") && $0.contains("refusing") },
       "the refusal is logged: \(logger.lines.suffix(3))")

print("== the relay: the self-probe")
expect(strict.listenerStarts == 1, "one listener so far: \(strict.listenerStarts)")
expect(probe(strictPort) == .answers, "the listener answers a probe")
expect(!upstream.waitForAccept(0.3),
       "at the cap, with both sessions live, the relay refused the probe's connection; the listener answered all the same")
expect(eventually { strict.activeSessionCount == 2 }, "and the two live sessions are untouched: \(strict.activeSessionCount)")
let deadPort = unusedPort()
expect(deadPort != 0 && probe(deadPort) == .refused, "a port nothing listens on refuses the probe (\(deadPort))")
expect(logger.lines.contains { $0.contains("sockslog: probe of 127.0.0.1:\(deadPort) refused") },
       "the refusal is logged, with the port and no more: \(logger.lines.suffix(2))")

print("== the relay: restarting the listener")
// Not at the cap for this: a client of the old port must be able to tell a
// listener that is gone from one that refuses at capacity.
c2.cancel()
expect(eventually { strict.activeSessionCount == 1 }, "one session left before the restart: \(strict.activeSessionCount)")
let restartedPort = restart(strict) ?? 0
expect(restartedPort != 0, "a listener again, on \(restartedPort) (was \(strictPort))")
expect(strict.listenerStarts == 2, "and it is a new one: listener \(strict.listenerStarts)")
expect(!c1.isClosed, "sessions survive a listener restart")
if restartedPort != strictPort {
    // The OS may hand the same ephemeral port out again; only when it did
    // not is the old port's refusal the old listener's absence.
    expect(probe(strictPort) == .refused, "the old port no longer answers")
} else {
    print("  (the OS reused the port; the old listener is gone by generation)")
}
expect(probe(restartedPort) == .answers, "the new port answers")
expect(upstream.waitForAccept(), "(the probe's connection, relayed)")
expect(eventually { strict.activeSessionCount == 1 }, "still one session: \(strict.activeSessionCount)")
let c4 = Client(port: restartedPort)
expect(upstream.waitForAccept(), "a client of the new port is relayed")
let c5 = Client(port: restartedPort)
expect(c5.waitClosed(), "the new port applies the same cap")
c1.cancel()
strict.stop()
expect(eventually { probe(restartedPort, timeout: 0.5) == .refused }, "after stop() the port refuses the probe")
expect(upstream.waitForAccept(0.2) == false, "(no stray accepts)")
c3.cancel(); c4.cancel(); c5.cancel()

print("== the relay: evicting the quietest at the cap")
let lenient = SocksLogProxy(upstreamHost: "127.0.0.1", upstreamPort: upstreamPort,
                            capacity: SocksRelayCapacity(maxSessions: 2, idleGrace: 0))
let lenientPort = lenient.start() ?? 0
expect(lenientPort != 0, "the second relay listens")
let e1 = Client(port: lenientPort)
expect(upstream.waitForAccept(), "first relayed")
let e2 = Client(port: lenientPort)
expect(upstream.waitForAccept(), "second relayed")
let e3 = Client(port: lenientPort)
expect(upstream.waitForAccept(), "the third is relayed too, at the cap")
expect(e1.waitClosed(), "because the quietest, the first, was evicted")
expect(!e2.isClosed && !e3.isClosed, "the other two stay")
expect(lenient.activeSessionCount == 2, "and the count holds at the cap: \(lenient.activeSessionCount)")
expect(logger.lines.contains { $0.contains("sockslog: at capacity") && $0.contains("evicting socks[") },
       "the eviction is logged: \(logger.lines.suffix(3))")
lenient.stop()
e1.cancel(); e2.cancel(); e3.cancel()

print("== the relay: traffic keeps a session; silence past the grace does not")
// The oldest session carries bytes the whole time; the second says nothing.
// With a real grace, the second is the quietest at the cap, not the first.
let grace: TimeInterval = 1
let busy = SocksLogProxy(upstreamHost: "127.0.0.1", upstreamPort: upstreamPort,
                         capacity: SocksRelayCapacity(maxSessions: 2, idleGrace: grace))
let busyPort = busy.start() ?? 0
expect(busyPort != 0, "the third relay listens")
let b1 = Client(port: busyPort)
expect(b1.waitReady() && upstream.waitForAccept(), "the first (oldest) relayed")
let b2 = Client(port: busyPort)
expect(b2.waitReady() && upstream.waitForAccept(), "the second relayed")
let talkUntil = Date().addingTimeInterval(grace * 1.5)
while Date() < talkUntil {
    b1.send(0x05)
    Thread.sleep(forTimeInterval: 0.1)
}
let b3 = Client(port: busyPort)
expect(upstream.waitForAccept(), "the third, arriving after the grace, is relayed")
expect(b2.waitClosed(), "the silent second was evicted")
expect(!b1.isClosed, "the oldest, still talking, was not: its traffic refreshed lastActivity")
expect(!b3.isClosed && busy.activeSessionCount == 2, "two sessions: \(busy.activeSessionCount)")
expect(logger.lines.contains { $0.contains("evicting socks[") && $0.contains("silent for 1s") },
       "the eviction names the silence: \(logger.lines.suffix(3))")
busy.stop()
b1.cancel(); b2.cancel(); b3.cancel()
upstream.stop()

print("== the relay: stopped and released, it carries its sessions to their end")
// A loopback recovery stops the relay and drops the manager's reference while
// the page's keep-alive connections are still open (M6 review). Each one must
// go on relaying, chunk after chunk, both ways -- not relay one more chunk
// and then hang with the socket open, which is what WebKit's next request on
// it did.
let echo = try! EchoUpstream()
let echoPort = echo.start()
expect(echoPort != 0, "the echo upstream listens")
var released: SocksLogProxy? = SocksLogProxy(upstreamHost: "127.0.0.1", upstreamPort: echoPort)
let releasedPort = released?.start() ?? 0
expect(releasedPort != 0, "the fourth relay listens")
let r1 = Client(port: releasedPort)
expect(r1.waitReady() && echo.waitForAccept(), "a session through it")
weak var releasedRelay = released
released?.stop()
released = nil
for byte in UInt8(1)...5 {
    r1.send(byte)
    Thread.sleep(forTimeInterval: 0.1)  // one chunk each
}
expect(eventually { echo.received == 5 }, "all five chunks reached the upstream after the release: \(echo.received)")
expect(eventually { r1.received == 5 }, "and all five echoes came back: \(r1.received)")
expect(!r1.isClosed, "the session is still open")
expect(releasedRelay != nil, "the live session is what keeps the released relay alive")
r1.cancel()
expect(eventually { releasedRelay == nil }, "and the session's end lets it go")

print("== the relay: stopped and released with no session, its port is closed")
// The real device's shape (M6 review): iOS defuncted every session during the
// suspension, so nothing holds the relay when the recovery releases it. The
// listener must still close, not linger accepting connections nobody serves.
var idle: SocksLogProxy? = SocksLogProxy(upstreamHost: "127.0.0.1", upstreamPort: echoPort)
let idlePort = idle?.start() ?? 0
expect(idlePort != 0, "the fifth relay listens")
weak var idleRelay = idle
idle?.stop()
idle = nil
expect(eventually { probe(idlePort, timeout: 0.5) == .refused }, "its port refuses the probe")
expect(eventually { idleRelay == nil }, "and the relay is freed")
echo.stop()

print(failures == 0 ? "\(checks)/\(checks) SOCKS relay checks passed" : "\(failures) of \(checks) SOCKS relay checks FAILED")
exit(failures == 0 ? 0 : 1)
