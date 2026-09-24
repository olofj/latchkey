// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  LocalCopy.swift
//  Latchkey
//
//  Copy for diagnostics. What these screens copy names the tailnet, its
//  addresses, its peers and the gateway: it goes on this device's pasteboard
//  only, never to the user's other devices through Universal Clipboard (the
//  concern R23 raised for pasted sign-in links).
//

#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers

enum LocalCopy {
    static func text(_ text: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]],
                                      options: [.localOnly: true])
    }
}
#endif
