// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  TestHooks.swift
//  Latchkey
//
//  The one door every test hook goes through (revision R15).
//
//  A test hook is a launch argument or environment variable that changes what
//  the app does: stage an auth key, reset state, route everything through the
//  proxy, point the app at a stub proxy or a fake control plane. Several of
//  those are exactly what an attacker with a paired Mac would want — upstream's
//  `-AuthKey` alone joins the app to a foreign tailnet.
//
//  Upstream gated some behind DEBUG and most behind nothing. DEBUG is not a
//  boundary here: the build that goes on the phone is installed with Xcode's
//  Run, which uses the Debug configuration. So every hook reads through this
//  type, which returns nothing unless LATCHKEY_TEST_HOOKS is compiled in — and only
//  the Testing build configuration, used by the scheme's Test action, defines
//  it. Code that must not ship at all (a private-SPI call, the harness views)
//  sits inside `#if LATCHKEY_TEST_HOOKS` instead.
//
//  To add a hook: read it here, never through ProcessInfo directly. That keeps
//  `grep -rn ProcessInfo.processInfo.arguments App TSNet` down to this file and
//  WorkspaceStore's data-isolation check.
//

import Foundation

enum TestHooks {
    /// Whether this build carries test hooks at all.
    nonisolated static var compiledIn: Bool {
#if LATCHKEY_TEST_HOOKS
        true
#else
        false
#endif
    }

    /// True when the launch argument `name` is present, in a test build.
    nonisolated static func flag(_ name: String) -> Bool {
#if LATCHKEY_TEST_HOOKS
        ProcessInfo.processInfo.arguments.contains(name)
#else
        false
#endif
    }

    /// The argument following `name` (`-Name value`), in a test build.
    /// Empty values count as absent.
    nonisolated static func value(_ name: String) -> String? {
#if LATCHKEY_TEST_HOOKS
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        let v = args[i + 1]
        return v.isEmpty ? nil : v
#else
        nil
#endif
    }

    /// True when any launch argument starts with `prefix`, in a test build:
    /// for telling "absent" from "present but malformed" (`-Name=value`,
    /// `-Name` with no value).
    nonisolated static func anyArgument(hasPrefix prefix: String) -> Bool {
#if LATCHKEY_TEST_HOOKS
        ProcessInfo.processInfo.arguments.dropFirst().contains { $0.hasPrefix(prefix) }
#else
        false
#endif
    }

    /// The environment variable `name`, in a test build. Empty counts as
    /// absent.
    nonisolated static func environment(_ name: String) -> String? {
#if LATCHKEY_TEST_HOOKS
        guard let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else { return nil }
        return v
#else
        nil
#endif
    }
}
