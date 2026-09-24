// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//
//  ProxyBounceTestHarness.swift
//  Latchkey
//
//  Hermetic in-app integration harness used by XCUITest. It runs a real
//  WKWebView against an app-provided WKURLSchemeHandler, then simulates tsnet
//  Running -> Starting -> Running publishes. The page owns JS state and an
//  in-flight fetch. Accessibility labels make an unexpected document reload or
//  a lost fetch observable without a real tailnet/auth key.
//

// Hermetic in-app harness (-UITestProxyBounceHarness). Test builds only (R15).
#if LATCHKEY_TEST_HOOKS

import SwiftUI
import Combine
import WebKit
import TailscaleKit

private nonisolated final class BounceSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let queue = DispatchQueue(label: "net.lixom.latchkey.bounce-test")
    private var delayedTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        logger.log("bounce harness: scheme request \(url.redactedForLog)")
        let id = ObjectIdentifier(urlSchemeTask as AnyObject)
        if url.path == "/slow" {
            let task = Task { [weak self, weak urlSchemeTask] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let urlSchemeTask else { return }
                let data = Data("fetch-completed".utf8)
                let response = HTTPURLResponse(url: url, statusCode: 200,
                                               httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Type": "text/plain"])!
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
                guard let handler = self else { return }
                handler.queue.async { [weak handler] in
                    handler?.delayedTasks.removeValue(forKey: id)
                }
            }
            queue.async { [weak self] in self?.delayedTasks[id] = task }
            return
        }

        if url.path == "/popped" {
            // The destination of the harness's same-origin popup (R3 review).
            let page = """
            <!doctype html><meta name='viewport' content='width=device-width'>
            <title>Popped</title>
            <body><h1 id='popped'>POPPED PAGE</h1>
            <script>webkit.messageHandlers.bounce.postMessage({popup: 'popped-page'});</script>
            </body>
            """
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/html; charset=utf-8"])!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(Data(page.utf8))
            urlSchemeTask.didFinish()
            return
        }

        let html = """
        <!doctype html><meta name='viewport' content='width=device-width'>
        <title>Proxy bounce test</title>
        <body>
          <p id='loads'>loads: 0</p>
          <p id='fetch'>fetch: pending</p>
          <!-- R3 review: the two window.open shapes KiroCrew uses. -->
          <button id='popup-later' style='font-size:20px'
            onclick="var w = window.open('', '_blank');
                     webkit.messageHandlers.bounce.postMessage({popup: w ? 'window' : 'null'});
                     if (w) { w.opener = null; setTimeout(function () { w.location = 'bounce-test://page/popped'; }, 300); }"
            >Open popup later</button>
          <button id='popup-blank' style='font-size:20px'
            onclick="var w = window.open();
                     webkit.messageHandlers.bounce.postMessage({popup: w ? 'blank-window' : 'null'});"
            >Open blank popup</button>
          <script>
            let loads = Number(sessionStorage.getItem('bounce-loads') || '0') + 1;
            sessionStorage.setItem('bounce-loads', String(loads));
            document.getElementById('loads').textContent = 'loads: ' + loads;
            webkit.messageHandlers.bounce.postMessage({loads: loads, fetch: 'pending'});
            fetch('bounce-test://page/slow').then(r => r.text()).then(text => {
              document.getElementById('fetch').textContent = 'fetch: ' + text;
              webkit.messageHandlers.bounce.postMessage({loads: loads, fetch: text});
            }).catch(e => {
              document.getElementById('fetch').textContent = 'fetch: ERROR ' + e;
              webkit.messageHandlers.bounce.postMessage({loads: loads, fetch: 'ERROR'});
            });
          </script>
        </body>
        """
        let data = Data(html.utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask as AnyObject)
        queue.async { [weak self] in
            self?.delayedTasks.removeValue(forKey: id)?.cancel()
        }
    }
}

@MainActor
private final class BounceMessageBridge: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published var loadCount = 0
    @Published var fetchStatus = "not-started"
    /// What the page's last window.open returned, or "popped-page" once the
    /// popup's destination has loaded (R3 review).
    @Published var popupStatus = "none"

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        logger.log("bounce harness: script message \(body)")
        if let loads = body["loads"] as? Int { loadCount = loads }
        if let fetch = body["fetch"] as? String { fetchStatus = fetch }
        if let popup = body["popup"] as? String { popupStatus = popup }
    }
}

@MainActor
private final class ProxyBounceHarnessModel: ObservableObject {
    let browser: BrowserViewModel
    let bridge = BounceMessageBridge()
    @Published var connectionLabel = "Connected"
    private let tsnet = TSNetModel()
    private let schemeHandler = BounceSchemeHandler()

    init() {
        tsnet.state = .Running
        browser = BrowserViewModel(
            model: tsnet,
            initialURL: URL(string: "bounce-test://page/")!,
            dataStore: .nonPersistent(),
            configureWebView: { [schemeHandler, bridge] configuration in
                configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "bounce-test")
                configuration.userContentController.add(bridge, name: "bounce")
            })
    }

    /// R7: kill the content process and let the browser recover by itself.
    func killWebContent() {
        browser.simulateContentProcessTermination()
    }

    func bounce() {
        connectionLabel = "Reconnecting"
        tsnet.state = .Starting
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.tsnet.state = .Running
            self?.connectionLabel = "Connected"
        }
    }
}

private struct BounceBridgeStatus: View {
    @ObservedObject var bridge: BounceMessageBridge

    var body: some View {
        Group {
            Text(bridge.loadCount == 1 ? "ONE LOAD" : "LOADS \(bridge.loadCount)")
                .accessibilityIdentifier("bounce-load-count")
            Text(bridge.fetchStatus == "fetch-completed" ? "FETCH COMPLETE" : "FETCH PENDING")
                .accessibilityIdentifier("bounce-fetch-status")
            Text("POPUP \(bridge.popupStatus)")
                .accessibilityIdentifier("bounce-popup-status")
        }
    }
}

struct ProxyBounceTestHarnessView: View {
    @StateObject private var model = ProxyBounceHarnessModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.connectionLabel)
                    .accessibilityIdentifier("bounce-connection-status")
                BounceBridgeStatus(bridge: model.bridge)
                Spacer()
                Button("Simulate connection bounce") { model.bounce() }
                    .accessibilityIdentifier("simulate-connection-bounce")
                Button("Kill web content") { model.killWebContent() }
                    .accessibilityIdentifier("simulate-web-content-termination")
            }
            .padding()
            // The production control, so the test exercises the real thing.
            ReturnToDashboardAffordance(model: model.browser)
            Divider()
            BrowserView(model: model.browser)
        }
    }
}

#endif // LATCHKEY_TEST_HOOKS
