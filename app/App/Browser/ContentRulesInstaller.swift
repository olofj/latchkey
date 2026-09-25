// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ContentRulesInstaller.swift
//  Latchkey
//
//  Compiles `ContentRules`' list with WebKit and caches it for the process
//  (F6 §4.3). Always compiles, never looks up: WKContentRuleListStore keys
//  compiled lists by identifier as a file name and `lookUpContentRuleList`
//  hands back whatever was compiled under that name, whatever the source
//  says now. Ten rules compile in milliseconds.
//

import WebKit

@MainActor
final class ContentRulesInstaller {
    /// The deadline, as an error the page can name like WebKit's own:
    /// `[ContentRules 1]`.
    enum Failure: Int, CustomNSError {
        case timedOut = 1
        static var errorDomain: String { "ContentRules" }
    }

    /// One per process: a compiled list is immutable, so view models share it.
    static let shared = ContentRulesInstaller()

    /// Compiled lists by identifier, for this process. Keyed by the
    /// identifier rather than the origin, because the identifier also carries
    /// the CDN setting (§4.1a): keyed by origin, flipping the toggle would
    /// reuse the list compiled for the other setting.
    private var compiled: [String: WKContentRuleList] = [:]

    static let deadline: Duration = .seconds(15)

    /// `-UITestNoContentRules`: report the list ready without installing one.
    /// The positive control for every leak test, and nothing else.
    static var disabledForTesting: Bool { TestHooks.flag("-UITestNoContentRules") }

    func cachedList(forIdentifier identifier: String) -> WKContentRuleList? {
        compiled[identifier]
    }

    /// Compiles the list for `origin` with a 15 s deadline and caches it.
    /// Throws WebKit's own error (`WKError.contentRuleListStoreCompileFailed`
    /// is the expected one) or `Failure.timedOut`.
    func list(forOrigin origin: String, allowCDNs: Bool) async throws -> WKContentRuleList {
        let identifier = ContentRules.identifier(forOrigin: origin, allowCDNs: allowCDNs)
        if let list = compiled[identifier] { return list }
        var source = ContentRules.json(forOrigin: origin, allowCDNs: allowCDNs) ?? ContentRules.brokenJSON
        if TestHooks.flag("-UITestBreakContentRules") { source = ContentRules.brokenJSON }
        let list = try await Self.compile(identifier: identifier, source: source)
        compiled[identifier] = list
        Self.removeOthers(keeping: identifier)
        return list
    }

    private static func compile(identifier: String, source: String) async throws -> WKContentRuleList {
        guard let store = WKContentRuleListStore.default() else {
            throw WKError(.contentRuleListStoreCompileFailed)
        }
        // Resumed exactly once, by whichever of the compile and the deadline
        // finishes first. Both run on the main actor.
        final class Once { var done = false }
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            let timer = Task { @MainActor in
                try? await Task.sleep(for: deadline)
                guard !once.done else { return }
                once.done = true
                continuation.resume(throwing: Failure.timedOut)
            }
            store.compileContentRuleList(forIdentifier: identifier,
                                         encodedContentRuleList: source) { list, error in
                MainActor.assumeIsolated {
                    guard !once.done else { return }
                    once.done = true
                    timer.cancel()
                    if let list {
                        continuation.resume(returning: list)
                    } else {
                        continuation.resume(throwing: error ?? WKError(.contentRuleListStoreCompileFailed))
                    }
                }
            }
        }
    }

    /// Hygiene: lists compiled for another gateway, schema or CDN setting
    /// are harmless, and removed. Errors are ignored.
    private static func removeOthers(keeping identifier: String) {
        guard let store = WKContentRuleListStore.default() else { return }
        store.getAvailableContentRuleListIdentifiers { identifiers in
            for other in identifiers ?? []
            where other.hasPrefix(ContentRules.identifierPrefix) && other != identifier {
                store.removeContentRuleList(forIdentifier: other) { _ in }
            }
        }
    }
}
