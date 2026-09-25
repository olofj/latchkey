// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ShareOutcome.swift
//  Latchkey
//
//  What a gateway's answer means for a share (F3 §4.5), and what the owner
//  reads. Pure, so scripts/test-share.sh checks every answer on the host.
//
//  "Sent" is only ever the gateway's word: a `{"ok": true}` from
//  `POST /api/chat`. A busy session's `{"ok": true, "queued": true}` is
//  QUEUED, said as such and never as sent -- the earlier draft's named
//  hazard. Refusals keep the gateway's own `error` text, verbatim.
//

import Foundation

nonisolated enum ShareOutcome: Equatable {
    case sent(slot: String)
    case queued(slot: String)
    /// 403 with `X-Auth-Required`: the dashboard session lapsed. The item
    /// waits for sign-in, and nothing is re-shared.
    case signedOut
    /// The remembered or chosen session is not in the list just fetched.
    case sessionGone
    /// The gateway said no; `text` is its own `error`, or nil for a bare
    /// refusal (a CSRF 403 is text/plain).
    case refused(status: Int, text: String?)
    /// No answer: the tailnet, the gateway or the phone is down.
    case unreachable
    /// The upload stopped partway through the staged chunks.
    case uploadInterrupted(done: Int, of: Int)

    /// The one the owner reads.
    var sentence: String { Self.sentence(for: self, gatewayHost: nil) }

    static let unreachableCode = "unreachable"

    /// A response as the page-world fetch reports it: `status` 0 or nil when
    /// the request never got an answer.
    struct Response: Equatable {
        var status: Int?
        var body: String
        var authRequired: Bool

        init(status: Int?, body: String = "", authRequired: Bool = false) {
            self.status = status
            self.body = body
            self.authRequired = authRequired
        }

        var json: [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        }
        var answered: Bool { (status ?? 0) > 0 }
    }

    /// Anything that is not a success, from any step: nil when `r` is one.
    static func failure(_ r: Response) -> ShareOutcome? {
        guard r.answered, let status = r.status else { return .unreachable }
        if status == 403, r.authRequired { return .signedOut }
        if (200..<300).contains(status) { return nil }
        return .refused(status: status, text: errorText(r))
    }

    /// The answer to `POST /api/chat` for `slot`.
    static func post(_ r: Response, slot: String) -> ShareOutcome {
        if let failure = failure(r) { return failure }
        guard let json = r.json, json["ok"] as? Bool == true else {
            // A 2xx that is not the receipt proves nothing was accepted.
            return .refused(status: r.status ?? 0, text: errorText(r))
        }
        if json["queued"] as? Bool == true { return .queued(slot: slot) }
        return .sent(slot: (json["slot"] as? String) ?? slot)
    }

    /// The answer to `POST /api/upload/file`: the path to reference, or why
    /// not.
    static func upload(_ r: Response) -> Result<String, UploadFailure> {
        if let failure = failure(r) { return .failure(UploadFailure(outcome: failure)) }
        guard let paths = r.json?["paths"] as? [String], let first = paths.first, !first.isEmpty else {
            return .failure(UploadFailure(outcome: .refused(status: r.status ?? 0, text: errorText(r))))
        }
        return .success(first)
    }

    struct UploadFailure: Error, Equatable { let outcome: ShareOutcome }

    /// The gateway's `error` string, if the body is JSON carrying one.
    static func errorText(_ r: Response) -> String? {
        guard let text = r.json?["error"] as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Whether the item is done with: confirmed by the gateway.
    var isDelivered: Bool {
        switch self {
        case .sent, .queued: return true
        default: return false
        }
    }

    /// The accessibility label the UI tests read (`share-result`), and the
    /// code kept on a failed item. No content: slot keys, codes and the
    /// gateway's own error text only.
    var label: String {
        switch self {
        case .sent(let slot): return "sent:\(slot)"
        case .queued(let slot): return "queued:\(slot)"
        case .signedOut: return "failed:signed-out"
        case .sessionGone: return "failed:session-gone"
        case .refused(let status, let text?) where status != 403: return "failed:\(text)"
        case .refused(let status, _): return "failed:refused-\(status)"
        case .unreachable: return "failed:\(Self.unreachableCode)"
        case .uploadInterrupted: return "failed:upload-interrupted"
        }
    }

    /// `label` without its `failed:` prefix: what a failed item keeps.
    var code: String {
        label.hasPrefix("failed:") ? String(label.dropFirst("failed:".count)) : label
    }

    static func sentence(for outcome: ShareOutcome, gatewayHost: String?) -> String {
        let gw = gatewayHost ?? "the gateway"
        switch outcome {
        case .sent: return "Sent."
        case .queued: return "Queued — the session is mid-turn; the gateway queued it."
        case .signedOut: return "Waiting for sign-in. It will be sent when you're signed in."
        case .sessionGone: return "The session you used last time isn't there any more — pick one."
        case .refused(403, nil):
            return "\(gw) refused the message (403). Open the session with it prefilled instead?"
        case .refused(let status, let text):
            return text ?? "\(gw) refused the message (\(status))."
        case .unreachable:
            return "Couldn't reach \(gw). Kept — it will be sent when the gateway is back."
        case .uploadInterrupted(let done, let total):
            return "Upload failed after \(done) of \(total) chunks."
        }
    }

    /// Whether the prefill fallback (F3 §4.9) is offered: a bare 403 on the
    /// post, which is the ported-origin CSRF refusal (F1 §4a), for a link or
    /// text. Not for a document -- prefill carries no file.
    static func offersPrefill(_ outcome: ShareOutcome, kind: ShareItem.Kind) -> Bool {
        if case .refused(403, nil) = outcome { return kind != .document }
        return false
    }
}
