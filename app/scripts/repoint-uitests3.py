#!/usr/bin/env python3
"""Third re-point pass: the hardcoded default gateway.

Several tests assert against `http://ai/chat`, upstream's default home page.
Latchkey's default is the KiroCrew gateway (PLAN §1.7). The value is now a
single constant in the suite so the next change -- M5, when discovery chooses
the gateway -- is one edit, not four.

Also fixes the connected tests' host substring: they waited for a loaded page
whose URL contains "ai", which matched the old `ai` peer. It now has to match
the gateway host.
"""
from __future__ import annotations

import sys

SUITE = "UITests/LatchkeyUITests.swift"

CONSTANTS = '''
    // MARK: - Fixtures

    /// The app's default gateway (`HomePage.defaultURL`). The UI test target
    /// cannot import the app module, so it is duplicated here rather than
    /// shared -- keep the two in step. M5 replaces the app-side constant with
    /// a discovered gateway, at which point these tests should set a gateway
    /// explicitly instead of asserting the default.
    static let defaultGatewayURL = "https://gateway.example.ts.net"

    /// A substring of `defaultGatewayURL`'s host, used to recognise the loaded
    /// page by its URL. Upstream matched on "ai", the short name of its chat
    /// peer.
    static let defaultGatewayHostFragment = "byskebox"
'''

REPLACEMENTS = [
    ('''        XCTAssertEqual((restoredField.value as? String) ?? "", "http://ai/chat",
                       "Home page should be restored to the default after the reset relaunch")''',
     '''        XCTAssertEqual((restoredField.value as? String) ?? "", Self.defaultGatewayURL,
                       "Home page should be restored to the default after the reset relaunch")'''),
    ('''        // leftover suffix from the old value (e.g. `http://ai/chat` +
        // `FADC5F69` = `http://ai/chatFADC5F69`), writing a corrupted URL to''',
     '''        // leftover suffix from the old value (e.g. the default gateway URL +
        // `FADC5F69`), writing a corrupted URL to'''),
    ('''                      "Home page (http://ai/chat) URL was not reached within 60s. " +''',
     '''                      "Gateway (\\(Self.defaultGatewayURL)) was not reached within 60s. " +'''),
]

# The connected tests look for the loaded page by URL substring.
HOST_FRAGMENT_SITES = [
    ('waitForPageLoaded(in: app, contains: "ai", timeout: 60)',
     'waitForPageLoaded(in: app, contains: Self.defaultGatewayHostFragment, timeout: 60)'),
    ('waitForPageLoaded(in: app, contains: "ai", timeout: 45)',
     'waitForPageLoaded(in: app, contains: Self.defaultGatewayHostFragment, timeout: 45)'),
    ('waitForPageLoaded(in: app, contains: "ai", timeout: 30)',
     'waitForPageLoaded(in: app, contains: Self.defaultGatewayHostFragment, timeout: 30)'),
]

ANCHOR = """    override func setUpWithError() throws {"""


if __name__ == "__main__":
    body = open(SUITE).read()

    for old, new in REPLACEMENTS + HOST_FRAGMENT_SITES:
        count = body.count(old)
        if count == 0:
            print(f"  MISS: {old.strip().splitlines()[0][:70]!r}")
            continue
        body = body.replace(old, new)
        print(f"  x{count}: {old.strip().splitlines()[0][:70]}")

    if "defaultGatewayURL" not in body.split(ANCHOR)[0]:
        body = body.replace(ANCHOR, CONSTANTS.strip("\n") + "\n\n" + ANCHOR, 1)
        print("  added fixture constants")

    if body.count("{") != body.count("}"):
        sys.exit(f"refusing to write: unbalanced braces "
                 f"({body.count('{')} open, {body.count('}')} close)")
    open(SUITE, "w").write(body)
    print("ok")
