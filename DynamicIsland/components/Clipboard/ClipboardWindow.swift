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
import Defaults

struct ClipboardWindow: View {
    @ObservedObject var clipboardManager = ClipboardManager.shared
    @State private var selectedTab: ClipboardTab = .all
    @State private var searchText = ""
    @State private var selectedItemID: UUID?

    private var filteredItems: [ClipboardItem] {
        fuzzyMatchedClipboardItems(query: searchText, items: selectedTab.items(from: clipboardManager))
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        switch direction {
        case .left, .right:
            selectedTab = movedClipboardTab(from: selectedTab, direction: direction)
        case .up, .down:
            selectedItemID = movedClipboardSelection(from: selectedItemID, direction: direction, items: filteredItems)
        default:
            break
        }
    }

    private func activateSelection() {
        guard let selectedItemID,
              let item = filteredItems.first(where: { $0.id == selectedItemID })
        else { return }
        activate(item)
    }

    private func activate(_ item: ClipboardItem) {
        selectedItemID = item.id
        clipboardManager.activateItem(item)
        ClipboardWindowManager.shared.hideClipboardWindow()
        ClipboardPasteCoordinator.shared.pasteIntoCapturedApplication()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with tabs and search
            ClipboardWindowHeader(
                selectedTab: $selectedTab,
                searchText: $searchText,
                onMove: moveSelection,
                onActivate: activateSelection,
                onCancel: { ClipboardWindowManager.shared.hideClipboardWindow() }
            )
            
            Divider()
                .background(Color.gray.opacity(0.3))
            
            // Content area
            ClipboardWindowContent(
                selectedTab: $selectedTab,
                searchText: searchText,
                selectedItemID: $selectedItemID,
                onActivate: activate
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
        .onAppear {
            selectedItemID = filteredItems.first?.id
        }
    }
}

struct ClipboardWindowHeader: View {
    @Binding var selectedTab: ClipboardTab
    @Binding var searchText: String
    let onMove: (MoveCommandDirection) -> Void
    let onActivate: () -> Void
    let onCancel: () -> Void
    @ObservedObject var clipboardManager = ClipboardManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // Title and controls
            HStack {
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
                .disabled(selectedTab.items(from: clipboardManager).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
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
            .padding(.bottom, 8)
            
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                
                ClipboardSearchField(
                    text: $searchText,
                    placeholder: "搜索剪切板…",
                    onMove: onMove,
                    onActivate: onActivate,
                    onCancel: onCancel
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
            .background(Color.gray.opacity(0.1))
            .cornerRadius(6)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}

struct ClipboardWindowContent: View {
    @Binding var selectedTab: ClipboardTab
    let searchText: String
    @Binding var selectedItemID: UUID?
    let onActivate: (ClipboardItem) -> Void
    @ObservedObject var clipboardManager = ClipboardManager.shared
    
    var filteredItems: [ClipboardItem] {
        fuzzyMatchedClipboardItems(query: searchText, items: selectedTab.items(from: clipboardManager))
    }
    
    var body: some View {
        Group {
            if filteredItems.isEmpty {
                ClipboardEmptyState(tab: selectedTab, hasSearch: !searchText.isEmpty)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(filteredItems) { item in
                                ClipboardWindowItemRow(
                                    item: item,
                                    tab: selectedTab,
                                    isSelected: selectedItemID == item.id,
                                    onSelect: { selectedItemID = item.id },
                                    onActivate: { onActivate(item) }
                                )
                                .id(item.id)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: selectedItemID) { _, itemID in
                        guard let itemID else { return }
                        proxy.scrollTo(itemID, anchor: .center)
                    }
                }
            }
        }
        .onChange(of: selectedTab) { _, _ in selectedItemID = filteredItems.first?.id }
        .onChange(of: searchText) { _, _ in selectedItemID = filteredItems.first?.id }
    }
}

struct ClipboardEmptyState: View {
    let tab: ClipboardTab
    let hasSearch: Bool
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: hasSearch ? "magnifyingglass" : tab.icon)
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
                Text("暂无\(tab.localizedName)内容")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                
                Text(tab == .favorites ? "将条目加入收藏后会显示在这里" : "复制内容后会显示在这里")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ClipboardWindowItemRow: View {
    let item: ClipboardItem
    let tab: ClipboardTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    @ObservedObject var clipboardManager = ClipboardManager.shared
    @State private var isHovering = false
    
    var isPinned: Bool {
        item.isPinned || clipboardManager.pinnedItems.contains(where: { $0.id == item.id })
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ClipboardItemLeadingPreview(item: item)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(item.preview)
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
            if isHovering {
                HStack(spacing: 6) {
                    // Pin/Unpin button
                    Button(action: {
                        clipboardManager.togglePin(for: item)
                    }) {
                        Image(systemName: isPinned ? "heart.fill" : "heart")
                            .font(.system(size: 11))
                            .foregroundColor(isPinned ? .red : .gray)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // Copy button
                    Button(action: {
                        clipboardManager.copyToClipboard(item)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
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
                .fill(isSelected ? Color.accentColor.opacity(0.22) : (isHovering ? Color.gray.opacity(0.1) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .onTapGesture(count: 2) {
            onActivate()
        }
        .onTapGesture(count: 1) {
            onSelect()
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

#Preview {
    ClipboardWindow()
        .frame(width: 960, height: 650)
        .background(Color.gray.opacity(0.3))
}
