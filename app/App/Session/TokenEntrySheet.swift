// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  TokenEntrySheet.swift
//  Latchkey
//
//  The native sign-in sheet that replaces the page's red banner (M4.4, R22,
//  R23, D3). Three ways in, one parser (TokenInput) and one target:
//
//   - Paste, through the system PasteButton — never a silent clipboard read,
//     which would raise iOS's paste prompt and read what the user did not
//     offer.
//   - Typing (or pasting from the keyboard menu) into the field.
//   - Scanning the dashboard's Phone access QR code.
//
//  The target is always the selected gateway, named at the top before any
//  navigation. A pasted link naming another host is used with the selected
//  gateway anyway, and the sheet says so first.
//

@preconcurrency import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct TokenEntrySheet: View {
    @ObservedObject var session: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    /// What was pasted and the pasteboard's change count at that moment. The
    /// clipboard is cleared after sign-in only if the field still holds
    /// exactly this and the pasteboard has not changed since (R23).
    @State private var lastPaste: Paste?
    @State private var scanning = false

    private struct Paste {
        let text: String
        let changeCount: Int
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Signing in to") {
                        Text(session.gatewayHost ?? "the gateway")
                            .font(.body.monospaced())
                            .accessibilityIdentifier("token-sheet-target")
                    }
                    Text("Your dashboard session has ended. On a computer, run `kirocrew token` and paste what it prints — or scan the Phone access QR code on the dashboard. Links work for 5 minutes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section {
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in pasted(strings.first ?? "") }
                    }
                    .accessibilityIdentifier("token-paste-button")

                    TextField("Sign-in link or token", text: $input, axis: .vertical)
                        .lineLimit(1...4)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("token-input")

                    if Self.hasCamera {
                        Button {
                            scanning = true
                        } label: {
                            Label("Scan QR code", systemImage: "qrcode.viewfinder")
                        }
                        .accessibilityIdentifier("token-scan-button")
                    }
                }

                if let foreign = session.foreignLinkHost(in: input) {
                    Section {
                        Text("This link names \(foreign). Latchkey only signs in to \(session.gatewayHost ?? "the selected gateway"), and will try the token there.")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("token-foreign-host")
                    }
                }

                if let message = session.message {
                    Section {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("token-sheet-message")
                    }
                }

                Section {
                    Button {
                        submit()
                    } label: {
                        HStack {
                            Text("Sign in")
                            if session.isRedeeming {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isRedeeming)
                    .accessibilityIdentifier("token-submit")
                }
            }
            .accessibilityIdentifier("token-sheet")
            .navigationTitle("Sign in")
#if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("token-sheet-close")
                }
            }
        }
        .sheet(isPresented: $scanning) {
            QRScannerView { code in
                scanning = false
                input = code
                submitIfUnambiguous()
            }
            .ignoresSafeArea()
        }
    }

    /// Paste: sign in at once when the link is for this gateway (or a bare
    /// token, or the CLI's localhost link); otherwise show the warning first.
    private func pasted(_ text: String) {
        input = text
#if canImport(UIKit)
        lastPaste = Paste(text: text, changeCount: UIPasteboard.general.changeCount)
#endif
        submitIfUnambiguous()
    }

    private func submitIfUnambiguous() {
        if session.foreignLinkHost(in: input) == nil { submit() }
    }

    private func submit() {
        let count = lastPaste?.text == input ? lastPaste?.changeCount : nil
        session.redeem(input, pasteboardChangeCount: count)
    }

    private static var hasCamera: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }
}

/// A full-screen QR scanner for the dashboard's Phone access code (D3).
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        QRScannerController(onCode: onCode)
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {}
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let onCode: (String) -> Void
    private let session = AVCaptureSession()
    private var delivered = false

    init(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.layer.bounds
        view.layer.addSublayer(preview)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.first?.frame = view.layer.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        let code = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }.first
        guard let code else { return }
        // Delivered on the main queue (setMetadataObjectsDelegate above).
        MainActor.assumeIsolated {
            guard !delivered else { return }
            delivered = true
            onCode(code)
        }
    }
}
