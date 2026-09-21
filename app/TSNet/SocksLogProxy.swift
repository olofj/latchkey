// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//
//  SocksLogProxy.swift
//  Latchkey
//
//  A tiny SOCKS5 pass-through relay that sits between WebKit and tsnet's real
//  SOCKS5 proxy, logging **every** connection attempt and its outcome.
//
//  ## Why this exists
//
//  When chasing the "invalid URL" (-1000) failures, the single most valuable
//  fact is: *for a given URL, did the request reach the proxy at all, and if so
//  what did tsnet say?* That distinguishes the two candidate mechanisms:
//
//   * **iOS never sent it to us** \u2014 the OS matched `matchDomains`, decided the
//     host wasn't ours, and resolved/dialed it itself. Nothing appears here.
//   * **It reached us and tsnet couldn't dial it** \u2014 a CONNECT appears here with
//     a non-zero SOCKS reply code. (Measured: WebKit reports -1000 for *every*
//     SOCKS failure reply, so the error code alone can't tell you which.)
//
//  tsnet's own SOCKS server (`net/socks5`) only logs *failures*, and not the
//  reply code, so absence of its log lines proves nothing. This relay logs both
//  directions explicitly.
//
//  It is also the only diagnostic channel on a device that can't be attached to
//  a Mac (no `log stream`, no Console.app) \u2014 pair it with Settings \u2192 Logs.
//
//  ## How it works
//
//  Listens on 127.0.0.1 (an OS-assigned port) and relays bytes verbatim to
//  tsnet's loopback SOCKS5 address. It does not modify the stream: it *parses a
//  copy* of the first few messages in each direction to recover the requested
//  host/port and the reply code, then gets out of the way and pumps bytes.
//  Credentials pass through untouched, so tsnet's auth is unaffected.
//
//  Enabled by default (the logging is cheap and the diagnostic value is high);
//  set `APERTURE_NO_SOCKS_LOG=1` / `-NoSocksLog` to bypass it and point WebKit
//  straight at tsnet.
//
//  ## Housekeeping (R30)
//
//  Being in the data path by default, the relay is bounded: `SocksRelayCapacity`
//  caps concurrent sessions and picks who goes at the cap. And its own
//  listener can be defuncted by iOS while tsnet's stays up (see
//  `restartListener`); `TSNetManager` asks this object whether it accepted
//  anything for a failed load, probes the port with a loopback connect
//  (`probe`), and restarts the listener when the probe fails. Both decisions
//  are in `App/Network/SocksRelayPolicy.swift`. Everything mutable here is
//  confined to `queue`; a listener that reports failure after it was ready
//  is handed to `onListenerFailed`, so the manager can replace it.
//

import Foundation
import Network

/// Relays SOCKS5 traffic to tsnet's proxy, logging each attempt + outcome.
///
/// `@unchecked Sendable`: state is confined to `queue`, a serial dispatch queue
/// (Network.framework hands callbacks there), not to an actor \u2014 `NWListener`'s
/// callback API isn't async, and the relay must be usable from the nonisolated
/// contexts that start the node.
nonisolated final class SocksLogProxy: @unchecked Sendable {

    /// Whether the relay should be used at all. On by default; the logging is a
    /// few lines per navigation. Disable with `-NoSocksLog` /
    /// `APERTURE_NO_SOCKS_LOG=1` to point WebKit directly at tsnet (useful to
    /// rule the relay itself out of any investigation).
    nonisolated static func isEnabled() -> Bool {
        // The off switch is a test hook (R15); R10's anti-leak variant needs
        // it, because with the relay on WebKit always talks to an in-app
        // listener, which masks the proxy-unreachable path.
        if TestHooks.environment("APERTURE_NO_SOCKS_LOG") == "1" { return false }
        return !TestHooks.flag("-NoSocksLog")
    }

    /// tsnet's loopback SOCKS5 listener. Read by the manager if a restart
    /// cannot start a listener and WebKit has to be pointed at tsnet directly.
    let upstreamHost: String
    let upstreamPort: UInt16
    private let capacity: SocksRelayCapacity
    /// Called, on the relay's queue, when a listener that had reached
    /// `.ready` reports `.failed` (R30 review): iOS reporting a defuncted
    /// listener rather than leaving it looking alive. The manager replaces
    /// it, within its restart budget. The listener is already gone by then.
    private let onListenerFailed: (@Sendable () -> Void)?
    private let queue = DispatchQueue(label: "net.lixom.latchkey.sockslog")
    /// Confined to `queue`, as is every other mutable thing here: `start`,
    /// `stop`, `restartListener` and the state handlers all touch it there.
    private var listener: NWListener?
    /// Listeners that reached `.ready` so far. The log carries it, and the
    /// host tests tell a restarted listener from the old one by it: an
    /// ephemeral port can be handed out twice.
    private var listenerGeneration: UInt64 = 0
    /// Monotonic id so a CONNECT and its reply can be correlated in the log.
    private var nextID: UInt64 = 1
    private var activeClients: [UInt64: NWConnection] = [:]
    private var activeUpstreams: [UInt64: NWConnection] = [:]
    /// Parse state and last activity per admitted session (R30).
    private var sessions: [UInt64: Session] = [:]
    private var lifecycleEvents: UInt64 = 0
    /// When the listener last accepted a client: the evidence a failed page
    /// load is judged against (R30).
    private var lastAcceptedAt: Date?
    private var refusals: UInt64 = 0
    private var evictions: UInt64 = 0

    init(upstreamHost: String, upstreamPort: UInt16,
         capacity: SocksRelayCapacity = SocksRelayCapacity(),
         onListenerFailed: (@Sendable () -> Void)? = nil) {
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
        self.capacity = capacity
        self.onListenerFailed = onListenerFailed
    }

    /// How long a listener may take to reach `.ready` before it is given up
    /// on. Loopback takes microseconds; this is the pathological bound.
    nonisolated static let startTimeout: TimeInterval = 3

    /// Starts listening and returns the local port WebKit should point at, or
    /// nil if the listener couldn't start (caller then uses tsnet directly).
    /// Waits for the port (see `startListener`): the proxy configuration is
    /// built synchronously from it when the node comes up.
    func start() -> UInt16? {
        let result = Box<UInt16?>(nil)
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            startListener { port in
                result.value = port
                done.signal()
            }
        }
        _ = done.wait(timeout: .now() + Self.startTimeout + 1)
        return result.value
    }

    /// Creates a listener on `queue` and hands `completion` (also on `queue`)
    /// its port once it is `.ready`, or nil if it failed, was cancelled, or
    /// took longer than `startTimeout`. Exactly one completion.
    ///
    /// The OS assigns the port asynchronously: `listener.port` is 0 (or nil)
    /// until the listener actually reaches `.ready`, so that state is waited
    /// for rather than `.port` polled — otherwise WebKit gets pointed at
    /// port 0 and every load fails.
    private func startListener(completion: @escaping @Sendable (UInt16?) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let l: NWListener
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            params.allowLocalEndpointReuse = true
            l = try NWListener(using: params)
        } catch {
            logger.log("sockslog: failed to start (\(error)); using tsnet proxy directly")
            completion(nil)
            return
        }
        l.newConnectionHandler = { [weak self] conn in
            self?.handle(client: conn)
        }

        let progress = StartProgress()
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !progress.settled else { return }
                progress.settled = true
                guard let port = l.port?.rawValue, port != 0 else {
                    logger.log("sockslog: listener ready without a port; using tsnet proxy directly")
                    l.cancel()
                    completion(nil)
                    return
                }
                progress.ready = true
                self.listener = l
                self.listenerGeneration &+= 1
                logger.log("sockslog: relay listening on 127.0.0.1:\(port) -> tsnet \(self.upstreamHost):\(self.upstreamPort) (listener \(self.listenerGeneration))")
                completion(port)
            case .failed(let error):
                if progress.ready {
                    // After `.ready`: iOS reporting the defuncted listener.
                    // It is dead; say so to the manager (R30 review).
                    logger.log("sockslog: listener failed after ready: \(error); asking for a replacement")
                    if self.listener === l { self.listener = nil }
                    self.onListenerFailed?()
                } else if !progress.settled {
                    progress.settled = true
                    logger.log("sockslog: listener failed: \(error); using tsnet proxy directly")
                    completion(nil)
                }
            case .cancelled:
                // Our own doing (stop, restart, the test hook), unless it
                // happened before ready, when it ends the start.
                if !progress.settled {
                    progress.settled = true
                    completion(nil)
                }
            case .waiting(let error):
                logger.log("sockslog: listener waiting: \(error)")
            default:
                break
            }
        }
        l.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.startTimeout) {
            guard !progress.settled else { return }
            progress.settled = true
            logger.log("sockslog: listener not ready after \(Int(Self.startTimeout))s (state=\(l.state)); using tsnet proxy directly")
            l.cancel()
            completion(nil)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
        }
    }

    /// Replaces only the app-owned listening socket after iOS suspension.
    /// Existing relay sessions keep using this object and are not disturbed.
    /// Apple may defunct a loopback listener while leaving its NWListener object
    /// apparently alive; a fresh OS-assigned port is therefore required.
    /// Called by `TSNetManager.restartSocksRelay` on `SocksRelayRecovery`'s
    /// verdict (R30); the caller republishes the proxy configuration.
    /// Asynchronous: nothing waits on the main actor for the new port (R30
    /// review). `completion` runs on the relay's queue.
    func restartListener(completion: @escaping @Sendable (UInt16?) -> Void) {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            startListener(completion: completion)
        }
    }

    /// `restartListener(completion:)`, awaited.
    func restartListener() async -> UInt16? {
        await withCheckedContinuation { continuation in
            restartListener { continuation.resume(returning: $0) }
        }
    }

    /// Whether the listener accepted a client at or after `since`: for a page
    /// load that failed, whether the load reached the relay at all (R30).
    func hasAcceptedSession(since: Date) -> Bool {
        queue.sync { lastAcceptedAt.map { $0 >= since } ?? false }
    }

    /// Sessions being relayed right now.
    var activeSessionCount: Int {
        queue.sync { sessions.count }
    }

    /// How many listeners have reached `.ready` in this relay's life.
    var listenerStarts: UInt64 {
        queue.sync { listenerGeneration }
    }

    // MARK: - The self-probe (R30 review)

    /// How long a probe waits for the connect to be accepted or refused. A
    /// live loopback listener answers in microseconds; a defuncted socket
    /// refuses at once or, at worst, drops the SYN.
    nonisolated static let probeTimeout: TimeInterval = 2
    nonisolated private static let probeQueue = DispatchQueue(label: "net.lixom.latchkey.sockslog.probe")

    /// Whether anything accepts a TCP connection on 127.0.0.1:`port`: the
    /// relay's own listener, asked directly. A connect that completes is
    /// accepted by the relay like any client (one accept/finish pair in the
    /// log; no bytes are sent) and closed at once. Never blocks the caller:
    /// the connect runs on its own queue, `completion` too.
    nonisolated static func probe(port: UInt16, timeout: TimeInterval = probeTimeout,
                                  completion: @escaping @Sendable (SocksRelayRecovery.ListenerProbe) -> Void) {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let connection = NWConnection(host: "127.0.0.1",
                                      port: NWEndpoint.Port(rawValue: port) ?? .any,
                                      using: params)
        let progress = StartProgress()
        let finish: @Sendable (SocksRelayRecovery.ListenerProbe) -> Void = { outcome in
            guard !progress.settled else { return }
            progress.settled = true
            connection.cancel()
            completion(outcome)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(.answers)
            case .waiting(let error):
                // A refused loopback connect parks the connection here, "for
                // a better path", rather than failing it.
                logger.log("sockslog: probe of 127.0.0.1:\(port) refused: \(error)")
                finish(.refused)
            case .failed(let error):
                logger.log("sockslog: probe of 127.0.0.1:\(port) failed: \(error)")
                finish(.refused)
            default:
                break
            }
        }
        connection.start(queue: probeQueue)
        probeQueue.asyncAfter(deadline: .now() + timeout) {
            finish(.timedOut)
        }
    }

    /// `probe(port:timeout:completion:)`, awaited.
    nonisolated static func probe(port: UInt16, timeout: TimeInterval = probeTimeout) async
        -> SocksRelayRecovery.ListenerProbe {
        await withCheckedContinuation { continuation in
            probe(port: port, timeout: timeout) { continuation.resume(returning: $0) }
        }
    }

    /// One start's progress, confined to the queue its callbacks run on.
    private final class StartProgress: @unchecked Sendable {
        var settled = false
        var ready = false
    }

    /// A value handed across a semaphore.
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

#if LATCHKEY_TEST_HOOKS
    /// Test hook (R30): kills the app-owned listener and every session the
    /// way iOS does after a suspension. The port WebKit was given stops
    /// answering; tsnet's own listener is untouched, so the status poll sees
    /// nothing and only a failed page load can notice. Lets the L2 harness
    /// exercise the page-driven restart end to end.
    func debugDefunctListener() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for id in Array(sessions.keys) {
                close(id: id, reason: "test hook: listener defuncted")
            }
        }
    }
#endif

    // MARK: - Relay

    private func handle(client: NWConnection) {
        let now = Date()
        // The cap (R30). Refusals and evictions are logged sparingly, as
        // accepts are: a storm of them must not become its own log storm
        // (LogRing aborts the process at 1000 lines/s).
        let active = sessions.map { SocksRelayCapacity.Session(id: $0.key, lastActivity: $0.value.lastActivity) }
        switch capacity.admit(active, now: now) {
        case .accept:
            break
        case .acceptEvicting(let victim, let idle):
            evictions &+= 1
            if evictions <= 3 || evictions.isMultiple(of: 100) {
                logger.log("sockslog: at capacity (\(sessions.count)); evicting socks[\(victim)], silent for \(Int(idle))s (evicted \(evictions) so far)")
            }
            close(id: victim, reason: "evicted at capacity after \(Int(idle))s idle")
        case .refuse:
            refusals &+= 1
            if refusals <= 3 || refusals.isMultiple(of: 100) {
                logger.log("sockslog: at capacity (\(sessions.count)), every session live; refusing a connection (refused \(refusals) so far)")
            }
            client.cancel()
            return
        }

        let id = nextID
        nextID += 1
        activeClients[id] = client
        lastAcceptedAt = now
        lifecycleEvents &+= 1
        if lifecycleEvents <= 20 || lifecycleEvents.isMultiple(of: 100) {
            logger.log("socks[\(id)] relay accepted; active=\(activeClients.count), lifecycle=\(lifecycleEvents)")
        }
        client.start(queue: queue)
        beginRelay(client: client, id: id, acceptedAt: now)
    }

    private func beginRelay(client: NWConnection, id: UInt64, acceptedAt: Date) {
        client.stateUpdateHandler = nil
        let upstream = NWConnection(
            host: NWEndpoint.Host(upstreamHost),
            port: NWEndpoint.Port(rawValue: upstreamPort) ?? .any,
            using: .tcp)
        let session = Session(id: id, lastActivity: acceptedAt)
        sessions[id] = session
        activeUpstreams[id] = upstream
        upstream.start(queue: queue)

        // client -> upstream (parse the CONNECT request out of a copy)
        pump(from: client, to: upstream, id: id) { [weak self] data in
            session.lastActivity = Date()
            self?.inspectClientBytes(data, session: session)
        }
        // upstream -> client (parse the reply code out of a copy)
        pump(from: upstream, to: client, id: id) { [weak self] data in
            session.lastActivity = Date()
            self?.inspectServerBytes(data, session: session)
        }
    }

    /// Ends a session from outside its pumps: eviction, or the test hook.
    /// The pumps then finish on their cancelled connections, which the
    /// idempotent `finishRelay` ignores.
    private func close(id: UInt64, reason: String) {
        activeClients[id]?.cancel()
        activeUpstreams[id]?.cancel()
        finishRelay(id: id, reason: reason)
    }

    /// Copies bytes one direction, handing each chunk to `observe` first.
    private func pump(from: NWConnection,
                      to: NWConnection,
                      id: UInt64,
                      observe: @escaping @Sendable (Data) -> Void) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                observe(data)
                to.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard sendError == nil else {
                        logger.log("socks[\(id)] relay send ended: \(String(describing: sendError))")
                        from.cancel()
                        to.cancel()
                        self?.finishRelay(id: id, reason: "send error")
                        return
                    }
                    self?.pump(from: from, to: to, id: id, observe: observe)
                })
                return
            }
            if isComplete || error != nil {
                if let error {
                    logger.log("socks[\(id)] relay receive ended: \(error)")
                }
                from.cancel()
                to.cancel()
                self?.finishRelay(id: id, reason: error == nil ? "complete" : "receive error")
                return
            }

            // `minimumIncompleteLength` is one, so an empty callback with no
            // completion or error cannot make progress. Retrying immediately
            // can become a hot callback loop if iOS has defuncted a connection
            // while the process was suspended. Terminate the relay instead;
            // WebKit can open a fresh SOCKS connection.
            logger.log("socks[\(id)] relay receive made no progress; cancelling")
            from.cancel()
            to.cancel()
            self?.finishRelay(id: id, reason: "no progress")
        }
    }

    private func finishRelay(id: UInt64, reason: String) {
        // Both directional pumps can finish. Removal makes this idempotent and
        // prevents duplicate terminal logs from becoming their own log storm.
        let existed = activeClients.removeValue(forKey: id) != nil
            || activeUpstreams.removeValue(forKey: id) != nil
        activeUpstreams.removeValue(forKey: id)
        sessions.removeValue(forKey: id)
        guard existed else { return }
        lifecycleEvents &+= 1
        logger.log("socks[\(id)] relay finished (\(reason)); active=\(activeClients.count), lifecycle=\(lifecycleEvents)")
    }

    // MARK: - Parsing (read-only; the stream itself is untouched)

    /// Per-connection parse state. Only the handshake is parsed; once the
    /// CONNECT reply is seen the relay stops looking at payload bytes.
    /// Confined to the relay's serial queue; marked Sendable so the Network
    /// framework callback types can express that confinement to Swift 6.
    private final class Session: @unchecked Sendable {
        let id: UInt64
        var clientPhase: ClientPhase = .greeting
        var serverPhase: ServerPhase = .methodSelect
        var pendingClient = Data()
        var pendingServer = Data()
        var target = "?"
        var requestedAt = Date()
        /// The last byte in either direction, or the accept; what the cap
        /// evicts by (R30).
        var lastActivity: Date

        init(id: UInt64, lastActivity: Date) {
            self.id = id
            self.lastActivity = lastActivity
        }

        enum ClientPhase { case greeting, auth, request, done }
        enum ServerPhase { case methodSelect, authReply, connectReply, done }
    }

    private func inspectClientBytes(_ data: Data, session s: Session) {
        guard s.clientPhase != .done else { return }
        s.pendingClient.append(data)

        // Walk as far through the handshake as the buffered bytes allow.
        while true {
            switch s.clientPhase {
            case .greeting:
                // VER | NMETHODS | METHODS...
                guard s.pendingClient.count >= 2 else { return }
                let n = Int(s.pendingClient[s.pendingClient.startIndex + 1])
                let need = 2 + n
                guard s.pendingClient.count >= need else { return }
                let methods = Array(s.pendingClient.dropFirst(2).prefix(n))
                s.pendingClient.removeFirst(need)
                // 0x02 = username/password. tsnet requires it.
                s.clientPhase = methods.contains(0x02) ? .auth : .request
            case .auth:
                // VER | ULEN | UNAME | PLEN | PASSWD
                guard s.pendingClient.count >= 2 else { return }
                let ulen = Int(s.pendingClient[s.pendingClient.startIndex + 1])
                guard s.pendingClient.count >= 2 + ulen + 1 else { return }
                let plen = Int(s.pendingClient[s.pendingClient.startIndex + 2 + ulen])
                let need = 2 + ulen + 1 + plen
                guard s.pendingClient.count >= need else { return }
                s.pendingClient.removeFirst(need)
                s.clientPhase = .request
            case .request:
                // VER | CMD | RSV | ATYP | ADDR | PORT
                guard s.pendingClient.count >= 4 else { return }
                let base = s.pendingClient.startIndex
                let cmd = s.pendingClient[base + 1]
                let atyp = s.pendingClient[base + 3]
                var host = "?"
                var consumed = 4
                switch atyp {
                case 0x01: // IPv4
                    guard s.pendingClient.count >= consumed + 4 else { return }
                    let b = Array(s.pendingClient.dropFirst(consumed).prefix(4))
                    host = b.map(String.init).joined(separator: ".")
                    consumed += 4
                case 0x03: // domain name
                    guard s.pendingClient.count >= consumed + 1 else { return }
                    let len = Int(s.pendingClient[base + consumed])
                    consumed += 1
                    guard s.pendingClient.count >= consumed + len else { return }
                    host = String(decoding: Array(s.pendingClient.dropFirst(consumed).prefix(len)))
                    consumed += len
                case 0x04: // IPv6
                    guard s.pendingClient.count >= consumed + 16 else { return }
                    let b = Array(s.pendingClient.dropFirst(consumed).prefix(16))
                    host = Self.formatIPv6(b)
                    consumed += 16
                default:
                    s.clientPhase = .done
                    return
                }
                guard s.pendingClient.count >= consumed + 2 else { return }
                let pb = Array(s.pendingClient.dropFirst(consumed).prefix(2))
                let port = (UInt16(pb[0]) << 8) | UInt16(pb[1])
                s.pendingClient.removeAll(keepingCapacity: false)
                s.target = "\(host):\(port)"
                s.requestedAt = Date()
                s.clientPhase = .done
                let kind = Self.addrKind(atyp)
                let cmdName = cmd == 0x01 ? "CONNECT" : "cmd=\(cmd)"
                logger.log("socks[\(s.id)] \(cmdName) \(kind) \(s.target) — request reached the tailnet proxy")
                return
            case .done:
                return
            }
        }
    }

    private func inspectServerBytes(_ data: Data, session s: Session) {
        guard s.serverPhase != .done else { return }
        s.pendingServer.append(data)

        while true {
            switch s.serverPhase {
            case .methodSelect:
                guard s.pendingServer.count >= 2 else { return }
                let method = s.pendingServer[s.pendingServer.startIndex + 1]
                s.pendingServer.removeFirst(2)
                s.serverPhase = (method == 0x02) ? .authReply : .connectReply
            case .authReply:
                guard s.pendingServer.count >= 2 else { return }
                let status = s.pendingServer[s.pendingServer.startIndex + 1]
                s.pendingServer.removeFirst(2)
                if status != 0 {
                    logger.log("socks[\(s.id)] proxy auth FAILED (status \(status))")
                    s.serverPhase = .done
                    return
                }
                s.serverPhase = .connectReply
            case .connectReply:
                // VER | REP | RSV | ATYP | BND.ADDR | BND.PORT
                guard s.pendingServer.count >= 2 else { return }
                let rep = s.pendingServer[s.pendingServer.startIndex + 1]
                let ms = Int(Date().timeIntervalSince(s.requestedAt) * 1000)
                if rep == 0 {
                    logger.log("socks[\(s.id)] OK \(s.target) — tailnet proxy connected (\(ms)ms)")
                } else {
                    logger.log("socks[\(s.id)] FAILED \(s.target) — tailnet proxy could not connect: \(Self.replyName(rep)) (reply \(rep), \(ms)ms). WebKit will report this as \"invalid URL\" (-1000).")
                }
                s.pendingServer.removeAll(keepingCapacity: false)
                s.serverPhase = .done
                return
            case .done:
                return
            }
        }
    }

    // MARK: - Formatting

    private static func addrKind(_ atyp: UInt8) -> String {
        switch atyp {
        case 0x01: return "ipv4"
        case 0x03: return "name"
        case 0x04: return "ipv6"
        default:   return "atyp=\(atyp)"
        }
    }

    /// RFC 1928 reply codes. These are what tsnet's dial failure turns into,
    /// and every one of them is reported by WebKit as -1000.
    private static func replyName(_ rep: UInt8) -> String {
        switch rep {
        case 1: return "general failure"
        case 2: return "connection not allowed"
        case 3: return "network unreachable"
        case 4: return "host unreachable"
        case 5: return "connection refused"
        case 6: return "TTL expired"
        case 7: return "command not supported"
        case 8: return "address type not supported"
        default: return "unknown"
        }
    }

    private static func formatIPv6(_ b: [UInt8]) -> String {
        guard b.count == 16 else { return "?" }
        var parts: [String] = []
        for i in stride(from: 0, to: 16, by: 2) {
            parts.append(String(format: "%x", (Int(b[i]) << 8) | Int(b[i + 1])))
        }
        return parts.joined(separator: ":")
    }
}

private extension String {
    /// Lossy UTF-8 decode of raw SOCKS address bytes (a malformed name must not
    /// crash the relay).
    nonisolated init(decoding bytes: [UInt8]) {
        self = String(bytes: bytes, encoding: .utf8) ?? "?"
    }
}
