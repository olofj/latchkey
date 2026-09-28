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
    /// Restarts of the relay's listener allowed per minute (R30).
    @MainActor private var relayRestartBudget = SocksRelayRecovery.Budget()
    /// A listener restart is waiting for its new port (R30 review: the wait
    /// is off the main actor now, so it has a duration).
    @MainActor private var relayRestartInFlight = false
    /// The one self-probe of the relay listener in flight, if any.
    @MainActor private var relayProbeTask: Task<Void, Never>?

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
        startRetryTask?.cancel()
        startRetryTask = nil
        startInFlight = true
        // F8 §4.6: never a node without process logging. Its filch is what
        // redacts tsnet's Go stderr, and that stderr carries login links.
        if let error = ProcessLogging.setUp() {
            startInFlight = false
            let failure = startTracker.failed(stage: .logging, errnoValue: Self.errnoValue(of: error),
                                              message: String(describing: error))
            model.startFailure = failure
            logger.log("NODE START REFUSED: process logging is unavailable (\(error)); no node is created without it. Nothing on disk has been changed. Try now retries.")
            return
        }
#if LATCHKEY_TEST_HOOKS
        // F8 §6.1: fail this attempt as a node that could not be created
        // would, above both the fixture and the real start.
        if let error = NodeStartFailureHook.nextAttemptError() {
            nodeStartFailed(error)
            return
        }
        // R11: the offline harness supplies what a node would have produced
        // and everything above the model runs as in production.
        if let fixture = TestNetworkFixture.fromLaunchArguments() {
            nodeStartSucceeded()
            startFromTestFixture(fixture)
            return
        }
#endif
        Task(priority: .userInitiated) {
            await startTailscale()
        }
    }

    /// F8: consecutive failed starts and the one on screen.
    @MainActor private var startTracker = NodeStartTracker()
    /// The next scheduled attempt after a failed start, if any (F8 §4.3).
    @MainActor private var startRetryTask: Task<Void, Never>?
    /// Set on background, so a foreground can tell a return to the app (new
    /// information: retry now, on a fresh schedule) from the launch's own
    /// first `.active`.
    @MainActor private var backgroundedSinceStartFailure = false

    /// A start could not produce a node (F8 §4.1). Nothing on disk is
    /// touched; the gate says so, and the next attempt is scheduled.
    @MainActor
    private func nodeStartFailed(_ error: Error) {
        startInFlight = false
        let details = Self.startFailureDetails(error)
        let failure = startTracker.failed(stage: .node, errnoValue: details.errno, message: details.message)
        model.startFailure = failure
        let next = failure.nextRetryIn.map { "next in \($0)" } ?? "no more automatic retries"
        logger.log("NODE START FAILED: \(error) (errno \(failure.errnoValue.map(String.init) ?? "none")). Nothing on disk has been changed. Attempt \(failure.attempt) of \(NodeStartFailure.retryDelays.count + 1); \(next).")
        guard let delay = failure.nextRetryIn else { return }
        startRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.startRetryTask = nil
            self.startTailscaleIfNeeded()
        }
    }

    /// The one place a start failure is cleared (F8 §4.2).
    @MainActor
    private func nodeStartSucceeded() {
        if model.startFailure != nil {
            logger.log("NODE START succeeded after \(model.startFailure?.attempt ?? 0) failed attempt(s)")
        }
        startTracker.succeeded()
        model.startFailure = nil
    }

    /// Try now (F8 §2): an attempt at once, on a fresh schedule. For a
    /// logging refusal, the setup is retried first and the node follows in
    /// the same tap.
    @MainActor
    func retryStartNow() {
        guard model.startFailure != nil else { return }
        logger.log("NODE START: Try now")
        startTracker.restartSchedule()
        startTailscaleIfNeeded()
    }

    /// Start a new node (F8 §4.4): the node's state directory is renamed
    /// aside by `setAside` — never deleted — and a fresh start follows. Only
    /// while a node start is failing, and never for a logging refusal, which
    /// a new identity would not fix.
    @MainActor
    func startNewNode(setAside: () throws -> URL) async throws -> URL {
        guard let failure = model.startFailure, failure.stage == .node, !startInFlight else {
            throw TSNetError.noNode
        }
        startRetryTask?.cancel()
        startRetryTask = nil
        // A start that failed after creating the node (in tailscaleUp) left it
        // holding the directory: close it before the rename.
        await shutdown()
        let aside = try setAside()
        logger.log("NODE START, NEW NODE: the previous state directory was kept, renamed to \(aside.lastPathComponent); starting a fresh node")
        startTracker.restartSchedule()
        startTailscaleIfNeeded()
        return aside
    }

    /// The errno and message a failed start carried. A `TsnetStart` failure
    /// has no errno (`recErr` returns -1 for every Go error): its message
    /// is the evidence, and `NodeStartFailure` reads the errno from it.
    nonisolated static func startFailureDetails(_ error: Error) -> (errno: Int32?, message: String) {
        switch error as? TailscaleError {
        case .posixError(let e, let details):
            return (e.code.rawValue, details ?? String(describing: e.code))
        case .unknownPosixError(let code, let details):
            return (code, details ?? "error \(code)")
        case .internalError(let details):
            return (nil, details ?? "internal error")
        default:
            return (errnoValue(of: error), String(describing: error))
        }
    }

    nonisolated private static func errnoValue(of error: Error) -> Int32? {
        if let e = error as? POSIXError { return e.code.rawValue }
        if case .posixError(let e, _)? = error as? TailscaleError { return e.code.rawValue }
        let ns = error as NSError
        return ns.domain == NSPOSIXErrorDomain ? Int32(ns.code) : nil
    }

    func getModel() -> TSNetModel {
        return model
    }

#if LATCHKEY_TEST_HOOKS
    /// Test builds only (R11, R15). No tsnet node: the fixture's status and
    /// its `BackendState` (`.Running` unless it names another, as F11's
    /// NeedsLogin gate tests do) go straight onto the model, and the proxy
    /// configuration is published through the same `proxyConfig` path
    /// production uses — relay, factory and policy included — just pointed
    /// at the stub proxy.
    @MainActor
    private func startFromTestFixture(_ fixture: TestNetworkFixture) {
        logger.log("TEST FIXTURE: no tsnet node; proxy \(fixture.proxyHost):\(fixture.proxyPort), \(fixture.status.Peer?.count ?? 0) peer(s)")
        model.localStatus = fixture.status
        model.tailnetName = fixture.status.CurrentTailnet?.MagicDNSSuffix
        model.state = Self.ipnState(fromBackendState: fixture.status.BackendState) ?? .Running
        // Published once the relay is up (F16 §4.3): `Running` is already on
        // the model, so the first load waits for the proxy in `loadInitial`.
        let generation = loopbackRecoveryGeneration
        Task { [weak self] in
            guard let self else { return }
            let config = await self.proxyConfig(upstreamHost: fixture.proxyHost,
                                                upstreamPort: fixture.proxyPort,
                                                credential: fixture.credential)
            guard generation == self.loopbackRecoveryGeneration else { return }
            self.model.proxyConfiguration = config
        }
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
            || TestHooks.flag("-UITestDefunctRelayListener") || TestHooks.flag("-UITestStallLoopback")
    }

    nonisolated private func startTailscale() async {
        do {
            // This sets up a localAPI client attached to the local node.
            let node = try await MainActor.run { try setupNode() }

            // Create a localAPIClient instance for our local node
            let localAPIClient = LocalAPIClient(localNode: node, logger: logger)
            await MainActor.run { setLocalAPIClient(localAPIClient) }

            try await tailscaleUp(localAPI: localAPIClient, consumer: consumer)
            // After the whole start, not at node creation: clearing there would
            // reset the schedule on every retry of a failing tailscaleUp, and
            // the bounded backoff would become a 1 s loop (F8 §3).
            await MainActor.run { nodeStartSucceeded() }

        } catch {
            // Not a trap (F8): a crash here was a crash loop at launch whose
            // only exit, deleting the app, deleted the node's identity.
            await MainActor.run { nodeStartFailed(error) }
        }
    }

    func tailscaleUp(localAPI: LocalAPIClient, consumer: TSNetConsumer) async throws {
        // Read before anything is awaited. The status poll is already running
        // (setLocalAPIClient), so a loopback recovery can start and install
        // its own bus, for a new consumer, while this one's start is in
        // flight; a shutdown() can clear everything. Either bumps the
        // generation, and then what this start made must not go in.
        let generation = loopbackRecoveryGeneration
#if LATCHKEY_TEST_HOOKS
        let hold = recoverDuringFirstBusStartIfRequested()
#else
        let hold: Duration? = nil
#endif
        let bus = try await startEventBus(localAPI: localAPI, consumer: consumer, holdForTest: hold)
        guard generation == loopbackRecoveryGeneration else {
            logger.log("First bus start superseded while starting; its bus is discarded")
            bus.cancel()
            return
        }
        installBus(bus)

        // Deliberately do NOT call `node?.up()`. `up()` calls Go's
        // `Up(context.Background())` (non-cancellable), which blocks until the
        // node reaches `Running`. For a no-auth-key node sitting at
        // `NeedsLogin` (every real user before they log in), that blocks the
        // `TailscaleNode` actor's serial executor INDEFINITELY — and since
        // `loopback()`, `close()`, `addrs()` are all on the same actor, EVERY
        // localAPI call (`backendStatus()` polling, `startLoginInteractive()`,
        // a reset's `/logout`, R32) queues behind it and hangs
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
        //
        // Suspended, not blocked, while the relay starts (F16 §4.3). A loopback
        // recovery in that time publishes its own configuration; this one is
        // then stale and is dropped.
        if let loopback = try await self.node?.loopback(), generation == loopbackRecoveryGeneration {
            let config = await proxyConfig(loopback)
            if generation == loopbackRecoveryGeneration {
                model.proxyConfiguration = config
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
    /// Status requests abandoned at `LoopbackHealth.statusBound` in a row,
    /// from the poll and `refreshStatusNow` alike (F16 §4.1).
    @MainActor private var statusStalls = LoopbackStallCount()

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

    /// A bus watch that has been started and not yet installed (F16 §4.2).
    /// `consumer` is what `errorWatcher` observes, so an install can be
    /// checked against the current one. The watcher acts only once `armed`,
    /// which `installBus` sets: a start that is never installed never
    /// schedules a restart, whatever its consumer reports.
    struct StartedBus {
        let processor: MessageProcessor
        let errorWatcher: AnyCancellable
        let consumer: TSNetConsumer
        let localAPI: LocalAPIClient
        let armed: BusArm

        /// For a start that turned out stale: neither part may live on.
        func cancel() {
            errorWatcher.cancel()
            processor.cancel()
        }
    }

    /// Whether a started bus's error watcher may act yet (F16 §4.2).
    final class BusArm {
        var armed = false
    }

    /// Starts a bus watch and its error observer, and installs NOTHING (F16
    /// §4.2): whoever decided to start it installs both with `installBus`
    /// after its own staleness check, or cancels both. Before F16 the watcher
    /// was installed here, unconditionally. A restart superseded by a loopback
    /// recovery while its start was in flight then replaced the recovery's
    /// watcher with one for the OLD consumer, and the live bus's first death
    /// (the idle -1001, about a minute later) went unobserved: no restart,
    /// and a Login whose BrowseToURL never arrived.
    ///
    /// `holdForTest` makes this start take that long (`-UITestBusInstallDelay`,
    /// test builds): a start that finishes after the recovery that superseded
    /// it, on demand rather than by scheduling accident.
    func startEventBus(localAPI: LocalAPIClient, consumer: TSNetConsumer,
                       holdForTest: Duration? = nil) async throws -> StartedBus {
        // This sets up a bus watcher to listen for changes in the netmap.  These will be sent to the given consumer, in
        // this case, a TSNetModel which will keep track of the changes and publish them.
        //
        // The consumer's error is cleared first (F16 §4.2): it is the one that
        // caused this start, if any. `scheduleBusRestart` clears it too, but
        // that clear runs inside the @Published willSet of the failing
        // assignment, which then stores the error again. Left in place,
        // `installBus` would take it for a new death and restart once more.
        await MainActor.run { consumer.error = nil }
        let busEventMask: Ipn.NotifyWatchOpt = [.initialState]
        let processor = try await localAPI.watchIPNBus(mask: busEventMask,
                                                       consumer: consumer)
#if LATCHKEY_TEST_HOOKS
        if let holdForTest {
            logger.log("Bus start held for \(holdForTest.components.seconds) s (test hook)")
            // Not Task.sleep: a recovery cancels this task, and the hold is
            // there to finish after that cancellation, as a slow start would.
            await Self.holdIgnoringCancellation(holdForTest)
        }
#endif

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
        //
        // Unarmed until installed (F16 §4.2). A start superseded while in
        // flight watches a consumer whose processor is failing against a
        // replaced loopback; acting on that would schedule a restart for the
        // OLD consumer before the caller could discard the start, and that
        // restart would install past every check. An error that arrives
        // before the install is not lost: `installBus` looks for it.
        let arm = BusArm()
        let busObserver = await consumer.$error
            .sink { [weak self] error in
                guard let self, let error, arm.armed else { return }
                self.scheduleBusRestart(localAPI: localAPI, consumer: consumer,
                                        error: error)
            }
        return StartedBus(processor: processor, errorWatcher: busObserver,
                          consumer: consumer, localAPI: localAPI, armed: arm)
    }

    /// Installs a started bus, replacing the processor and the error watcher
    /// before it. Only after the caller's own staleness check (F16 §4.2).
    /// The prior observer is cancelled first, so the old watcher's sink can't
    /// fire again and cascade into concurrent restarts.
    @MainActor
    private func installBus(_ bus: StartedBus) {
#if LATCHKEY_TEST_HOOKS
        // The instrument for a fault whose natural trigger was not shown (F16
        // §4.2): an installed watcher observes the current consumer, always.
        // scripts/test-lifecycle.sh fails on this line.
        if bus.consumer !== consumer {
            logger.log("BUS WATCHER MISMATCH: observing \(ObjectIdentifier(bus.consumer)), current \(ObjectIdentifier(consumer))")
        }
#endif
        busErrorWatcher?.cancel()
        busErrorWatcher = bus.errorWatcher
        setProcessor(bus.processor)
        bus.armed.armed = true
        // A death between the start and this install reached an unarmed
        // watcher; it is acted on here instead.
        if let pending = bus.consumer.error {
            scheduleBusRestart(localAPI: bus.localAPI, consumer: bus.consumer, error: pending)
        }
    }

    @MainActor
    private func scheduleBusRestart(localAPI: LocalAPIClient, consumer: TSNetConsumer,
                                    error: Error) {
        if LoopbackHealth.isLocalLoopbackConnectionFailure(error) {
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
#if LATCHKEY_TEST_HOOKS
                let hold = self.takeBusInstallHoldForTest()
#else
                let hold: Duration? = nil
#endif
                let bus = try await self.startEventBus(
                    localAPI: localAPI, consumer: consumer, holdForTest: hold)
                // Checked AFTER the start (F16 §4.2): a loopback recovery that
                // cancelled this task while the start was in flight has
                // installed its own bus by now, for a new consumer. What was
                // started here observes the old one and must not go in.
                guard !Task.isCancelled else {
                    logger.log("Bus restart superseded while starting; its bus is discarded")
                    bus.cancel()
                    return
                }
                self.installBus(bus)
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

    /// `backendStatus()` raced against `LoopbackHealth.statusBound` (F16).
    /// TailscaleKit's request carries a 60 s timeout (LocalAPIClient.swift:337)
    /// that no caller here may inherit. Throws `LoopbackStatusTimeout` at the
    /// bound; the abandoned request is cancelled, which URLSession's async API
    /// honours. An answer slower than `slowAnswer` is logged, because the
    /// bound is chosen, not measured (F16 §8).
    nonisolated static func boundedStatus(_ client: LocalAPIClient,
                                          within bound: Duration = LoopbackHealth.statusBound)
        async throws -> IpnState.Status {
        let started = ContinuousClock.now
        let status = try await LoopbackHealth.bounded(within: bound) { try await client.backendStatus() }
        let took = ContinuousClock.now - started
        if took > LoopbackHealth.slowAnswer {
            let ms = took.components.seconds * 1000 + took.components.attoseconds / 1_000_000_000_000_000
            logger.log("Status request answered after \(ms) ms (bound \(bound.components.seconds) s)")
        }
        return status
    }

    /// A bounded status request answered: the loopback carries bytes.
    @MainActor
    private func statusAnswered() {
        statusStalls.answered()
    }

    /// A bounded status request was abandoned (F16 §4.1). The second in a row
    /// replaces the loopback, as a refused one is replaced.
    @MainActor
    private func statusAbandoned() {
        let (strike, recover) = statusStalls.abandoned()
        logger.log("Status request abandoned after \(LoopbackHealth.statusBound.components.seconds) s (\(strike) of \(LoopbackStallCount.strikes) before loopback recovery)")
        if recover {
            recoverLoopbackAfterFailure(LoopbackStatusTimeout())
        }
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
#if LATCHKEY_TEST_HOOKS
                let hold = self.shutDownDuringRecoveryIfRequested()
#else
                let hold: Duration? = nil
#endif
                let bus = try await self.startEventBus(
                    localAPI: newClient, consumer: newConsumer, holdForTest: hold)
                // Covers the watcher too (F16 §4.2): a shutdown() during the
                // start bumped the generation, and before F16 the watcher had
                // already been installed on a manager whose node was closing.
                guard !Task.isCancelled,
                      generation == self.loopbackRecoveryGeneration else {
                    bus.cancel()
                    return
                }
                self.consumer = newConsumer
                self.localAPIClient = newClient
                self.installBus(bus)

                // Replace the app-owned relay too: its upstream port and SOCKS
                // credential changed with the tsnet loopback listener. The
                // old relay's sessions ride tsnet's accepted connections,
                // which a closed listener leaves open, so they run on to
                // their end (`SocksLogProxy.stop`); only new ones use this.
                self.socksLogProxy?.stop()
                self.socksLogProxy = nil
                self.socksLogProxyPort = nil
#if LATCHKEY_TEST_HOOKS
                self.loopbackErrorDuringRecoveryRelayIfRequested(generation: generation)
#endif
                let config = await self.proxyConfig(loopback)
                // Rechecked after the relay's start (F16 §4.3): a shutdown()
                // or a newer recovery in that time owns what is published.
                guard !Task.isCancelled,
                      generation == self.loopbackRecoveryGeneration else { return }
                self.model.proxyConfiguration = config
                self.busRestartBackoff = .milliseconds(500)
                self.loopbackRecoveryTask = nil
#if LATCHKEY_TEST_HOOKS
                self.model.tcpChaosTestStatus = self.loopbackErrorInjectedGeneration.map {
                    $0 < generation ? "recovered again" : "recovered" } ?? "recovered"
#else
                self.model.tcpChaosTestStatus = "recovered"
#endif
                logger.log("LocalAPI loopback recovered at \(loopback.address), generation \(generation)")
                // The new bus is armed from its install, and the relay start
                // above is awaited: a loopback failure it reported in that
                // time found this recovery still in flight and was dropped
                // (recoverLoopbackAfterFailure's guard). It is acted on now,
                // or the bus stays dead with nothing left to restart it. Any
                // other error took the ordinary restart path when it arrived.
                if let pending = self.consumer.error, LoopbackHealth.isLocalLoopbackConnectionFailure(pending) {
                    self.scheduleBusRestart(localAPI: newClient, consumer: newConsumer, error: pending)
                }
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
                        let status = try await Self.boundedStatus(client)
#if LATCHKEY_TEST_HOOKS
                        await self.stallLoopbackBeforePublishingIfRequested(status)
#endif
                        await MainActor.run {
                            // A successful request proves the local listener is
                            // carrying bytes again; future watcher failures may
                            // start from the short retry delay.
                            self.busRestartBackoff = .milliseconds(500)
                            self.statusAnswered()
                            self.model.localStatus = status
                            if status.BackendState == "Running" {
                                self.runTCPChaosTestIfNeeded()
#if LATCHKEY_TEST_HOOKS
                                self.scheduleBusDeathsIfRequested()
#endif
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
                            if error is LoopbackStatusTimeout {
                                self.statusAbandoned()
                                return
                            }
                            logger.log("Status poll failed: \(error)")
                            if LoopbackHealth.isLocalLoopbackConnectionFailure(error) {
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
    ///
    /// Async since F16 §4.3: starting the relay awaits its listener instead of
    /// blocking the main actor. A loopback recovery or `shutdown()` during
    /// that wait supersedes the call, which then returns nil and records
    /// nothing; callers check `loopbackRecoveryGeneration` before publishing,
    /// so a superseded nil never replaces what the newer caller published.
    func proxyConfig(_ loopbackConfig: TailscaleNode.LoopbackConfig) async -> ProxyConfiguration? {
        guard let ip = loopbackConfig.ip, let port = loopbackConfig.port else {
            return nil
        }
        return await proxyConfig(upstreamHost: ip, upstreamPort: port,
                                 credential: loopbackConfig.proxyCredential)
    }

    /// The same, from plain values: tsnet's loopback listener in production,
    /// or the stub proxy in the offline test harness (R11). Starts the
    /// logging relay in front of it when enabled, records the endpoint for
    /// later rescoping, and builds the configuration through
    /// `ProxyConfigurationFactory`.
    func proxyConfig(upstreamHost ip: String, upstreamPort port: Int,
                     credential: String) async -> ProxyConfiguration? {
        let generation = loopbackRecoveryGeneration

        // Route WebKit through the logging relay (Settings → Logs) so every
        // connection attempt that reaches the tailnet proxy is recorded with
        // its outcome. tsnet's own SOCKS server logs only failures and not the
        // reply code, so without this the absence of a log line is ambiguous:
        // it could mean "iOS never sent it to us" OR "it succeeded".
        var proxyHost = ip
        var proxyPort = port
        if SocksLogProxy.isEnabled() {
            if let upstreamPort = UInt16(exactly: port) {
                await startRelayIfNeeded(upstreamHost: ip, upstreamPort: upstreamPort)
            }
            guard generation == loopbackRecoveryGeneration else {
                logger.log("proxyConfig: superseded while its relay started; not publishing")
                return nil
            }
            if let localPort = socksLogProxyPort {
                proxyHost = "127.0.0.1"
                proxyPort = Int(localPort)
            }
        }

        recordProxyEndpoint(host: proxyHost, port: proxyPort, credential: credential)
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

    /// The relay start in flight, and the loopback generation it belongs to
    /// (F16 §4.3). A second caller of the same generation joins it rather
    /// than starting another relay; a caller of a newer one starts its own.
    @MainActor private var relayStart: (generation: UInt64, task: Task<Void, Never>)?

    /// Starts the logging relay in front of `upstreamHost:upstreamPort` unless
    /// one is running, without blocking: the listener's `.ready` is awaited.
    /// A start superseded while in flight (a loopback recovery or `shutdown()`
    /// bumped `loopbackRecoveryGeneration`, and replaced or cleared the relay)
    /// stops the relay it started instead of installing it: its upstream is
    /// the replaced loopback, and installing it over the newer relay would
    /// point WebKit at a dead listener.
    @MainActor
    private func startRelayIfNeeded(upstreamHost ip: String, upstreamPort: UInt16) async {
        let generation = loopbackRecoveryGeneration
        if let inFlight = relayStart, inFlight.generation == generation {
            await inFlight.task.value
            return
        }
        guard socksLogProxy == nil else { return }
        let relay = SocksLogProxy(upstreamHost: ip, upstreamPort: upstreamPort,
                                  onListenerFailed: { [weak self] failed in
            Task { @MainActor [weak self] in self?.relayListenerFailed(failed) }
        }, onProxyReply: { [weak self] reply in
            // One hop to the main actor, where the page reads it (F4
            // §4.5). Last-one-wins is correct: a sweep's twelve refusals
            // are all for hosts the page is not loading, and the page
            // matches on target and time before believing any of them.
            Task { @MainActor [weak self] in self?.model.lastProxyFailure = reply }
        })
#if LATCHKEY_TEST_HOOKS
        recoverDuringRelayStartIfRequested()
        let stallWindow = MainThreadStallMonitor.shared.window()
        defer { stallWindow.map(MainThreadStallMonitor.shared.close) }
#endif
        let task = Task { @MainActor [weak self] in
            let localPort = await relay.start()
            guard let self else {
                relay.stop()
                return
            }
            guard generation == self.loopbackRecoveryGeneration, self.socksLogProxy == nil else {
                logger.log("sockslog: a relay start was superseded while in flight; stopping it")
                relay.stop()
                return
            }
            if let localPort {
                self.socksLogProxy = relay
                self.socksLogProxyPort = localPort
            } else {
                self.recordRelayFallback(after: "no listener could be started")
            }
        }
        relayStart = (generation, task)
        await task.value
        if relayStart?.generation == generation { relayStart = nil }
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

    /// The page reports a load that failed (R30). If it looks like WebKit could
    /// not reach the logging relay -- a transport error while the node is
    /// Running and tsnet's own loopback answers, with the relay having
    /// accepted nothing for the navigation -- the relay's own port is probed,
    /// and a listener that refuses the probe is restarted and the proxy
    /// configuration republished, which the page takes as its cue to retry.
    /// The verdict is `SocksRelayRecovery`'s; this gathers its evidence.
    /// Failures the relay accepted (a dead gateway is also -1000) are left
    /// alone: the relay's own log line says what tsnet replied, and a new
    /// listener would change nothing. So is a listener that answers the
    /// probe (R30 review): the accept inference misreads a pooled connection
    /// WebKit reused, and a failure that never dialed the proxy.
    @MainActor
    func pageLoadFailed(_ failure: SocksRelayRecovery.PageFailure) {
        guard let relay = socksLogProxy, let port = socksLogProxyPort,
              SocksRelayRecovery.isTransportFailure(domain: failure.domain, code: failure.code)
        else { return }
        // Read before the loopback round trip: a connection accepted for
        // something else meanwhile (the probe's own, for one) must not pass
        // for this load's.
        let accepted = relay.hasAcceptedSession(since: failure.navigationStartedAt)
        Task { [weak self] in
            guard let self else { return }
            let answers = await self.refreshStatusNow()
            var evidence = SocksRelayRecovery.Evidence(
                failure: failure,
                // A loopback recovery may have replaced the relay meanwhile.
                relayInUse: self.socksLogProxy === relay && self.socksLogProxyPort == port,
                nodeRunning: self.model.state == .Running,
                loopbackRecoveryInFlight: self.loopbackRecoveryTask != nil,
                upstreamAnswers: answers,
                relayAcceptedSinceNavigation: accepted)
            if case .probe = SocksRelayRecovery.decide(evidence) {
                // The final guard, and the one that costs a connection: only
                // once everything else points at the listener.
                let outcome = await SocksLogProxy.probe(port: port)
                self.countProbe(outcome)
                evidence = evidence.probed(outcome)
            }
            switch SocksRelayRecovery.decide(evidence) {
            case .restart:
                self.restartSocksRelayWithinBudget(
                    reason: "page failed with \(failure.domain) \(failure.code), nothing reached the relay, and its listener \(evidence.listener?.rawValue ?? "?") a probe")
            case .leave(let reason):
                logger.log("sockslog: relay listener kept after \(failure.domain) \(failure.code): \(reason)")
            case .probe:
                // Unreachable: the probe's finding is in the evidence now.
                break
            }
        }
    }

    /// The dashboard session check got no answer twice in a row (R30
    /// review). The page-world fetch says nothing about why -- the gateway,
    /// the tailnet, or the relay's port under it -- so the relay's listener
    /// is probed, and restarted only if it refuses.
    @MainActor
    func sessionCheckUnanswered() {
        probeRelayListener(trigger: "session check unanswered twice")
    }

    /// A loopback connect to the relay's own port, off the main actor, when
    /// nothing else can tell whether the listener survived (R30 review): on
    /// return to the foreground, and after an unanswered session check. The
    /// page's WebSocket reconnects and its own fetches fail at a dead port
    /// without any main-frame navigation failing, so `pageLoadFailed` never
    /// hears of it. Gathers evidence only: a listener that answers is left
    /// alone, one that refuses is restarted within the budget. Never rebuilds
    /// anything on the foreground itself (PLAN M6.1).
    @MainActor
    private func probeRelayListener(trigger: String) {
        guard let relay = socksLogProxy, let port = socksLogProxyPort,
              model.state == .Running, loopbackRecoveryTask == nil,
              !relayRestartInFlight, relayProbeTask == nil
        else { return }
        relayProbeTask = Task { [weak self] in
            let outcome = await SocksLogProxy.probe(port: port)
            guard let self else { return }
            self.relayProbeTask = nil
            self.countProbe(outcome)
            // Replaced or restarted meanwhile: the finding is about a port
            // WebKit no longer uses.
            guard self.socksLogProxy === relay, self.socksLogProxyPort == port else { return }
            switch SocksRelayRecovery.decide(probe: outcome) {
            case .restart:
                self.restartSocksRelayWithinBudget(reason: "its listener \(outcome.rawValue) a probe (\(trigger))")
            case .leave(let reason):
                logger.log("sockslog: relay listener probed (\(trigger)): \(reason)")
            case .probe:
                break
            }
        }
    }

    @MainActor
    private func countProbe(_ outcome: SocksRelayRecovery.ListenerProbe) {
        AppDiagnostics.shared.socksRelayProbes += 1
        if outcome != .answers { AppDiagnostics.shared.socksRelayProbesFailed += 1 }
    }

    /// The listener told the relay it failed after it had been ready (R30
    /// review): the one case iOS reports a defuncted listener rather than
    /// leaving it looking alive. Replace it, within the budget -- if it is
    /// still the relay in use: a relay replaced by a loopback recovery can
    /// report its listener's failure after the fact (M6 review), and must
    /// not cost its successor a restart.
    @MainActor
    private func relayListenerFailed(_ failed: SocksLogProxy) {
        guard socksLogProxy === failed else { return }
        restartSocksRelayWithinBudget(reason: "its listener reported failure")
    }

    @MainActor
    private func restartSocksRelayWithinBudget(reason: String) {
        guard !relayRestartInFlight else {
            logger.log("sockslog: relay listener restart already in flight; not restarting again for: \(reason)")
            return
        }
        guard relayRestartBudget.allow(now: Date()) else {
            logger.log("sockslog: relay listener restart refused (\(reason)): \(relayRestartBudget.maxRestarts) already in \(Int(relayRestartBudget.window))s")
            return
        }
        restartSocksRelay(reason: reason)
    }

    /// Replaces the relay's listener and republishes the proxy configuration
    /// on the new port (R30). The wait for the new port is on the relay's
    /// queue, not the main actor (R30 review). If no listener can be started,
    /// WebKit is pointed at tsnet directly rather than at a dead port; the
    /// log then loses its per-connection lines until the next node start.
    @MainActor
    private func restartSocksRelay(reason: String) {
        guard let relay = socksLogProxy, proxyEndpoint != nil, !relayRestartInFlight else { return }
        relayRestartInFlight = true
        logger.log("sockslog: restarting the relay listener: \(reason)")
        Task { [weak self] in
            let port = await relay.restartListener()
            guard let self else { return }
            self.relayRestartInFlight = false
            // Replaced by a loopback recovery, or shut down, while waiting.
            guard self.socksLogProxy === relay, let endpoint = self.proxyEndpoint else { return }
            if let port {
                self.socksLogProxyPort = port
                self.publishProxyConfiguration(host: "127.0.0.1", port: Int(port), credential: endpoint.credential)
                AppDiagnostics.shared.socksRelayRestarts += 1
                self.model.tcpChaosTestStatus = "relay recovered"
            } else {
                self.socksLogProxy = nil
                self.socksLogProxyPort = nil
                self.recordRelayFallback(after: "no replacement listener could be started")
                self.publishProxyConfiguration(host: relay.upstreamHost, port: Int(relay.upstreamPort),
                                               credential: endpoint.credential)
            }
        }
    }

    /// WebKit is being pointed at tsnet's proxy directly because the relay
    /// has no listener (R30 review): counted and said once, since from here
    /// on the log has no per-connection lines to show it.
    @MainActor
    private func recordRelayFallback(after cause: String) {
        AppDiagnostics.shared.socksRelayFallbacks += 1
        logger.log("sockslog: \(cause); WebKit uses tsnet's proxy directly until the next node start (fallback \(AppDiagnostics.shared.socksRelayFallbacks))")
    }

    /// Records the SOCKS endpoint WebKit is about to be given, and bumps the
    /// model's endpoint generation when the host or port changed (R30
    /// review): that is what tells the page a transport was replaced, as
    /// opposed to rescoped.
    @MainActor
    private func recordProxyEndpoint(host: String, port: Int, credential: String) {
        if proxyEndpoint?.host != host || proxyEndpoint?.port != port {
            model.proxyEndpointGeneration &+= 1
        }
        proxyEndpoint = (host, port, credential)
    }

    /// Publishes a configuration for a new SOCKS endpoint under the current
    /// rules. Built fresh, not edited in place, for R12's reason.
    @MainActor
    private func publishProxyConfiguration(host: String, port: Int, credential: String) {
        let policy = model.proxyPolicy
            ?? StableProxyPolicy.make(from: model.localStatus, exitNodeEnabled: proxyEverythingRequested())
        guard let updated = ProxyConfigurationFactory.make(
            proxyHost: host, proxyPort: port, credential: credential, policy: policy)
        else {
            logger.log("proxyConfig: invalid proxy endpoint port \(port); not republishing")
            return
        }
        recordProxyEndpoint(host: host, port: port, credential: credential)
        model.proxyPolicy = policy
        model.proxyConfiguration = updated
        logger.log("proxyConfig: endpoint replaced, WebKit now uses \(host):\(port) (endpoint generation \(model.proxyEndpointGeneration))")
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
            // before damaging all TCP sockets in the process. Two seconds was
            // upstream's fixed delay, measured from the poll that also starts
            // the first load; a cold WebKit's first load can take longer, and
            // the L2 lifecycle tests need the page provably up before the
            // damage -- or, for a first-load test, the damage during it. So
            // `-UITestTCPChaosDelay <seconds>` sets it (M6).
            let delay = TestHooks.value("-UITestTCPChaosDelay").flatMap(Double.init) ?? 2
            try? await Task.sleep(for: .seconds(delay))
            self.model.tcpChaosTestStatus = "damaging"
#if LATCHKEY_TEST_HOOKS
            if TestHooks.flag("-UITestDefunctRelayListener") {
                // R30: only the app-owned relay listener dies. tsnet's stays
                // up, so the status poll notices nothing; the next failed
                // page load is what must bring it back.
                logger.log("TCP chaos test: defuncting the relay listener")
                self.socksLogProxy?.debugDefunctListener()
                self.model.tcpChaosTestStatus = "relay damaged"
                return
            }
#endif
            do {
                if TestHooks.flag("-UITestStallLoopback") {
                    logger.log("TCP chaos test: stalling the tsnet loopback listener")
                    try await node.debugStallLoopback()
                } else if TestHooks.flag("-UITestDefunctLoopback") {
                    logger.log("TCP chaos test: defuncting the tsnet loopback listener")
                    try await node.debugDefunctLoopback()
                } else {
                    logger.log("TCP chaos test: shutting down the process's TCP sockets")
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

#if LATCHKEY_TEST_HOOKS
    /// `-UITestStallLoopback -UITestTCPChaosDelay 0` (F16): the loopback goes
    /// silent BEFORE the first Running status with peers is published, not
    /// after it. That status is what starts the picker's first sweep, so
    /// through `runTCPChaosTestIfNeeded` the stall would race the sweep and
    /// some probes would get through. Awaited by the poll, so the sweep
    /// starts on a loopback that is already silent. Any other delay fires
    /// through `runTCPChaosTestIfNeeded` as the other hooks do.
    @MainActor
    private func stallLoopbackBeforePublishingIfRequested(_ status: IpnState.Status) async {
        guard TestHooks.flag("-UITestStallLoopback"), TestHooks.value("-UITestTCPChaosDelay") == "0",
              !didRunTCPChaosTest, status.BackendState == "Running",
              !(status.Peer ?? [:]).isEmpty, let node
        else { return }
        didRunTCPChaosTest = true
        logger.log("TCP chaos test: stalling the tsnet loopback listener before the first status")
        do {
            try await node.debugStallLoopback()
            model.tcpChaosTestStatus = "damaged"
        } catch {
            model.tcpChaosTestStatus = "failed: \(error)"
            logger.log("TCP chaos test failed: \(error)")
        }
    }

    /// `-UITestBusErrorAfter <s>[,<s>...]` (F16 §6.1): at each offset from
    /// the first Running status poll, the IPN bus dies as it does every idle
    /// minute: its processor stops and the current consumer gets a -1001. An
    /// ordinary restart follows, IF a watcher observes that consumer; the
    /// lifecycle test's Login is what tells. The chaos label reads
    /// `bus death N` so a test can order itself after one.
    @MainActor private var didScheduleBusDeaths = false
    @MainActor
    private func scheduleBusDeathsIfRequested() {
        guard !didScheduleBusDeaths, let spec = TestHooks.value("-UITestBusErrorAfter") else { return }
        didScheduleBusDeaths = true
        let offsets = spec.split(separator: ",").compactMap { Double($0) }
        for (i, offset) in offsets.enumerated() {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(offset))
                guard let self else { return }
                logger.log("TCP chaos test: killing the IPN bus (death \(i + 1) of \(offsets.count))")
                self.processor?.cancel()
                self.consumer.error = URLError(.timedOut)
                self.model.tcpChaosTestStatus = "bus death \(i + 1)"
            }
        }
    }

    /// `-UITestRecoverDuringFirstBusStart`: the launch's own bus start is
    /// held 3 s, and half a second into it the loopback is closed and
    /// replaced, so the recovery installs its bus first. The launch's start
    /// then finishes stale, for the replaced consumer; installing it logs
    /// `BUS WATCHER MISMATCH` (scripts/test-lifecycle.sh).
    @MainActor private var recoverDuringFirstBusStartTaken = false
    @MainActor
    private func recoverDuringFirstBusStartIfRequested() -> Duration? {
        guard TestHooks.flag("-UITestRecoverDuringFirstBusStart"), !recoverDuringFirstBusStartTaken,
              let node else { return nil }
        recoverDuringFirstBusStartTaken = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            logger.log("TCP chaos test: replacing the loopback inside the first bus start")
            do {
                try await node.debugDefunctLoopback()
            } catch {
                logger.log("TCP chaos test failed: \(error)")
                return
            }
            self.recoverLoopbackAfterFailure(URLError(.cannotConnectToHost))
        }
        return .seconds(3)
    }

    /// `-UITestLoopbackErrorDuringRecoveryRelay`: the first recovery's new
    /// bus reports a loopback failure while the recovery waits for its relay.
    /// Acted on, it is a second recovery: the chaos label reads `recovered
    /// again`. Dropped, it stays `recovered`, with a bus nothing restarts.
    @MainActor private var loopbackErrorInjectedGeneration: UInt64?
    @MainActor
    private func loopbackErrorDuringRecoveryRelayIfRequested(generation: UInt64) {
        guard TestHooks.flag("-UITestLoopbackErrorDuringRecoveryRelay"),
              loopbackErrorInjectedGeneration == nil,
              let failing = URL(string: "http://127.0.0.1/localapi/v0/watch-ipn-bus") else { return }
        loopbackErrorInjectedGeneration = generation
        logger.log("TCP chaos test: a loopback failure on the new bus while the recovery's relay starts")
        consumer.error = URLError(.networkConnectionLost, userInfo: [NSURLErrorFailingURLErrorKey: failing])
    }

    /// `-UITestBusInstallDelay <s>` (F16 §6.1): the FIRST ordinary bus
    /// restart takes this long to start, so a loopback recovery fired inside
    /// it supersedes it with its start in flight. Once only: the restarts
    /// after it must be prompt, or the test's Login has no bus to arrive on.
    @MainActor private var busInstallHoldTaken = false
    @MainActor
    private func takeBusInstallHoldForTest() -> Duration? {
        guard !busInstallHoldTaken,
              let s = TestHooks.value("-UITestBusInstallDelay").flatMap(Double.init) else { return nil }
        busInstallHoldTaken = true
        return .seconds(s)
    }

    /// `-UITestShutdownDuringRecovery` (F16 §6.3): the first loopback
    /// recovery's bus start is held 4 s, and 1 s into the hold the manager is
    /// shut down as a workspace deletion does. When the hold is long over,
    /// the chaos label reads whether a watcher or processor was installed
    /// after shutdown cleared them: `bus after shutdown` or `shutdown clean`.
    @MainActor private var shutdownDuringRecoveryTaken = false
    @MainActor
    private func shutDownDuringRecoveryIfRequested() -> Duration? {
        guard TestHooks.flag("-UITestShutdownDuringRecovery"), !shutdownDuringRecoveryTaken else { return nil }
        shutdownDuringRecoveryTaken = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            logger.log("TCP chaos test: shutting the manager down inside the recovery's bus start")
            await self.shutdown()
            try? await Task.sleep(for: .seconds(6))
            let installed = self.busErrorWatcher != nil || self.processor != nil
            logger.log("TCP chaos test: after shutdown, bus \(installed ? "INSTALLED" : "not installed")")
            self.model.tcpChaosTestStatus = installed ? "bus after shutdown" : "shutdown clean"
        }
        return .seconds(4)
    }

    /// `-UITestRecoverDuringRelayStart` (F16 §6.4): half a second into the
    /// first relay start, the tsnet loopback is closed and replaced, as a
    /// failed LocalAPI request would have it. With `-UITestRelayReadyDelay`
    /// that start is still in flight when the recovery installs its own relay,
    /// so it finishes stale: pointed at the closed listener. On demand rather
    /// than by scheduling accident.
    @MainActor private var recoverDuringRelayStartTaken = false
    @MainActor
    private func recoverDuringRelayStartIfRequested() {
        guard TestHooks.flag("-UITestRecoverDuringRelayStart"), !recoverDuringRelayStartTaken,
              let node else { return }
        recoverDuringRelayStartTaken = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            logger.log("TCP chaos test: replacing the loopback inside the first relay start")
            do {
                try await node.debugDefunctLoopback()
            } catch {
                logger.log("TCP chaos test failed: \(error)")
                return
            }
            self.recoverLoopbackAfterFailure(URLError(.cannotConnectToHost))
        }
    }

    nonisolated private static func holdIgnoringCancellation(_ hold: Duration) async {
        let seconds = Double(hold.components.seconds) + Double(hold.components.attoseconds) / 1e18
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { c.resume() }
        }
    }
#endif

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
        relayProbeTask?.cancel()
        relayProbeTask = nil
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
        if model.startFailure != nil { backgroundedSinceStartFailure = true }
    }

    func willEnterForeground() {
        // Recovery is driven by an actual loopback connection failure, not by
        // scene lifecycle: iOS can defunct sockets for reasons other than lock.
        logger.log("Foreground: no lifecycle recovery; awaiting actual socket errors")
        if model.startFailure != nil {
            // F8 §4.3: a return to the app is new information (a port freed,
            // space made), so a failing start is retried now on a fresh
            // schedule. The launch's own first `.active` is not a return,
            // and must not jump the schedule already running.
            if backgroundedSinceStartFailure {
                backgroundedSinceStartFailure = false
                startTracker.restartSchedule()
                startTailscaleIfNeeded()
            }
        } else if node == nil {
            startTailscaleIfNeeded()
        }
        // The relay listener is the one socket nothing polls (R30 review), so
        // it is asked -- a loopback connect, off the main actor. A refusal is
        // the socket error awaited above; an answer changes nothing.
        probeRelayListener(trigger: "foreground")
    }

    /// Returns whether the node's loopback answered (Latchkey: discovery
    /// uses that as its proxy-health signal, since the same listener serves
    /// SOCKS5 and LocalAPI).
    @discardableResult
    func refreshStatusNow() async -> Bool {
        guard let client = localAPIClient else { return false }
        do {
            // Bounded (F16): discovery's "Searching…" and `pageLoadFailed`'s
            // relay verdict both wait on this.
            let status = try await Self.boundedStatus(client)
            statusAnswered()
            model.localStatus = status
            refreshProxyPolicyIfNeeded()
            return true
        } catch is LoopbackStatusTimeout {
            statusAbandoned()
            return false
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

