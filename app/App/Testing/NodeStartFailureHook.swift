// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  NodeStartFailureHook.swift
//  Latchkey
//
//  F8 §6.1: a node start that fails on demand, which is what let a
//  `fatalError` survive in the launch path — nothing could cause it.
//
//    -UITestNodeStartFails <errno>      every attempt fails (EACCES, ENOSPC,
//                                       EADDRINUSE, EPERM, EIO or a number)
//    -UITestNodeStartFailsTimes <n>     the first n attempts fail, then the
//                                       start proceeds (errno as above, or
//                                       EADDRINUSE when not given)
//
//  The failure is thrown as TailscaleKit throws a POSIX failure, before any
//  node or fixture is touched. Test builds only (R15).
//

#if LATCHKEY_TEST_HOOKS
import Foundation
import TailscaleKit

enum NodeStartFailureHook {
    private static var attempts = 0

    /// The error this start attempt must fail with, or nil to proceed.
    static func nextAttemptError() -> Error? {
        let named = TestHooks.value("-UITestNodeStartFails")
        let times = TestHooks.value("-UITestNodeStartFailsTimes")
        guard named != nil || times != nil else { return nil }
        guard let code = NodeStartFailure.errno(named: named ?? "EADDRINUSE"),
              let posix = POSIXErrorCode(rawValue: code) else {
            fatalError("-UITestNodeStartFails needs an errno name or number; got \(named ?? "")")
        }
        attempts += 1
        if let times {
            guard let n = Int(times) else {
                fatalError("-UITestNodeStartFailsTimes needs a count; got \(times)")
            }
            if attempts > n { return nil }
        }
        return TailscaleError.posixError(POSIXError(posix), "test hook")
    }
}
#endif
