/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import ApplicationServices
import CoreGraphics

/// Controls Soda Music's own favorite actions. Soda Music ignores the
/// MediaRemote Like command, but exposes an in-app Like shortcut and a native
/// player-bar favorite button. Combining those two gives us deterministic
/// set-on and set-off operations without Screen Recording permission.
actor SodaMusicFavoriteController {
    static let shared = SodaMusicFavoriteController()

    static let bundleIdentifier = "com.soda.music"

    private let favoriteButtonX: CGFloat = 102
    private let favoriteButtonBottomInset: CGFloat = 30
    private let likeShortcutKeyCode: CGKeyCode = 37 // L

    func setFavorite(_ targetState: Bool) async -> Bool? {
        let previousApplication = await MainActor.run {
            NSWorkspace.shared.frontmostApplication
        }

        guard let processIdentifier = await prepareSodaMusicWindow() else {
            return nil
        }

        // Cmd+L is Soda Music's configured in-app "收藏歌曲" action. The
        // action is idempotent: it explicitly sets the current track to liked.
        postLikeShortcut()

        if !targetState {
            // First force the state to on, then use Soda Music's own button to
            // toggle it off. This remains correct even if Atoll's cached icon
            // was stale when the user clicked it.
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let frame = sodaMusicWindowFrame(processIdentifier: processIdentifier) else {
                await restore(previousApplication)
                return nil
            }
            let point = CGPoint(
                x: frame.minX + favoriteButtonX,
                y: frame.minY + frame.height - favoriteButtonBottomInset
            )
            postClick(at: point)
        }

        try? await Task.sleep(nanoseconds: 900_000_000)
        await restore(previousApplication)
        return targetState
    }

    @MainActor
    private func prepareSodaMusicWindow() async -> pid_t? {
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        ).first else {
            return nil
        }

        application.unhide()
        application.activate(options: [])

        let accessibilityApplication = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            accessibilityApplication,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success,
           let windows = value as? [AXUIElement]
        {
            for window in windows {
                AXUIElementSetAttributeValue(
                    window,
                    kAXMinimizedAttribute as CFString,
                    kCFBooleanFalse
                )
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
        }

        try? await Task.sleep(nanoseconds: 400_000_000)
        return application.processIdentifier
    }

    private func restore(_ application: NSRunningApplication?) async {
        guard application?.bundleIdentifier != Self.bundleIdentifier else { return }
        _ = await MainActor.run {
            application?.activate(options: [])
        }
    }

    private func sodaMusicWindowFrame(processIdentifier: pid_t) -> CGRect? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        return windowInfo
            .filter { row in
                (row[kCGWindowOwnerPID as String] as? Int) == Int(processIdentifier)
                    && (row[kCGWindowLayer as String] as? Int) == 0
            }
            .compactMap { row in
                guard let rawBounds = row[kCGWindowBounds as String],
                      let frame = CGRect(
                        dictionaryRepresentation: rawBounds as! CFDictionary
                      ),
                      frame.width >= 700,
                      frame.height >= 400
                else {
                    return nil
                }
                return frame
            }
            .max(by: { lhs, rhs in lhs.width * lhs.height < rhs.width * rhs.height })
    }

    private func postLikeShortcut() {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: likeShortcutKeyCode,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: likeShortcutKeyCode,
                keyDown: false
              )
        else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func postClick(at point: CGPoint) {
        CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }
}
