// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ProcessLogging.swift
//  Latchkey
//
//  The process-wide tsnet logging every node shares (one logtail; Go runtime
//  stderr captured by its persistent filch, R29). It must be set up before
//  any `TailscaleNode` exists, and a node must never be created while it is
//  not (F8 §1.4, §4.6): the filch is where tsnet's Go stderr is redacted
//  before it is written, and login links are what that stderr carries.
//
//  Set up once by `WorkspaceManager.init`. Every node start asks again, so a
//  failure there is a refusal the gate can show (G7) and Try now can retry,
//  rather than the launch-time `fatalError` it used to be.
//

import Foundation
import TailscaleKit

enum ProcessLogging {
    private static var isSetUp = false

    /// Sets up process logging if it is not already, and returns why it could
    /// not be. Idempotent; a failed attempt may be retried.
    static func setUp() -> Error? {
        if isSetUp { return nil }
        do {
#if LATCHKEY_TEST_HOOKS
            // F8 §6.2: the logs directory made unusable, without making it so.
            if TestHooks.flag("-UITestLoggingSetupFails") {
                throw POSIXError(.EACCES)
            }
#endif
            try TailscaleLogging.setup(directory: WorkspaceStore.logsDir.path)
            isSetUp = true
            return nil
        } catch {
            return error
        }
    }
}
