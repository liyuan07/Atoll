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
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var pasteTask: Task<Void, Never>?
    private var pasteGeneration: UInt64 = 0

    private init() {
        rememberExternalApplication(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication
            Task { @MainActor [weak self] in
                self?.rememberExternalApplication(application)
            }
        }
    }

    func captureCurrentApplication() {
        cancelPendingPaste()
        if let application = externalApplication(
            from: NSWorkspace.shared.frontmostApplication
        ) {
            targetApplication = application
            lastExternalApplication = application
        } else if targetApplication?.isTerminated != false {
            targetApplication = validLastExternalApplication
        }
    }

    func pasteIntoCapturedApplication() {
        cancelPendingPaste()
        let generation = pasteGeneration
        guard let application = resolvedTargetApplication else {
            targetApplication = nil
            return
        }
        targetApplication = nil

        pasteTask = Task { @MainActor [weak self] in
            application.activate(options: [.activateAllWindows])
            let isFrontmost = await Self.waitForApplicationToActivate(application)
            guard !Task.isCancelled,
                  self?.pasteGeneration == generation,
                  !application.isTerminated else {
                return
            }

            Self.postPasteShortcut(
                to: application.processIdentifier,
                globally: isFrontmost
            )
            if self?.pasteGeneration == generation {
                self?.pasteTask = nil
            }
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
        guard let application = resolvedTargetApplication else {
            targetApplication = nil
            return
        }
        targetApplication = nil

        let generation = pasteGeneration
        pasteTask = Task { @MainActor [weak self] in
            application.activate(options: [.activateAllWindows])
            let isFrontmost = await Self.waitForApplicationToActivate(application)
            guard self?.pasteGeneration == generation,
                  !application.isTerminated else {
                return
            }

            for item in group.items {
                guard !Task.isCancelled,
                      self?.pasteGeneration == generation else { return }
                guard ClipboardManager.shared.copyToClipboard(item) else { continue }

                Self.postPasteShortcut(
                    to: application.processIdentifier,
                    globally: isFrontmost
                )
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

    private var resolvedTargetApplication: NSRunningApplication? {
        if let targetApplication, !targetApplication.isTerminated {
            return targetApplication
        }
        return validLastExternalApplication
    }

    private var validLastExternalApplication: NSRunningApplication? {
        guard let lastExternalApplication,
              !lastExternalApplication.isTerminated else {
            return nil
        }
        return lastExternalApplication
    }

    private func rememberExternalApplication(_ application: NSRunningApplication?) {
        guard let application = externalApplication(from: application) else { return }
        lastExternalApplication = application
    }

    private func externalApplication(
        from application: NSRunningApplication?
    ) -> NSRunningApplication? {
        guard let application,
              !application.isTerminated,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }
        return application
    }

    private static func waitForApplicationToActivate(
        _ application: NSRunningApplication
    ) async -> Bool {
        for _ in 0..<40 {
            guard !Task.isCancelled, !application.isTerminated else { return false }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == application.processIdentifier {
                return true
            }
            guard await waitForPasteTarget(nanoseconds: 25_000_000) else {
                return false
            }
        }
        return false
    }

    private static func waitForPasteTarget(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private static func postPasteShortcut(
        to processIdentifier: pid_t,
        globally: Bool
    ) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        if globally {
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        } else {
            keyDown.postToPid(processIdentifier)
            keyUp.postToPid(processIdentifier)
        }
    }
}
