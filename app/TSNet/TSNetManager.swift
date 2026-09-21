// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//  Created by Jonathan Nobels on 2025-12-09.
//

import Foundation
import TailscaleKit
import Network
import WebKit
@preconcurrency import Combine

enum TSNetError: Error {
    case noNode
}

typealias MessageSender = @Sendable (String) async  -> Void

/// How an auth key may be supplied to the node for non-interactive (headless)
/// login — used by UI tests and any automated run that can't show the web
/// auth sheet. Checked once at launch, in priority order:
///
///   1. `APERTURE_AUTHKEY` environment variable (preferred for secrets —
///      doesn't appear in the process argument list).
///   2. `-AuthKey <key>` launch argument (convenient for `simctl launch`).
///
/// When set, the node authenticates with this key on `up()` instead of going
/// to `NeedsLogin` and showing the "Login" button. A matching
/// `APERTURE_EPHEMERAL`/`-Ephemeral` flag marks the node ephemeral so test
/// nodes clean themselves up when closed.

@MainActor
final class TSNetManager {
    @MainActor var node: TailscaleNode?

    let config: Configuration

    // The consumer is replaced on each lifecycle generation so callbacks
    // already queued by a cancelled observer cannot mutate current state.
    private(set) var consumer: TSNetConsumer
    let model: TSNetModel

    var localAPIClient: LocalAPIClient?
    var processor: MessageProcessor?

    /// Background poll of the localAPI `/status` endpoint (every few seconds
    /// while connected) so the UI can classify each tab's connection as
    /// direct vs derped vs internet (see `ConnectionTypeResolver`). Stopped
    /// when the node goes down.
    @MainActor private var statusPollTask: Task<Void, Never>?

    /// True while a start is in-flight or the node is up. Guards against the
    /// launch double-start: `init()` kicks off a start, and the initial
    /// `scenePhase == .active` notification calls `willEnterForeground()` too.
    /// MainActor so the check-and-set is atomic.
    @MainActor private var startInFlight = false

    /// Logging SOCKS5 relay in front of tsnet's proxy, so every connection
    /// attempt + outcome is visible in Settings → Logs on a device that can't
    /// be attached to a Mac. See `SocksLogProxy`.
    @MainActor private var socksLogProxy: SocksLogProxy?
    @MainActor private var socksLogProxyPort: UInt16?

    /// The SOCKS5 endpoint WebKit talks to — the logging relay's port when
    /// the relay is on, tsnet's loopback listener otherwise — and tsnet's
    /// per-launch credential. Kept so a policy change can build a FRESH
    /// ProxyConfiguration (R12): copying and editing the installed one would
    /// rewrite it in place, because ProxyConfiguration has reference
    /// semantics under its struct face (see ProxyConfigurationFactory).
    @MainActor private var proxyEndpoint: (host: String, port: Int, credential: String)?

    /// `host:port` of the SOCKS5 endpoint WebKit uses, for the diagnostics
    /// screen (Latchkey, M8.2). Never the credential.
    @MainActor var proxyEndpointSummary: String? {
        proxyEndpoint.map { "\($0.host):\($0.port)" }
    }
    @MainActor private var didRunTCPChaosTest = false

    /// Creates a per-workspace tsnet controller. `config.path` is the
    /// workspace's state dir (Application Support — persistent, unlike the
    /// old `NSTemporaryDirectory` location; see `WorkspaceStore.stateDir`);
    /// `config.hostName`/`controlURL`/`ephemeral`/`authKey` come from the
    /// workspace's `WorkspaceDefinition` (plus the shared launch-arg auth key
    /// for the default/test workspace).
    ///
    /// App-level one-time setup (process logging, `-UITestResetLogin` state-dir
    /// wipe) is handled by `WorkspaceManager`, NOT here — this class is now
    /// instantiated once per workspace and must not repeat global setup.
    @MainActor
    init(config: Configuration) {
        if config.authKey != nil {
            logger.log("Launching with auth key (ephemeral=\(config.ephemeral))")
        }
        self.config = config

        let model = TSNetModel()
        let consumer = TSNetConsumer(logger: logger, model: model)
        self.model = model
        self.consumer = consumer

        startTailscaleIfNeeded()
    }

    /// Starts the node iff no start is already in flight. The single entry
    /// point for both the initial launch and foreground reconnects, so the
    /// guard lives in one place.
    @MainActor
    func startTailscaleIfNeeded() {
        guard !startInFlight else {
            logger.log("startTailscale: already in flight, skipping")
            return
        }
        startInFlight = true
#if LATCHKEY_TEST_HOOKS
        // R11: the offline harness supplies what a node would have produced
        // and everything above the model runs as in production.
        if let fixture = TestNetworkFixture.fromLaunchArguments() {
            startFromTestFixture(fixture)
            return
        }
#endif
        Task(priority: .userInitiated) {
            await startTailscale()
        }
    }

    func getModel() -> TSNetModel {
        return model
    }

#if LATCHKEY_TEST_HOOKS
    /// Test builds only (R11, R15). No tsnet node: the fixture's status and
    /// `.Running` go straight onto the model, and the proxy configuration is
    /// published through the same `proxyConfig` path production uses — relay,
    /// factory and policy included — just pointed at the stub proxy.
    @MainActor
    private func startFromTestFixture(_ fixture: TestNetworkFixture) {
        logger.log("TEST FIXTURE: no tsnet node; proxy \(fixture.proxyHost):\(fixture.proxyPort), \(fixture.status.Peer?.count ?? 0) peer(s)")
        model.localStatus = fixture.status
        model.tailnetName = fixture.status.CurrentTailnet?.MagicDNSSuffix
        model.state = .Running
        model.proxyConfiguration = proxyConfig(upstreamHost: fixture.proxyHost,
                                               upstreamPort: fixture.proxyPort,
                                               credential: fixture.credential)
    }
#endif

    /// The auth key supplied at launch, if any. See the doc comment above the
    /// class for the resolution order. Test builds only (R15): in any other
    /// build an auth key from a paired Mac could join the app to a foreign
    /// tailnet.
    nonisolated static func launchAuthKey() -> String? {
        TestHooks.environment("APERTURE_AUTHKEY") ?? TestHooks.value("-AuthKey")
    }

    /// Whether the node should register as ephemeral. Honors either the
    /// `APERTURE_EPHEMERAL` env var ("1") or the `-Ephemeral` launch arg.
    /// Test builds only (R15); a real install is never ephemeral (R6).
    nonisolated static func launchEphemeral() -> Bool {
        TestHooks.environment("APERTURE_EPHEMERAL") == "1" || TestHooks.flag("-Ephemeral")
    }

    /// Upstream's L2 recovery hooks (R14 uses them). Test builds only (R15).
    nonisolated static func tcpChaosTestRequested() -> Bool {
        TestHooks.flag("-UITestDefunctLoopback") || TestHooks.flag("-UITestShutdownTCPConnections")
    }

    nonisolated private func startTailscale() async {
        do {
            // This sets up a localAPI client attached to the local node.
            let node = try await MainActor.run { try setupNode() }

            // Create a localAPIClient instance for our local node
            let localAPIClient = LocalAPIClient(localNode: node, logger: logger)
            await MainActor.run { setLocalAPIClient(localAPIClient) }

            try await tailscaleUp(localAPI: localAPIClient, consumer: consumer)

        } catch {
            await MainActor.run { startInFlight = false }
            fatalError("Error setting up Tailscale: \(error)")
        }
    }

    func tailscaleUp(localAPI: LocalAPIClient, consumer: TSNetConsumer) async throws {
        setProcessor(try await startEventBus(localAPI: localAPI, consumer: consumer))

        // Deliberately do NOT call `node?.up()`. `up()` calls Go's
        // `Up(context.Background())` (non-cancellable), which blocks until the
        // node reaches `Running`. For a no-auth-key node sitting at
        // `NeedsLogin` (every real user before they log in), that blocks the
        // `TailscaleNode` actor's serial executor INDEFINITELY — and since
        // `loopback()`, `close()`, `addrs()` are all on the same actor, EVERY
        // localAPI call (`backendStatus()` polling, `startLoginInteractive()`,
        // logout's `currentProfile`/`deleteProfile`) queues behind it and hangs
        // for the whole login window. It also deadlocks `close()` on
        // background (close queues behind up() forever) → two tsnet servers
        // on the same state dir after a bg/fg cycle.
        //
        // `tailscale_start` (called in `TailscaleNode.init`) already sets
        // `WantRunning` + calls `StartLoginInteractive`, so the IPN bus emits
        // `NeedsLogin` + `BrowseToURL` (and later `Running` when the user
        // completes login) on its own — `Up`'s only extra work is a redundant
        // wait-for-`Running`. The bus watcher attached above is the source of
        // truth for state; `startStatusPolling` is the fallback. (Confirmed by
        // the timing harness in timing/: Start→Running ≈ Up→Running, with no
        // actor freeze — see timing/README.md.)
        //
        // The loopback SOCKS5 proxy is up as soon as the node is started, so
        // `proxyConfiguration` can be published now. The initial connection
        // gate does not create the browser until the bus reports `Running`.
        if let loopback = try await self.node?.loopback() {
            await MainActor.run {
                model.proxyConfiguration = proxyConfig(loopback)
            }
        }
    }

    @MainActor var busErrorWatcher: AnyCancellable?

    /// Watches `prefs` so flipping the Exit Node toggle re-scopes the proxy
    /// immediately (exit node on => proxy everything so public traffic can
    /// egress; off => tailnet only). Without this the change would only take
    /// effect on the next 5s status poll.
    @MainActor private var prefsWatcher: AnyCancellable?

    /// Owns the ordinary IPN-bus error retry. It must be explicitly cancelled:
    /// cancelling the Combine sink does not cancel a Task it already spawned.
    @MainActor private var busRestartTask: Task<Void, Never>?
    /// Backoff belongs to the watcher lifecycle, not to one restart Task. A
    /// LocalAPI listener can accept a request and then fail it asynchronously;
    /// treating creation of that request as "restart succeeded" otherwise
    /// resets backoff on every -1004 and creates a hot retry loop.
    @MainActor private var busRestartBackoff: Duration = .milliseconds(500)
    @MainActor private var loopbackRecoveryTask: Task<Void, Never>?
    @MainActor private var loopbackRecoveryGeneration: UInt64 = 0

    /// Starts observing `prefs` for exit-node changes. Idempotent.
    @MainActor
    private func startPrefsObservation() {
        guard prefsWatcher == nil else { return }
        prefsWatcher = model.$prefs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshProxyPolicyIfNeeded()
            }
    }

    func startEventBus(localAPI: LocalAPIClient,
                       consumer: TSNetConsumer) async throws -> MessageProcessor {
        // This sets up a bus watcher to listen for changes in the netmap.  These will be sent to the given consumer, in
        // this case, a TSNetModel which will keep track of the changes and publish them.
        let busEventMask: Ipn.NotifyWatchOpt = [.initialState]
        let processor = try await localAPI.watchIPNBus(mask: busEventMask,
                                                       consumer: consumer)

        // Any error on the bus consumer indicates the watcher died and needs to
        // be restarted. The watch-ipn-bus long-poll has no keep-alive, so
        // URLSession's default 60s request timeout kills it every minute of
        // idleness — this restart is what keeps state flowing.
        //
        // The restart MUST be robust: the previous version did
        // `let processor = try await startEventBus(...)` inside an unawaited
        // Task with no catch. If that threw (e.g. loopback not ready after a
        // bg/fg cycle), the error was silently swallowed, `consumer.error` had
        // already been cleared, and NO new watcher existed — the app then had
        // NO bus observation forever, so state never updated again (the
        // "click Login/Logout and nothing happens for minutes/ever" hang).
        // Now we catch, log, back off, and retry until the bus comes back or
        // the node is torn down (background).
        let busObserver = await consumer.$error
            .sink { [weak self] error in
                guard let self, let error else { return }
                self.scheduleBusRestart(localAPI: localAPI, consumer: consumer,
                                        error: error)
            }

        // Cancel any prior observer before installing the new one, so the old
        // watcher's sink can't fire again and cascade into concurrent restarts.
        await MainActor.run {
            busErrorWatcher?.cancel()
            busErrorWatcher = busObserver
        }
        return processor
    }

    @MainActor
    private func scheduleBusRestart(localAPI: LocalAPIClient, consumer: TSNetConsumer,
                                    error: Error) {
        if Self.isLocalLoopbackConnectionFailure(error) {
            recoverLoopbackAfterFailure(error)
            return
        }
        let delay = busRestartBackoff
        busRestartBackoff = min(busRestartBackoff * 2, .seconds(30))
        logger.log("Bus watcher error: \(error); retrying after \(delay)")
        busRestartTask?.cancel()
        consumer.error = nil
        busRestartTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                let processor = try await self.startEventBus(
                    localAPI: localAPI, consumer: consumer)
                guard !Task.isCancelled else {
                    processor.cancel()
                    return
                }
                self.setProcessor(processor)
                self.busRestartTask = nil
            } catch is CancellationError {
                return
            } catch {
                // A synchronous setup failure has no consumer callback to drive
                // the next attempt, so feed it through the same persistent
                // backoff path. Async URLSession failures arrive via consumer.
                self.busRestartTask = nil
                self.scheduleBusRestart(localAPI: localAPI, consumer: consumer,
                                        error: error)
            }
        }
    }

    nonisolated private static func isLocalLoopbackConnectionFailure(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain,
              (ns.code == NSURLErrorCannotConnectToHost
                || ns.code == NSURLErrorNetworkConnectionLost)
        else { return false }
        let rawURL = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString ?? ""
        guard let host = URL(string: rawURL)?.host()?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    @MainActor
    private func recoverLoopbackAfterFailure(_ cause: Error) {
        guard loopbackRecoveryTask == nil, let node else { return }
        loopbackRecoveryGeneration &+= 1
        let generation = loopbackRecoveryGeneration
        logger.log("LocalAPI loopback failure: \(cause); replacing loopback generation \(generation)")
        busRestartTask?.cancel()
        busRestartTask = nil
        loopbackRecoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loopback = try await node.restartLoopback()
                guard !Task.isCancelled,
                      generation == self.loopbackRecoveryGeneration else { return }

                // Every LocalAPI request asks the node actor for its cached
                // config, now replaced above. Restart the stream immediately.
                let newConsumer = TSNetConsumer(logger: logger, model: self.model)
                let newClient = LocalAPIClient(localNode: node, logger: logger)
                let newProcessor = try await self.startEventBus(
                    localAPI: newClient, consumer: newConsumer)
                guard !Task.isCancelled,
                      generation == self.loopbackRecoveryGeneration else {
                    newProcessor.cancel()
                    return
                }
                self.consumer = newConsumer
                self.localAPIClient = newClient
                self.setProcessor(newProcessor)

                // Replace the app-owned relay too: its upstream port and SOCKS
                // credential changed with the tsnet loopback listener.
                self.socksLogProxy?.stop()
                self.socksLogProxy = nil
                self.socksLogProxyPort = nil
                self.model.proxyConfiguration = self.proxyConfig(loopback)
                self.busRestartBackoff = .milliseconds(500)
                self.loopbackRecoveryTask = nil
                self.model.tcpChaosTestStatus = "recovered"
                logger.log("LocalAPI loopback recovered at \(loopback.address), generation \(generation)")
            } catch {
                guard !Task.isCancelled,
                      generation == self.loopbackRecoveryGeneration else { return }
                self.loopbackRecoveryTask = nil
                logger.log("LocalAPI loopback replacement failed: \(error); retrying through bus backoff")
                self.scheduleBusRestart(localAPI: localAPIClient ?? LocalAPIClient(localNode: node, logger: logger),
                                        consumer: self.consumer, error: error)
            }
        }
    }

    func setLocalAPIClient(_ client: TailscaleKit.LocalAPIClient) {
        self.localAPIClient = client
        startPrefsObservation()
        startStatusPolling()
    }

    /// Polls `backendStatus()` every few seconds and publishes it on the model,
    /// so per-tab connection-type indicators stay current.
    @MainActor
    func startStatusPolling() {
        guard statusPollTask == nil else { return }
        statusPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let client = await MainActor.run(body: { self.localAPIClient }) {
                    do {
                        let status = try await client.backendStatus()
                        await MainActor.run {
                            // A successful request proves the local listener is
                            // carrying bytes again; future watcher failures may
                            // start from the short retry delay.
                            self.busRestartBackoff = .milliseconds(500)
                            self.model.localStatus = status
                            if status.BackendState == "Running" {
                                self.runTCPChaosTestIfNeeded()
                            }
                            // Fallback state signal: model.state is normally
                            // driven by the IPN bus, but if the bus watcher is
                            // mid-restart (or has died — see startEventBus),
                            // state would go stale indefinitely. Mirror the
                            // polled BackendState into model.state so the UI's
                            // gate/LoginBanner/Login-button react within one
                            // poll interval (5s) instead of waiting for the bus.
                            if let s = Self.ipnState(fromBackendState: status.BackendState),
                               self.model.state != s {
                                self.model.state = s
                            }
                            // Fold newly-discovered peers / the MagicDNS suffix
                            // into the proxy's split-tunnel rules. The proxy is
                            // published before the first poll, so without this
                            // the rule set would stay IP-ranges-only and bare
                            // MagicDNS names (`http://ai/`) would load DIRECT
                            // and fail. No-op when the rules are unchanged.
                            self.refreshProxyPolicyIfNeeded()
                        }
                    } catch {
                        await MainActor.run {
                            logger.log("Status poll failed: \(error)")
                            if Self.isLocalLoopbackConnectionFailure(error) {
                                self.recoverLoopbackAfterFailure(error)
                            }
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
            }
        }
    }

    func setProcessor(_ processor: MessageProcessor) {
        self.processor?.cancel()
        self.processor = processor
    }

    func setupNode() throws -> TailscaleNode {
        guard self.node == nil else { return self.node! }
        self.node = try TailscaleNode(config: config, logger: logger)
        return self.node!
    }

    /// Builds the SOCKS5 `ProxyConfiguration` for WebKit, scoped by
    /// `TailnetProxyPolicy` so ONLY tailnet destinations are proxied and the
    /// public internet loads DIRECT.
    ///
    /// The scoping is what fixes the iPad `-1000` ("invalid URL") bug. Measured
    /// fact: `-1000` is what WebKit/CFNetwork report for ANY SOCKS5 CONNECT
    /// failure, so it means "the proxy could not connect" — not "bad URL".
    /// Public hosts therefore must not depend on the tsnet proxy at all. See
    /// the file comment in `TailnetProxyPolicy.swift` for the candidate
    /// mechanisms and the verified `matchDomains` semantics.
    ///
    /// `-ProxyEverything` restores the old proxy-everything behaviour, so the
    /// two modes can be A/B'd on a real device with no rebuild (the iPad in
    /// the bug report can't be attached to a Mac).
    func proxyConfig(_ loopbackConfig: TailscaleNode.LoopbackConfig) -> ProxyConfiguration? {
        guard let ip = loopbackConfig.ip, let port = loopbackConfig.port else {
            return nil
        }
        return proxyConfig(upstreamHost: ip, upstreamPort: port,
                           credential: loopbackConfig.proxyCredential)
    }

    /// The same, from plain values: tsnet's loopback listener in production,
    /// or the stub proxy in the offline test harness (R11). Starts the
    /// logging relay in front of it when enabled, records the endpoint for
    /// later rescoping, and builds the configuration through
    /// `ProxyConfigurationFactory`.
    func proxyConfig(upstreamHost ip: String, upstreamPort port: Int,
                     credential: String) -> ProxyConfiguration? {

        // Route WebKit through the logging relay (Settings → Logs) so every
        // connection attempt that reaches the tailnet proxy is recorded with
        // its outcome. tsnet's own SOCKS server logs only failures and not the
        // reply code, so without this the absence of a log line is ambiguous:
        // it could mean "iOS never sent it to us" OR "it succeeded".
        var proxyHost = ip
        var proxyPort = port
        if SocksLogProxy.isEnabled() {
            if socksLogProxy == nil,
               let upstreamPort = UInt16(exactly: port) {
                let relay = SocksLogProxy(upstreamHost: ip, upstreamPort: upstreamPort)
                if let localPort = relay.start() {
                    socksLogProxy = relay
                    socksLogProxyPort = localPort
                }
            }
            if let localPort = socksLogProxyPort {
                proxyHost = "127.0.0.1"
                proxyPort = Int(localPort)
            }
        }

        proxyEndpoint = (proxyHost, proxyPort, credential)
        let policy = StableProxyPolicy.make(from: model.localStatus,
                                             exitNodeEnabled: proxyEverythingRequested())
        guard let proxyConfig = ProxyConfigurationFactory.make(
            proxyHost: proxyHost, proxyPort: proxyPort,
            credential: credential, policy: policy)
        else {
            logger.log("proxyConfig: invalid proxy endpoint port \(proxyPort); not publishing")
            return nil
        }
        model.proxyPolicy = policy
        if policy.proxiesEverything {
            logger.log("proxyConfig: proxying ALL hosts (-ProxyEverything test hook). Public traffic only works if something carries it out of the tailnet.")
        } else {
            logger.log("proxyConfig: split tunnel, proxying \(policy.matchDomains.count) rule(s): \(policy.matchDomains.joined(separator: ", "))")
        }
        if !policy.shortNamesWithheldAsPublicTLD.isEmpty {
            logger.log("proxyConfig: short names withheld (public-TLD collision), reachable via FQDN: \(policy.shortNamesWithheldAsPublicTLD.joined(separator: ", "))")
        }
        return proxyConfig
    }

    /// Re-derives the proxy's `matchDomains` from the latest peer status and
    /// republishes it if the rule set changed.
    ///
    /// The proxy is published as soon as the node starts — before the first
    /// `/status` poll — so the initial rule set is only the tailnet IP ranges.
    /// Once peers are known (and whenever they change: a peer joins, or
    /// MagicDNS arrives) the short names and MagicDNS suffix must be folded in,
    /// or bare names like `http://ai/` would load DIRECT and fail.
    @MainActor
    func refreshProxyPolicyIfNeeded() {
        guard model.proxyConfiguration != nil else { return }
        let policy = StableProxyPolicy.make(from: model.localStatus,
                                             exitNodeEnabled: proxyEverythingRequested())
        guard policy != model.proxyPolicy else { return }
        // Build a fresh configuration rather than editing the published one:
        // ProxyConfiguration's copies share storage, so upstream's
        // `var updated = model.proxyConfiguration; updated.matchDomains = …`
        // rewrote the object already installed in WebKit's data store (R12).
        guard let endpoint = proxyEndpoint,
              let updated = ProxyConfigurationFactory.make(
                proxyHost: endpoint.host, proxyPort: endpoint.port,
                credential: endpoint.credential, policy: policy)
        else { return }
        model.proxyPolicy = policy
        model.proxyConfiguration = updated
        logger.log("proxyConfig: policy updated — \(policy.matchDomains.joined(separator: ", "))")
        if !policy.shortNamesWithheldAsPublicTLD.isEmpty {
            logger.log("proxyConfig: short names withheld (public-TLD collision), reachable via FQDN: \(policy.shortNamesWithheldAsPublicTLD.joined(separator: ", "))")
        }
    }

    /// Whether ALL traffic (not just tailnet) should go through the proxy.
    ///
    /// Upstream also returned true when an exit node was enabled, since that is
    /// how public traffic egresses. Latchkey removed the exit-node feature
    /// (PLAN §1.8/§7.4 — it is broken under tsnet), so the ONLY remaining
    /// trigger is the `-ProxyEverything` launch override, which exists to
    /// demonstrate the `-1000` bug the split tunnel fixes.
    ///
    /// Deliberately NOT reading `prefs.ExitNodeID` any more. With no UI left to
    /// clear it, a stray `ExitNodeID` arriving from restored prefs or a tailnet
    /// policy would silently switch every public request onto a proxy with
    /// nothing carrying it, and the user would have no way to turn that off. It
    /// is logged instead, so the condition is visible rather than fatal.
    @MainActor
    func proxyEverythingRequested() -> Bool {
        let id = model.prefs?.ExitNodeID ?? ""
        if !id.isEmpty, id != lastIgnoredExitNodeID {
            // Once per distinct value: this runs on every 5 s policy poll.
            logger.log("prefs carry ExitNodeID '\(id)' but exit nodes are not supported; ignoring for routing")
        }
        lastIgnoredExitNodeID = id
        return Self.proxyEverythingOverride()
    }

    /// The last `ExitNodeID` reported as ignored, so the warning above fires
    /// once per value instead of every poll.
    @MainActor private var lastIgnoredExitNodeID = ""

    /// Debug/diagnostic escape hatch: `-ProxyEverything` (launch arg) or
    /// `APERTURE_PROXY_EVERYTHING=1` restores the pre-fix behaviour of routing
    /// every request through the tsnet proxy. Used to demonstrate the -1000 bug
    /// and to verify the split tunnel is what fixes it. Not settable on a real
    /// device, and with the exit-node toggle removed there is no longer an
    /// on-device equivalent — Settings → Routing is the on-device diagnostic.
    nonisolated static func proxyEverythingOverride() -> Bool {
        // Test builds only (R4, R15): in any other build nothing can switch
        // public traffic onto the proxy.
        TestHooks.environment("APERTURE_PROXY_EVERYTHING") == "1" || TestHooks.flag("-ProxyEverything")
    }

    @MainActor
    private func runTCPChaosTestIfNeeded() {
        guard Self.tcpChaosTestRequested(), !didRunTCPChaosTest else { return }
        didRunTCPChaosTest = true
        Task { [weak self] in
            guard let self, let node = self.node else { return }
            // Let the first document and SOCKS diagnostics establish themselves
            // before damaging all TCP sockets in the process.
            try? await Task.sleep(for: .seconds(2))
            self.model.tcpChaosTestStatus = "damaging"
            logger.log("TCP chaos test: defuncting the tsnet loopback listener")
            do {
                if TestHooks.flag("-UITestDefunctLoopback") {
                    try await node.debugDefunctLoopback()
                } else {
                    try await node.debugShutdownTCPConnections()
                }
                self.model.tcpChaosTestStatus = "damaged"
                logger.log("TCP chaos test: socket shutdown complete; awaiting reactive recovery")
            } catch {
                self.model.tcpChaosTestStatus = "failed: \(error)"
                logger.log("TCP chaos test failed: \(error)")
            }
        }
    }

    /// Permanently tears down this manager when its workspace is deleted.
    /// Unlike scene backgrounding, deletion must release the node and all
    /// observers so its state directory can be removed safely.
    func shutdown() async {
        statusPollTask?.cancel()
        statusPollTask = nil
        busRestartTask?.cancel()
        busRestartTask = nil
        loopbackRecoveryTask?.cancel()
        loopbackRecoveryTask = nil
        loopbackRecoveryGeneration &+= 1
        busErrorWatcher?.cancel()
        busErrorWatcher = nil
        prefsWatcher?.cancel()
        prefsWatcher = nil
        processor?.cancel()
        processor = nil
        socksLogProxy?.stop()
        socksLogProxy = nil
        socksLogProxyPort = nil
        localAPIClient = nil
        model.proxyConfiguration = nil
        proxyEndpoint = nil
        model.proxyPolicy = nil

        guard let node else { return }
        self.node = nil
        do {
            try await node.close()
            logger.log("Delete session: closed tsnet node")
        } catch {
            logger.log("Delete session: failed to close tsnet node: \(error)")
        }
    }

    func willEnterBackground() {
        logger.log("Background: leaving tsnet, proxy, and observers unchanged")
    }

    func willEnterForeground() {
        // Recovery is driven by an actual loopback connection failure, not by
        // scene lifecycle: iOS can defunct sockets for reasons other than lock.
        logger.log("Foreground: no lifecycle recovery; awaiting actual socket errors")
        if node == nil { startTailscaleIfNeeded() }
    }

    /// Returns whether the node's loopback answered (Latchkey: discovery
    /// uses that as its proxy-health signal, since the same listener serves
    /// SOCKS5 and LocalAPI).
    @discardableResult
    func refreshStatusNow() async -> Bool {
        guard let client = localAPIClient else { return false }
        do {
            let status = try await client.backendStatus()
            model.localStatus = status
            refreshProxyPolicyIfNeeded()
            return true
        } catch {
            logger.log("Immediate status refresh failed: \(error)")
            return false
        }
    }

    func setHostName(_ newHostName: String) {
        let trimmed = newHostName.trimmingCharacters(in: .whitespacesAndNewlines)
        let mask = Ipn.MaskedPrefs().hostname(trimmed)
        let client = localAPIClient
        Task {
            try await client?.editPrefs(mask: mask)
            logger.log("Set hostname to \(newHostName)")
        }
    }

    /// Maps the polled `IpnState.Status.BackendState` string ("Running",
    /// "NeedsLogin", …) to `Ipn.State`. Used by `startStatusPolling` as a
    /// fallback state signal so the UI isn't blind when the IPN bus watcher
    /// is mid-restart (or has died). `nonisolated` so it's callable from the
    /// polling Task off the main actor.
    nonisolated static func ipnState(fromBackendState s: String) -> Ipn.State? {
        switch s {
        case "NoState":          return .NoState
        case "InUseOtherUser":   return .InUseOtherUser
        case "NeedsLogin":       return .NeedsLogin
        case "NeedsMachineAuth": return .NeedsMachineAuth
        case "Stopped":          return .Stopped
        case "Starting":         return .Starting
        case "Running":          return .Running
        default:                 return nil
        }
    }
}

