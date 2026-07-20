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
    private var pasteTask: Task<Void, Never>?

    private init() {}

    func captureCurrentApplication() {
        pasteTask?.cancel()
        pasteTask = nil
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

    /// Paste a group into the previously focused application.
    ///
    /// Text-only groups are represented by ClipboardManager as one combined
    /// pasteboard item, so one Command-V is sufficient. Many applications read
    /// only the first object when a pasteboard contains several image or file
    /// objects. For those groups, write and paste each logical item in order,
    /// then restore the complete group representation to the pasteboard.
    func pasteGroupIntoCapturedApplication(_ group: ClipboardGroup) {
        let canPasteInSingleOperation = group.items.allSatisfy {
            [.text, .url, .rtf, .unknown].contains($0.type)
        }
        guard !canPasteInSingleOperation else {
            pasteIntoCapturedApplication()
            return
        }

        guard let application = targetApplication, !application.isTerminated else {
            targetApplication = nil
            return
        }
        targetApplication = nil

        pasteTask?.cancel()
        pasteTask = Task { @MainActor [weak self] in
            application.activate()
            guard await Self.waitForPasteTarget(nanoseconds: 180_000_000) else {
                return
            }

            for item in group.items {
                guard !Task.isCancelled else { return }
                guard ClipboardManager.shared.copyToClipboard(item) else { continue }

                Self.postPasteShortcut()
                guard await Self.waitForPasteTarget(nanoseconds: 280_000_000) else {
                    return
                }
            }

            // Keep the group itself on the clipboard after the sequential paste
            // finishes, matching the behavior of text-only group activation.
            _ = ClipboardManager.shared.copyGroupToClipboard(group)
            self?.pasteTask = nil
        }
    }

    private static func waitForPasteTarget(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
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
