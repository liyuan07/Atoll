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
    private var pasteGeneration: UInt64 = 0

    private init() {}

    func captureCurrentApplication() {
        cancelPendingPaste()
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }
        targetApplication = application
    }

    func pasteIntoCapturedApplication() {
        cancelPendingPaste()
        let generation = pasteGeneration
        guard let application = targetApplication, !application.isTerminated else {
            targetApplication = nil
            return
        }
        targetApplication = nil

        application.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard self?.pasteGeneration == generation else { return }
            Self.postPasteShortcut()
        }
    }

    /// Paste a group into the previously focused application.
    ///
    /// Same-type groups use one immutable pasteboard snapshot and one paste
    /// command. Mixed groups are replayed sequentially with generation checks,
    /// so a newer choice cannot be overwritten by an older delayed paste task.
    func pasteGroupIntoCapturedApplication(_ group: ClipboardGroup) {
        let isTextOnly = group.items.allSatisfy {
            [.text, .url, .rtf, .unknown].contains($0.type)
        }
        let isImageOnly = group.items.allSatisfy { $0.type == .image }
        let isFileOnly = group.items.allSatisfy { $0.type == .file }
        let canPasteInSingleOperation = isTextOnly || isImageOnly || isFileOnly
        guard !canPasteInSingleOperation else {
            pasteIntoCapturedApplication()
            return
        }

        cancelPendingPaste()
        guard let application = targetApplication, !application.isTerminated else {
            targetApplication = nil
            return
        }
        targetApplication = nil

        let generation = pasteGeneration
        pasteTask = Task { @MainActor [weak self] in
            application.activate()
            guard await Self.waitForPasteTarget(nanoseconds: 180_000_000),
                  self?.pasteGeneration == generation else {
                return
            }

            for item in group.items {
                guard !Task.isCancelled,
                      self?.pasteGeneration == generation else { return }
                guard ClipboardManager.shared.copyToClipboard(item) else { continue }

                Self.postPasteShortcut()
                guard await Self.waitForPasteTarget(nanoseconds: 500_000_000),
                      self?.pasteGeneration == generation else {
                    return
                }
            }

            // Keep the group itself on the clipboard after the sequential paste
            // finishes, matching the behavior of text-only group activation.
            _ = ClipboardManager.shared.copyGroupToClipboard(group)
            if self?.pasteGeneration == generation {
                self?.pasteTask = nil
            }
        }
    }

    private func cancelPendingPaste() {
        pasteGeneration &+= 1
        pasteTask?.cancel()
        pasteTask = nil
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
