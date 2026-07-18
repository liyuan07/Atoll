/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import SwiftUI
import AppKit

@MainActor
class ClipboardWindowManager: ObservableObject {
    static let shared = ClipboardWindowManager()
    
    private var clipboardWindow: NSWindow?
    private var windowDelegate: WindowDelegate?
    
    private init() {}
    
    func showClipboardWindow() {
        ClipboardPasteCoordinator.shared.captureCurrentApplication()
        if let existingWindow = clipboardWindow {
            // Ensure window appears above fullscreen apps
            existingWindow.level = .screenSaver
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()  // Force window to front even above fullscreen
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let currentScreen = screenForClipboardWindow()
        let targetFrame = preferredWindowFrame(on: currentScreen)
        
        // Create the window
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: targetFrame.size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Clipboard Manager"
        window.isMovableByWindowBackground = true
        window.level = .screenSaver  // Use screenSaver level to appear above fullscreen apps
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]  // Allow on all spaces and above fullscreen
        
        // Set minimum and maximum sizes
        window.minSize = NSSize(width: 640, height: 480)
        window.maxSize = currentScreen.visibleFrame.size
        
        // Center the window on the current screen (important for fullscreen apps)
        window.setFrame(targetFrame, display: false)
        
        // Set the content view
        let contentView = ClipboardWindow()
        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView
        
        // Handle window closing
        let windowDelegate = WindowDelegate { [weak self] window in
            ScreenCaptureVisibilityManager.shared.unregister(window)
            self?.clipboardWindow = nil
            self?.windowDelegate = nil
        }
        self.windowDelegate = windowDelegate
        window.delegate = windowDelegate

        ScreenCaptureVisibilityManager.shared.register(window, scope: .panelsOnly)
        
        self.clipboardWindow = window
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()  // Force window to front even above fullscreen apps
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func hideClipboardWindow() {
        clipboardWindow?.close()
    }
    
    func toggleClipboardWindow() {
        if let window = clipboardWindow, window.isVisible {
            hideClipboardWindow()
        } else {
            showClipboardWindow()
        }
    }
    
    var isWindowVisible: Bool {
        return clipboardWindow?.isVisible ?? false
    }

    private func screenForClipboardWindow() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func preferredWindowFrame(on screen: NSScreen) -> NSRect {
        let availableFrame = screen.visibleFrame
        let maximumWidth = availableFrame.width * 0.94
        let maximumHeight = availableFrame.height * 0.94
        let width = min(max(availableFrame.width * 0.70, 760), maximumWidth)
        let height = min(max(availableFrame.height * 0.78, 560), maximumHeight)
        let origin = NSPoint(
            x: availableFrame.midX - width / 2,
            y: availableFrame.midY - height / 2
        )
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }
}

private class WindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: (NSWindow) -> Void

    init(onClose: @escaping (NSWindow) -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide instead of close when user clicks close button
        sender.orderOut(nil)
        onClose(sender)
        return false
    }
}
