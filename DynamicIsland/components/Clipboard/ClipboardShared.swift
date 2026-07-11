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
        case .all: return String(localized: "All")
        case .text: return String(localized: "Text")
        case .images: return String(localized: "Image")
        case .files: return String(localized: "File")
        case .favorites: return String(localized: "Favorites")
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
