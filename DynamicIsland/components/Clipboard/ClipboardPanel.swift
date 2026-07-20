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

import AppKit
import SwiftUI

private extension Notification.Name {
    static let clipboardPanelActivateSelection = Notification.Name(
        "clipboardPanelActivateSelection"
    )
}

private func applyClipboardCornerMask(_ view: NSView, radius: CGFloat) {
    view.wantsLayer = true
    view.layer?.masksToBounds = true
    view.layer?.cornerRadius = radius
    view.layer?.backgroundColor = NSColor.clear.cgColor
    if #available(macOS 13.0, *) {
        view.layer?.cornerCurve = .continuous
    }
}

class ClipboardPanel: NSPanel {
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        
        setupWindow()
        setupContentView()
        installKeyMonitors()
    }
    
    // Override to allow the panel to become key window (required for TextField focus)
    override var canBecomeKey: Bool {
        return true
    }
    
    // Override to allow the panel to become main window (required for text input)
    override var canBecomeMain: Bool {
        return true
    }

    /// The native field editor can consume Return/Escape before the embedded
    /// NSTextField sees them. Handle them at the panel boundary so these keys
    /// are reliable regardless of which search-field responder is active.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handlePanelKey(event) {
            return
        }
        super.sendEvent(event)
    }

    override func close() {
        removeKeyMonitors()
        super.close()
    }

    private func installKeyMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, self.handlePanelKey(event) else { return event }
            return nil
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard [36, 53, 76].contains(event.keyCode) else { return }
            DispatchQueue.main.async {
                guard let self, self.isVisible else { return }
                _ = self.handlePanelKey(event)
            }
        }
    }

    private func removeKeyMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
    }

    @discardableResult
    private func handlePanelKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76:
            NotificationCenter.default.post(
                name: .clipboardPanelActivateSelection,
                object: self
            )
            return true
        case 53:
            close()
            return true
        default:
            return false
        }
    }
    
    private func setupWindow() {
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true  // Enable dragging
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isFloatingPanel = true  // Mark as floating panel for proper behavior
        
        // Allow dragging from any part of the window
        styleMask.insert(.fullSizeContentView)
        
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary  // Float above full-screen apps
        ]

        ScreenCaptureVisibilityManager.shared.register(self, scope: .panelsOnly)
        
        // Accept mouse moved events for proper hover behavior
        acceptsMouseMovedEvents = true
    }
    
    private func setupContentView() {
        let contentView = ClipboardPanelView {
            self.close()
        }
        
        let hostingView = NSHostingView(rootView: contentView)
        applyClipboardCornerMask(hostingView, radius: 12)
        self.contentView = hostingView
        
        let preferredSize = preferredContentSize()
        hostingView.setFrameSize(preferredSize)
        setContentSize(preferredSize)
    }

    private func screenAtPointer() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
    }

    private func preferredContentSize() -> CGSize {
        guard let screen = screenAtPointer() else {
            return CGSize(width: 960, height: 650)
        }

        let visibleSize = screen.visibleFrame.size
        return CGSize(
            width: min(max(visibleSize.width * 0.70, 760), visibleSize.width * 0.94),
            height: min(max(visibleSize.height * 0.78, 560), visibleSize.height * 0.94)
        )
    }
    
    func positionNearNotch() {
        guard let screen = screenAtPointer() else { return }
        
        let screenFrame = screen.visibleFrame
        let panelFrame = frame
        
        // Check if we have a saved position
        if let savedPosition = getSavedPosition(for: panelFrame.size),
           screenFrame.contains(NSRect(origin: savedPosition, size: panelFrame.size)) {
            setFrameOrigin(savedPosition)
            return
        }
        
        // Default to center of screen (not top center)
        let xPosition = (screenFrame.width - panelFrame.width) / 2 + screenFrame.minX
        let yPosition = (screenFrame.height - panelFrame.height) / 2 + screenFrame.minY
        
        setFrameOrigin(NSPoint(x: xPosition, y: yPosition))
    }
    
    private func getSavedPosition(for panelSize: NSSize) -> NSPoint? {
        let defaults = UserDefaults.standard
        let x = defaults.double(forKey: "clipboardPanelPositionX")
        let y = defaults.double(forKey: "clipboardPanelPositionY")
        let savedWidth = defaults.double(forKey: "clipboardPanelPositionWidth")
        let savedHeight = defaults.double(forKey: "clipboardPanelPositionHeight")
        
        guard x != 0.0 || y != 0.0,
              abs(savedWidth - panelSize.width) < 1,
              abs(savedHeight - panelSize.height) < 1
        else { return nil }
        return NSPoint(x: x, y: y)
    }
    
    private func saveCurrentPosition() {
        let currentOrigin = frame.origin
        let defaults = UserDefaults.standard
        defaults.set(currentOrigin.x, forKey: "clipboardPanelPositionX")
        defaults.set(currentOrigin.y, forKey: "clipboardPanelPositionY")
        defaults.set(frame.width, forKey: "clipboardPanelPositionWidth")
        defaults.set(frame.height, forKey: "clipboardPanelPositionHeight")
    }
    
    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(point)
        // Save position whenever it changes (user dragging)
        saveCurrentPosition()
    }
    
    func positionNearMouse() {
        let mouseLocation = NSEvent.mouseLocation
        let panelFrame = frame
        
        // Position near mouse but ensure it stays on screen
        guard let screen = screenAtPointer() else { return }
        let screenFrame = screen.visibleFrame
        
        var xPosition = mouseLocation.x - panelFrame.width / 2
        var yPosition = mouseLocation.y - panelFrame.height - 20
        
        // Keep within screen bounds
        xPosition = max(screenFrame.minX + 10, min(xPosition, screenFrame.maxX - panelFrame.width - 10))
        yPosition = max(screenFrame.minY + 10, min(yPosition, screenFrame.maxY - panelFrame.height - 10))
        
        setFrameOrigin(NSPoint(x: xPosition, y: yPosition))
    }
    
}

struct ClipboardPanelView: View {
    let onClose: () -> Void
    @ObservedObject var clipboardManager = ClipboardManager.shared
    @State private var selectedTab: ClipboardTab = .all
    @State private var searchText = ""
    @State private var hoveredItemId: UUID?
    @State private var selectedItemID: UUID?
    @State private var selectedItemIDs = Set<UUID>()
    @State private var selectedGroupID: UUID?
    @State private var shouldScrollItemSelectionIntoView = false
    @State private var shouldScrollGroupSelectionIntoView = false
    
    var filteredItems: [ClipboardItem] {
        fuzzyMatchedClipboardItems(query: searchText, items: selectedTab.items(from: clipboardManager))
    }

    var filteredGroups: [ClipboardGroup] {
        fuzzyMatchedClipboardGroups(query: searchText, groups: clipboardManager.groups)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        switch direction {
        case .left, .right:
            selectedTab = movedClipboardTab(from: selectedTab, direction: direction)
        case .up, .down:
            if selectedTab == .groups {
                shouldScrollGroupSelectionIntoView = true
                selectedGroupID = movedClipboardGroupSelection(
                    from: selectedGroupID,
                    direction: direction,
                    groups: filteredGroups
                )
            } else {
                shouldScrollItemSelectionIntoView = true
                selectedItemID = movedClipboardSelection(
                    from: selectedItemID,
                    direction: direction,
                    items: filteredItems
                )
                selectedItemIDs = selectedItemID.map { [$0] } ?? []
            }
        default:
            break
        }
    }

    private func activateSelection() {
        if selectedTab == .groups {
            guard let selectedGroupID,
                  let group = filteredGroups.first(where: { $0.id == selectedGroupID })
            else { return }
            activate(group)
            return
        }

        let selectedItems = filteredItems.filter { selectedItemIDs.contains($0.id) }
        if selectedItems.count > 1 {
            guard let group = clipboardManager.createGroup(from: selectedItems) else { return }
            activate(group)
            return
        }

        let item = selectedItems.first
            ?? selectedItemID.flatMap { id in filteredItems.first(where: { $0.id == id }) }
        guard let item else { return }
        activate(item)
    }

    private func activate(_ item: ClipboardItem) {
        selectedItemID = item.id
        clipboardManager.activateItem(item)
        onClose()
        ClipboardPasteCoordinator.shared.pasteIntoCapturedApplication()
    }

    private func activate(_ group: ClipboardGroup) {
        selectedGroupID = group.id
        guard clipboardManager.activateGroup(group) else { return }
        onClose()
        ClipboardPasteCoordinator.shared.pasteGroupIntoCapturedApplication(group)
    }

    private func select(_ item: ClipboardItem, extendingSelection: Bool) {
        // Mouse selection must never drive ScrollViewReader. Re-centering every
        // clicked row made cross-screen Command selection jump back and feel as
        // if multi-selection had exited.
        shouldScrollItemSelectionIntoView = false
        if extendingSelection {
            if selectedItemIDs.contains(item.id) {
                selectedItemIDs.remove(item.id)
                selectedItemID = filteredItems.first(where: {
                    selectedItemIDs.contains($0.id)
                })?.id
            } else {
                selectedItemIDs.insert(item.id)
                selectedItemID = item.id
            }
        } else {
            selectedItemID = item.id
            selectedItemIDs = [item.id]
        }
    }

    private func select(_ group: ClipboardGroup) {
        shouldScrollGroupSelectionIntoView = false
        selectedGroupID = group.id
    }

    private func resetSelection() {
        shouldScrollItemSelectionIntoView = false
        shouldScrollGroupSelectionIntoView = false
        selectedItemIDs.removeAll()
        selectedItemID = nil
        selectedGroupID = nil

        if selectedTab == .groups {
            selectedGroupID = filteredGroups.first?.id
        } else if let firstID = filteredItems.first?.id {
            selectedItemID = firstID
            selectedItemIDs = [firstID]
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with tabs
            ClipboardPanelHeader(
                selectedTab: $selectedTab,
                searchText: $searchText, 
                onMove: moveSelection,
                onActivate: activateSelection,
                onClose: onClose
            )
            
            Divider()
                .background(Color.gray.opacity(0.3))

            if selectedTab != .groups, selectedItemIDs.count > 1 {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                    Text("已选择 \(selectedItemIDs.count) 项")
                        .font(.system(size: 11, weight: .semibold))
                    Text("按 Enter 保存为分组并直接粘贴")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("⌘ 点击可增减选择")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.08))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            
            // Content
            if selectedTab == .groups {
                if filteredGroups.isEmpty {
                    ClipboardPanelEmptyState(
                        hasSearch: !searchText.isEmpty,
                        selectedTab: selectedTab
                    )
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 1) {
                                ForEach(filteredGroups) { group in
                                    ClipboardPanelGroupRow(
                                        group: group,
                                        isHovered: hoveredItemId == group.id,
                                        isSelected: selectedGroupID == group.id,
                                        onHover: { hoveredItemId = $0 },
                                        onSelect: { select(group) },
                                        onActivate: { activate(group) }
                                    )
                                    .id(group.id)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .onChange(of: selectedGroupID) { _, groupID in
                            guard shouldScrollGroupSelectionIntoView, let groupID else { return }
                            shouldScrollGroupSelectionIntoView = false
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(groupID, anchor: .center)
                            }
                        }
                    }
                }
            } else if filteredItems.isEmpty {
                ClipboardPanelEmptyState(
                    hasSearch: !searchText.isEmpty,
                    selectedTab: selectedTab
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(filteredItems) { item in
                                ClipboardPanelItemRow(
                                    item: item,
                                    isHovered: hoveredItemId == item.id,
                                    isSelected: selectedItemIDs.contains(item.id),
                                    isPinned: clipboardManager.pinnedItems.contains(where: { $0.id == item.id }),
                                    onHover: { hoveredItemId = $0 },
                                    onSelect: { extendingSelection in
                                        select(item, extendingSelection: extendingSelection)
                                    },
                                    onActivate: { activate(item) }
                                )
                                .id(item.id)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: selectedItemID) { _, itemID in
                        guard shouldScrollItemSelectionIntoView, let itemID else { return }
                        shouldScrollItemSelectionIntoView = false
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(itemID, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
        .onAppear {
            resetSelection()
        }
        .onChange(of: selectedTab) { _, _ in
            resetSelection()
        }
        .onChange(of: searchText) { _, _ in
            resetSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardPanelActivateSelection)) { _ in
            activateSelection()
        }
    }
}

struct ClipboardPanelHeader: View {
    @Binding var selectedTab: ClipboardTab
    @Binding var searchText: String
    let onMove: (MoveCommandDirection) -> Void
    let onActivate: () -> Void
    let onClose: () -> Void
    @ObservedObject var clipboardManager = ClipboardManager.shared
    
    var body: some View {
        VStack(spacing: 8) {
            // Title and close button
            HStack {
                // Close button
                NativeStyleCloseButton(action: onClose)
                
                Image(systemName: "doc.on.clipboard")
                    .foregroundColor(.primary)
                    .font(.system(size: 16, weight: .medium))
                
                Text("Clipboard Manager")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                
                Spacer()
                
                // Clear button
                Button(action: {
                    clipboardManager.clearItems(in: selectedTab)
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                        .font(.system(size: 12))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(selectedTab.isEmpty(in: clipboardManager))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            
            // Tab selector
            HStack(spacing: 0) {
                ForEach(ClipboardTab.allCases, id: \.self) { tab in
                    ClipboardTabButton(tab: tab, isSelected: selectedTab == tab) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTab = tab
                        }
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 16)
            
            // Search bar (always visible)
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                
                ClipboardSearchField(
                    text: $searchText,
                    placeholder: "搜索剪切板…",
                    onMove: onMove,
                    onActivate: onActivate,
                    onCancel: onClose
                )
                .frame(height: 18)
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 10))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.1))
            )
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }
}

struct ClipboardPanelEmptyState: View {
    let hasSearch: Bool
    let selectedTab: ClipboardTab
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: hasSearch ? "magnifyingglass" : selectedTab.icon)
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            
            if hasSearch {
                Text("没有找到结果")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                
                Text("请尝试其他搜索关键词")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                Text("暂无\(selectedTab.localizedName)内容")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                
                Text(emptyDescription)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDescription: String {
        switch selectedTab {
        case .favorites:
            return "将条目加入收藏后会显示在这里"
        case .groups:
            return "按住 ⌘ 选择多个条目，再按 Enter 保存为分组"
        default:
            return "复制内容后会显示在这里"
        }
    }
}

struct ClipboardPanelItemRow: View {
    let item: ClipboardItem
    let isHovered: Bool
    let isSelected: Bool
    let isPinned: Bool
    let onHover: (UUID?) -> Void
    let onSelect: (Bool) -> Void
    let onActivate: () -> Void
    @ObservedObject var clipboardManager = ClipboardManager.shared
    @State private var justCopied = false
    @State private var lastTapDate = Date.distantPast
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ClipboardItemLeadingPreview(item: item)
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayPreview)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                HStack {
                    Text(item.type.displayName)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(timeAgoString(from: item.timestamp))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Action buttons (shown on hover)
            if isHovered {
                HStack(spacing: 6) {
                    // Pin/Unpin button
                    Button(action: {
                        if isPinned {
                            clipboardManager.unpinItem(item)
                        } else {
                            clipboardManager.pinItem(item)
                        }
                    }) {
                        Image(systemName: isPinned ? "heart.fill" : "heart")
                            .font(.system(size: 11))
                            .foregroundColor(isPinned ? .red : .gray)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // Copy button
                    Button(action: {
                        clipboardManager.copyToClipboard(item)
                        
                        withAnimation(.easeInOut(duration: 0.2)) {
                            justCopied = true
                        }
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                justCopied = false
                            }
                        }
                    }) {
                        Image(systemName: justCopied ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(justCopied ? .green : .green)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // Delete button
                    Button(action: {
                        if isPinned {
                            clipboardManager.unpinItem(item)
                        } else {
                            clipboardManager.deleteItem(item)
                        }
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : (isHovered ? Color.gray.opacity(0.1) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                onHover(hovering ? item.id : nil)
            }
        }
        // A competing double-click recognizer delays the single-click callback
        // until the system double-click interval expires. It also reads the
        // modifier flags too late, after Command may already have been released.
        .onTapGesture {
            handleTap()
        }
    }

    private func handleTap() {
        let isExtendingSelection = NSEvent.modifierFlags.contains(.command)
        let tapDate = Date()

        if isExtendingSelection {
            lastTapDate = .distantPast
            onSelect(true)
        } else if tapDate.timeIntervalSince(lastTapDate) <= NSEvent.doubleClickInterval {
            lastTapDate = .distantPast
            onActivate()
        } else {
            lastTapDate = tapDate
            onSelect(false)
        }
    }
    
    private func timeAgoString(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        
        if interval < 60 {
            return "刚刚"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes) 分钟前"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours) 小时前"
        } else {
            let days = Int(interval / 86400)
            return "\(days) 天前"
        }
    }
}

struct ClipboardPanelGroupRow: View {
    let group: ClipboardGroup
    let isHovered: Bool
    let isSelected: Bool
    let onHover: (UUID?) -> Void
    let onSelect: () -> Void
    let onActivate: () -> Void
    @ObservedObject var clipboardManager = ClipboardManager.shared
    @State private var justCopied = false
    @State private var lastTapDate = Date.distantPast

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ClipboardGroupLeadingPreview(group: group)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(group.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)

                    Text("\(group.items.count) 项")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.accentColor.opacity(0.12))
                        )
                }

                Text(group.preview)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                HStack {
                    Label("整组粘贴", systemImage: "square.stack.3d.up")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)

                    Spacer()

                    Text(timeAgoString(from: group.timestamp))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if isHovered {
                HStack(spacing: 8) {
                    Button {
                        clipboardManager.copyGroupToClipboard(group)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            justCopied = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                justCopied = false
                            }
                        }
                    } label: {
                        Image(systemName: justCopied ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("复制整个分组")

                    Button {
                        clipboardManager.deleteGroup(group)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("删除分组")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.22)
                        : (isHovered ? Color.gray.opacity(0.1) : Color.clear)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                onHover(hovering ? group.id : nil)
            }
        }
        .onTapGesture {
            let tapDate = Date()
            if tapDate.timeIntervalSince(lastTapDate) <= NSEvent.doubleClickInterval {
                lastTapDate = .distantPast
                onActivate()
            } else {
                lastTapDate = tapDate
                onSelect()
            }
        }
    }

    private func timeAgoString(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return "刚刚"
        } else if interval < 3600 {
            return "\(Int(interval / 60)) 分钟前"
        } else if interval < 86400 {
            return "\(Int(interval / 3600)) 小时前"
        } else {
            return "\(Int(interval / 86400)) 天前"
        }
    }
}

#Preview {
    ClipboardPanelView {
        print("Close panel")
    }
}
