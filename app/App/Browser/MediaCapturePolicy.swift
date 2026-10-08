// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  MediaCapturePolicy.swift
//  Latchkey
//
//  Who may capture what in the web view (F23 W2).
//
//  The dashboard's voice input calls getUserMedia({audio:true}) and streams
//  the audio to the gateway's /api/ws/stt. That is the only capture Latchkey
//  allows: the microphone, asked for by the main frame, on the gateway's own
//  origin. Main frame only, because the dashboard's `about:srcdoc` widget
//  frames inherit the gateway's origin and must not get the mic with it.
//  The camera is never granted; the QR scanner is native.
//
//  The decision is recomputed from `allowedOrigin` on every request, so
//  nothing is remembered and a gateway switch moves the grant with it.
//
//  Pure Foundation so `scripts/test-media-capture-policy.sh` compiles it alone.
//

import Foundation

/// What the page asked to capture: WebKit's `WKMediaCaptureType`, without
/// WebKit, so the policy builds on the host.
nonisolated enum MediaCaptureKind: Equatable, Sendable {
    case microphone
    case camera
    case cameraAndMicrophone
    case other
}

nonisolated enum MediaCaptureDecision: Equatable, Sendable {
    /// Granted with no WebKit prompt; iOS's own TCC prompt still asks once.
    case grant
    case deny
}

enum MediaCapturePolicy {
    /// Decides a capture request.
    ///
    /// - Parameters:
    ///   - kind: what the page asked for.
    ///   - isMainFrame: whether the requesting frame is the top-level document.
    ///   - origin: the requesting origin as `scheme://host[:port]`, rendered by
    ///     `GatewayAddress.origin(of:)`; nil if it has none.
    ///   - allowedOrigin: the gateway origin the app last loaded; nil on the
    ///     error page or mid-switch.
    nonisolated static func decide(kind: MediaCaptureKind, isMainFrame: Bool,
                                   origin: String?, allowedOrigin: String?) -> MediaCaptureDecision {
        guard kind == .microphone, isMainFrame,
              let origin, let allowedOrigin, origin == allowedOrigin
        else { return .deny }
        return .grant
    }

    /// `scheme://host[:port]` for a WebKit security origin's parts, rendered
    /// as `GatewayAddress.origin(of:)` renders a URL (lowercase, default
    /// port dropped). WebKit reports port 0 for "the scheme's default".
    nonisolated static func origin(scheme: String, host: String, port: Int) -> String? {
        let authority = port > 0 ? "\(host):\(port)" : host
        return GatewayAddress.origin(of: "\(scheme)://\(authority)")
    }
}
