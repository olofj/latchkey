// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  AppBar.swift
//  Latchkey
//
//  The one strip of the screen Latchkey owns while the dashboard is up (F15).
//
//  Latchkey may not assume it owns any part of the screen the page is using:
//  the dashboard draws its own controls in its corners, and the gear used to
//  sit on top of its notification bell. So the app's controls live in a bar
//  ABOVE the page, and the page starts where the bar ends. It is not an
//  overlay: an overlaying bar relies on the page insetting itself, and F9
//  measured this gateway ignoring the inset outside an installed web app.
//
//  The bar is absent in the steady state. A deliberate scroll up brings it
//  in and one down takes it away, Safari's model; a page that cannot scroll
//  always has it. `AppBarRetraction` is the policy and `AppBarController`
//  the reasons it must be on screen. Every change resizes the web view,
//  which is why the policy is strict and why Reduce Motion gets no
//  animation at all.
//

import SwiftUI

/// The bar above the page, then everything below it. The whole column's
/// layout animates together when the bar moves, so the page's top edge
/// follows the bar's bottom edge rather than jumping ahead of it.
struct AppBarColumn<Content: View>: View {
    @ObservedObject var model: BrowserViewModel
    @ObservedObject var controller: AppBarController
    let showsSignIn: Bool
    let onSignIn: () -> Void
    let onSettings: () -> Void
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            AppBar(model: model, retracted: controller.retracted, showsSignIn: showsSignIn,
                   onSignIn: onSignIn, onSettings: onSettings)
            content
        }
        // The page's own canvas colour behind the bar and the status-bar strip
        // above it (F9 §0.1), so bar, strip and page read as one surface. A
        // view background does not reach into the safe area by itself.
        .background { PageTint(model: model).ignoresSafeArea() }
        .animation(AppBar.animation(reduceMotion: reduceMotion), value: controller.retracted)
        // The sign-in button must not be scrolled away: it is the only one.
        .onChange(of: showsSignIn, initial: true) { _, pinned in
            controller.setPinned(pinned)
        }
    }
}

struct AppBar: View {
    @ObservedObject var model: BrowserViewModel
    let retracted: Bool
    let showsSignIn: Bool
    let onSignIn: () -> Void
    let onSettings: () -> Void

    /// Reduce Motion: the bar and the page move in one step, not a slide.
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.2)
    }

    var body: some View {
        // Retracted, the controls are REMOVED, not merely clipped away. A
        // zero-height clipped bar still lays its controls out, above itself,
        // under the status bar: invisible, and still hittable by accessibility
        // (L1 caught exactly that gear on the first run). An element that is
        // there and cannot be seen is the failure F15 §4b forbids. VoiceOver
        // and Switch Control never see this state at all (`AppBarController`).
        ZStack(alignment: .bottom) {
            if !retracted {
                HStack(spacing: 8) {
                    ReturnToDashboardAffordance(model: model)
                    Spacer(minLength: 0)
                    if showsSignIn { signIn }
                    Spacer(minLength: 0)
                    settings
                }
                .padding(.horizontal, 6)
                .frame(height: CGFloat(AppBarRetraction.barHeight))
            }
        }
        .frame(maxWidth: .infinity)
        // Zero height when retracted: the column closes over it and the web
        // view starts at the safe-area top.
        .frame(height: retracted ? 0 : CGFloat(AppBarRetraction.barHeight), alignment: .bottom)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app-bar")
    }

    /// Settings, and through it the log viewer and the routing diagnostic:
    /// the reason the dashboard needs any chrome at all (PLAN §1.9).
    ///
    /// Full opacity. Over the page it used to be faded, and over a web view a
    /// button below full opacity gets no taps at all (M1–R29); in the bar it
    /// is not over anything. The material disc keeps it legible on whatever
    /// colour the page's canvas is.
    private var settings: some View {
        Button(action: onSettings) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(7)
                .background(.thinMaterial, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-button")
        .accessibilityLabel("Settings")
    }

    /// The way back to the sign-in sheet after closing it: the page's own
    /// banner is hidden (R22), so this is the only sign-in control.
    private var signIn: some View {
        Button(action: onSignIn) {
            Label("Signed out — Sign in", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("session-signin-button")
    }
}

/// The page's canvas colour, or the system background until it reports one
/// and on the app's own state pages (F9 §0.1).
private struct PageTint: View {
    @ObservedObject var model: BrowserViewModel

    var body: some View {
        guard model.pageState == .committed,
              let rgb = PageScriptSources.opaqueRGB(fromCSS: model.pageBackgroundCSS)
        else { return Color.platformSystemBackground }
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
