// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ShareViewController.swift
//  ShareExtension
//
//  "Latchkey" in the share sheet's app row (F3 §4.2, stage 2). It CAPTURES
//  and never sends: the node, its proxy and the signed-in page all live in
//  the app's process (F3 §4.4), so this writes one item to the inbox in the
//  App Group container and says "Saved. Open Latchkey to send it."
//
//  It links no TailscaleKit and touches no node state. It runs in a process
//  with a hard memory limit of about 120 MB, so no file is ever read into
//  memory here (`ShareCaptureModel`).
//
//  No notification and no attempt to open the app (F3 §8 Q2, decided
//  2026-09-24: R34/D6's "no notifications in v1" covers this; the text is
//  the bounce). `NSExtensionContext.open` is not supported for share
//  extensions, and the responder-chain trick is not used.
//

import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
    private let model = ShareCaptureModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] saved in
            guard let context = self?.extensionContext else { return }
            if saved {
                context.completeRequest(returningItems: nil)
            } else {
                context.cancelRequest(withError: CocoaError(.userCancelled))
            }
        }
        let host = UIHostingController(rootView: ShareCaptureView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        model.load(extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? [])
    }
}
