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
import ImageIO

struct ClipboardItemLeadingPreview: View {
    let item: ClipboardItem

    var body: some View {
        Group {
            if item.type == .image {
                if let thumbnail = ClipboardImageThumbnailCache.shared.thumbnail(for: item) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: 72, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        }
                } else {
                    imageFallback
                }
            } else {
                Image(systemName: item.type.icon)
                    .font(.system(size: 14))
                    .foregroundColor(.blue)
                    .frame(width: 72, height: 52, alignment: .center)
            }
        }
    }

    private var imageFallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.secondary.opacity(0.1))
            Image(systemName: item.type.icon)
                .font(.system(size: 18))
                .foregroundColor(.blue)
        }
        .frame(width: 72, height: 52)
    }
}

private final class ClipboardImageThumbnailCache {
    static let shared = ClipboardImageThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 160
        cache.totalCostLimit = 48 * 1_024 * 1_024
    }

    func thumbnail(for item: ClipboardItem) -> NSImage? {
        guard let fileName = item.imageFileName else { return nil }
        let cacheKey = fileName as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let fileURL = ClipboardManager.clipboardDataDirectory.appendingPathComponent(fileName)
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 240
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let thumbnail = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        cache.setObject(
            thumbnail,
            forKey: cacheKey,
            cost: cgImage.bytesPerRow * cgImage.height
        )
        return thumbnail
    }
}

func fuzzyMatchedClipboardItems(
    query: String,
    items: [ClipboardItem]
) -> [ClipboardItem] {
    let normalizedQuery = normalizedClipboardSearchText(query)
    guard !normalizedQuery.isEmpty else { return items }

    return items.compactMap { item -> (ClipboardItem, Int)? in
        let searchableText = normalizedClipboardSearchText("\(item.preview) \(item.type.displayName)")
        guard let score = clipboardFuzzyScore(query: normalizedQuery, candidate: searchableText) else {
            return nil
        }
        return (item, score)
    }
    .sorted { lhs, rhs in
        lhs.1 == rhs.1 ? lhs.0.timestamp > rhs.0.timestamp : lhs.1 > rhs.1
    }
    .map(\.0)
}

private func normalizedClipboardSearchText(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func clipboardFuzzyScore(query: String, candidate: String) -> Int? {
    if candidate.hasPrefix(query) {
        return 20_000 - candidate.count
    }
    if let range = candidate.range(of: query) {
        return 15_000 - candidate.distance(from: candidate.startIndex, to: range.lowerBound)
    }

    let queryCharacters = Array(query)
    let candidateCharacters = Array(candidate)
    var candidateIndex = 0
    var previousMatchIndex = -2
    var score = 1_000

    for queryCharacter in queryCharacters {
        guard let matchIndex = candidateCharacters[candidateIndex...].firstIndex(of: queryCharacter) else {
            return nil
        }
        score += 40
        if matchIndex == previousMatchIndex + 1 { score += 25 }
        score -= max(0, matchIndex - previousMatchIndex - 1)
        previousMatchIndex = matchIndex
        candidateIndex = matchIndex + 1
    }

    if previousMatchIndex - queryCharacters.count + 1 == 0 { score += 100 }
    return score
}

struct ClipboardSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onMove: (MoveCommandDirection) -> Void
    let onActivate: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> ClipboardNativeSearchField {
        let field = ClipboardNativeSearchField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.onMove = onMove
        field.onActivate = onActivate
        field.onCancel = onCancel
        return field
    }

    func updateNSView(_ field: ClipboardNativeSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.onMove = onMove
        field.onActivate = onActivate
        field.onCancel = onCancel

    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard let field = control as? ClipboardNativeSearchField else { return false }

            switch commandSelector {
            case #selector(NSResponder.moveLeft(_:)):
                field.onMove?(.left)
            case #selector(NSResponder.moveRight(_:)):
                field.onMove?(.right)
            case #selector(NSResponder.moveUp(_:)):
                field.onMove?(.up)
            case #selector(NSResponder.moveDown(_:)):
                field.onMove?(.down)
            case #selector(NSResponder.insertNewline(_:)):
                field.onActivate?()
            case #selector(NSResponder.cancelOperation(_:)):
                field.onCancel?()
            default:
                return false
            }
            return true
        }
    }
}

final class ClipboardNativeSearchField: NSTextField {
    var onMove: ((MoveCommandDirection) -> Void)?
    var onActivate: (() -> Void)?
    var onCancel: (() -> Void)?
    private var didRequestInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didRequestInitialFocus, let window else { return }
        didRequestInitialFocus = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onMove?(.left)
        case 124: onMove?(.right)
        case 125: onMove?(.down)
        case 126: onMove?(.up)
        case 36, 76: onActivate?()
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }
}

func movedClipboardSelection(
    from currentID: UUID?,
    direction: MoveCommandDirection,
    items: [ClipboardItem]
) -> UUID? {
    guard !items.isEmpty else { return nil }
    guard let currentID, let currentIndex = items.firstIndex(where: { $0.id == currentID }) else {
        return direction == .up ? items.last?.id : items.first?.id
    }

    switch direction {
    case .up:
        return items[max(0, currentIndex - 1)].id
    case .down:
        return items[min(items.count - 1, currentIndex + 1)].id
    default:
        return currentID
    }
}

func movedClipboardTab(from currentTab: ClipboardTab, direction: MoveCommandDirection) -> ClipboardTab {
    let tabs = ClipboardTab.allCases
    guard let currentIndex = tabs.firstIndex(of: currentTab) else { return .all }

    switch direction {
    case .left:
        return tabs[max(0, currentIndex - 1)]
    case .right:
        return tabs[min(tabs.count - 1, currentIndex + 1)]
    default:
        return currentTab
    }
}

enum ClipboardTab: String, CaseIterable {
    case all = "All"
    case text = "Text"
    case images = "Images"
    case files = "Files"
    case favorites = "Favorites"
    
    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .text: return "text.alignleft"
        case .images: return "photo"
        case .files: return "doc"
        case .favorites: return "heart.fill"
        }
    }
    
    var localizedName: String {
        switch self {
        case .all: return "全部"
        case .text: return "文本"
        case .images: return "图片"
        case .files: return "文件"
        case .favorites: return "收藏"
        }
    }

    func includes(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all:
            return !item.isPinned
        case .text:
            return !item.isPinned && [.text, .url, .rtf, .unknown].contains(item.type)
        case .images:
            return !item.isPinned && item.type == .image
        case .files:
            return !item.isPinned && item.type == .file
        case .favorites:
            return item.isPinned
        }
    }

    func items(from manager: ClipboardManager) -> [ClipboardItem] {
        if self == .favorites {
            return manager.pinnedItems
        }
        return manager.regularHistory.filter { includes($0) }
    }
}

struct ClipboardTabButton: View {
    let tab: ClipboardTab
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(tab.localizedName)
                    .font(.system(size: 11, weight: .medium))

                Rectangle()
                    .fill(isSelected ? Color.primary : Color.clear)
                    .frame(height: 2)
            }
            .foregroundColor(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
        .buttonStyle(PlainButtonStyle())
    }
}
