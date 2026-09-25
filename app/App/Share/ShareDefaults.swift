// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ShareDefaults.swift
//  Latchkey
//
//  The session each gateway was last shared to (F3 §4.7; Olof, §6 answer 1:
//  "remember the last session, preselected"). A share preference, not a
//  workspace property, so it lives apart from `WorkspaceDefinition`, in
//  `appSupportDir/share-defaults.json`.
//
//  It only ever PRESELECTS. The key is posted only if it is in the list just
//  fetched from the gateway: a remembered key that is gone would otherwise be
//  silently created as a new session (the trap in F3 §4.5).
//

import Foundation

struct ShareDefaults {
    struct Destination: Codable, Equatable {
        var slotKey: String
        var slotTitle: String?
        var at: Date
    }

    let file: URL

    /// Keyed by gateway origin (`https://host[:port]`).
    func all() -> [String: Destination] {
        guard let data = try? Data(contentsOf: file),
              let map = try? JSONDecoder().decode([String: Destination].self, from: data)
        else { return [:] }
        return map
    }

    func lastDestination(origin: String) -> Destination? { all()[origin] }

    /// The most recent destination on any OTHER gateway, if it is newer
    /// than this one's (the "Last time: … on … — switch?" line).
    func newerElsewhere(than origin: String) -> (origin: String, destination: Destination)? {
        let map = all()
        let here = map[origin]?.at ?? .distantPast
        return map.filter { $0.key != origin && $0.value.at > here }
            .max { $0.value.at < $1.value.at }
            .map { ($0.key, $0.value) }
    }

    func remember(origin: String, _ destination: Destination) {
        var map = all()
        map[origin] = destination
        try? JSONEncoder().encode(map).write(to: file, options: .atomic)
    }

    func removeAll() { try? FileManager.default.removeItem(at: file) }
}
