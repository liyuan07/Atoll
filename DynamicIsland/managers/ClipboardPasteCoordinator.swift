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
import CoreGraphics

@MainActor
final class ClipboardPasteCoordinator {
    static let shared = ClipboardPasteCoordinator()

    private var targetApplication: NSRunningApplication?

    private init() {}

    func captureCurrentApplication() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }
        targetApplication = application
    }

    func pasteIntoCapturedApplication() {
        guard let application = targetApplication, !application.isTerminated else {
            targetApplication = nil
            return
        }
        targetApplication = nil

        application.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            Self.postPasteShortcut()
        }
    }

    private static func postPasteShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
