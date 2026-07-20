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
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Defaults

// Clipboard item data structure
struct ClipboardItem: Identifiable, Codable {
    let id = UUID()
    let type: ClipboardItemType
    let timestamp: Date
    let preview: String
    var isPinned: Bool = false
    
    // Store different types of data - avoid large binary data in UserDefaults
    let stringData: String?
    let imageFileName: String? // Store filename instead of data
    let fileURLs: [String]?
    var rtfData: Data? // Legacy payloads are migrated to files on first launch.
    var rtfFileName: String?
    
    init(stringData: String, type: ClipboardItemType) {
        self.stringData = stringData
        self.imageFileName = nil
        self.fileURLs = nil
        self.rtfData = nil
        self.rtfFileName = nil
        self.type = type
        self.timestamp = Date()
        self.preview = ClipboardItem.generatePreview(stringData: stringData, type: type)
    }
    
    init(imageData: Data, fileExtension: String = "png") {
        self.stringData = nil
        self.fileURLs = nil
        self.rtfData = nil
        self.rtfFileName = nil
        self.type = .image
        self.timestamp = Date()
        
        // Save image data to temporary file instead of storing in UserDefaults
        let fileName = "clipboard_image_\(UUID().uuidString).\(fileExtension.lowercased())"
        let fileURL = ClipboardManager.clipboardDataDirectory.appendingPathComponent(fileName)
        
        do {
            try imageData.write(to: fileURL)
            self.imageFileName = fileName
            self.preview = "Image (\(ByteCountFormatter.string(fromByteCount: Int64(imageData.count), countStyle: .file)))"
        } catch {
            print("Failed to save image data: \(error)")
            self.imageFileName = nil
            self.preview = "Image (failed to save)"
        }
    }
    
    init(fileURLs: [String]) {
        self.stringData = nil
        self.imageFileName = nil
        self.fileURLs = fileURLs
        self.rtfData = nil
        self.rtfFileName = nil
        self.type = .file
        self.timestamp = Date()
        
        if fileURLs.count == 1, let url = URL(string: fileURLs.first!) {
            self.preview = url.lastPathComponent
        } else {
            self.preview = "\(fileURLs.count) files"
        }
    }
    
    init(rtfData: Data, plainText: String) {
        // RTF data is typically small, so we can keep it in UserDefaults
        self.stringData = plainText
        self.imageFileName = nil
        self.fileURLs = nil
        self.rtfData = nil
        self.type = .rtf
        self.timestamp = Date()
        self.preview = String(plainText.prefix(50))

        let fileName = "clipboard_rtf_\(UUID().uuidString).rtf"
        let fileURL = ClipboardManager.clipboardPayloadDirectory.appendingPathComponent(fileName)
        do {
            try rtfData.write(to: fileURL)
            self.rtfFileName = fileName
        } catch {
            print("Failed to save RTF clipboard data: \(error)")
            self.rtfFileName = nil
        }
    }
    
    // Helper to get image data from file
    func getImageData() -> Data? {
        guard let fileName = imageFileName else { return nil }
        let fileURL = ClipboardManager.clipboardDataDirectory.appendingPathComponent(fileName)
        return try? Data(contentsOf: fileURL)
    }

    var imageFileURL: URL? {
        guard let fileName = imageFileName else { return nil }
        let fileURL = ClipboardManager.clipboardDataDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return fileURL
    }

    var imagePasteboardType: NSPasteboard.PasteboardType {
        guard let fileExtension = imageFileName.map({ URL(fileURLWithPath: $0).pathExtension }),
              let type = UTType(filenameExtension: fileExtension) else {
            return .png
        }

        return NSPasteboard.PasteboardType(type.identifier)
    }

    func getRTFData() -> Data? {
        if let rtfFileName {
            return try? Data(contentsOf: ClipboardManager.clipboardPayloadDirectory.appendingPathComponent(rtfFileName))
        }
        return rtfData
    }

    /// Uses the original string for links, including records archived before
    /// link previews were fixed.
    var displayPreview: String {
        type == .url ? (stringData ?? preview) : preview
    }
    
    // Helper to check if this item has the same content as another
    func isSameContent(as other: ClipboardItem) -> Bool {
        return stringData == other.stringData &&
               imageFileName == other.imageFileName &&
               fileURLs == other.fileURLs &&
               type == other.type
    }
    
    static func generatePreview(stringData: String, type: ClipboardItemType) -> String {
        switch type {
        case .text:
            return String(stringData.prefix(50))
        case .url:
            // A URL's lastPathComponent can be "/" or an unrelated file name,
            // which made link entries look as if most of their content was
            // missing. Keep the original URL for an accurate, useful preview.
            return stringData
        case .file:
            if let url = URL(string: stringData) {
                return url.lastPathComponent
            }
            return "File"
        case .image:
            return "Image"
        case .rtf:
            return String(stringData.prefix(50))
        case .unknown:
            return String(stringData.prefix(50))
        }
    }
}

enum ClipboardItemType: String, CaseIterable, Codable {
    case text = "text"
    case url = "url"
    case file = "file"
    case image = "image"
    case rtf = "rtf"
    case unknown = "unknown"
    
    var icon: String {
        switch self {
        case .text: return "doc.text"
        case .url: return "link"
        case .file: return "doc"
        case .image: return "photo"
        case .rtf: return "doc.richtext"
        case .unknown: return "questionmark.circle"
        }
    }
    
    var displayName: String {
        switch self {
        case .text: return String(localized: "Text")
        case .url: return String(localized: "URL")
        case .file: return String(localized: "File")
        case .image: return String(localized: "Image")
        case .rtf: return String(localized: "Rich Text")
        case .unknown: return String(localized: "Unknown")
        }
    }
}

struct ClipboardGroup: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    var items: [ClipboardItem]

    init(id: UUID = UUID(), timestamp: Date = Date(), items: [ClipboardItem]) {
        self.id = id
        self.timestamp = timestamp
        self.items = items
    }

    var title: String {
        let counts = Dictionary(grouping: items, by: \.type)
        let orderedTypes: [ClipboardItemType] = [.text, .url, .rtf, .image, .file, .unknown]
        let parts = orderedTypes.compactMap { type -> String? in
            guard let count = counts[type]?.count, count > 0 else { return nil }
            return "\(type.displayName) \(count)"
        }
        return parts.joined(separator: " · ")
    }

    var preview: String {
        items
            .prefix(3)
            .map(\.displayPreview)
            .joined(separator: "  ·  ")
    }
}

private struct ClipboardArchive: Codable {
    var history: [ClipboardItem]
    var pinnedItems: [ClipboardItem]
    // Optional so archives written by older Atoll versions continue to decode.
    var groups: [ClipboardGroup]?
}

class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()
    
    @Published var clipboardHistory: [ClipboardItem] = []
    @Published var pinnedItems: [ClipboardItem] = []
    @Published var groups: [ClipboardGroup] = []
    @Published var isMonitoring: Bool = false
    @Published private(set) var lastCopiedItemDate: Date?
    
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private var cancellables = Set<AnyCancellable>()
    
    // Use configurable history size from settings
    private var maxHistoryItems: Int {
        return Defaults[.clipboardHistorySize]
    }

    private var expirationDays: Int {
        Defaults[.clipboardExpirationDays]
    }

    private var lastMaintenanceDate = Date.distantPast
    
    // Computed properties for filtered lists
    var regularHistory: [ClipboardItem] {
        clipboardHistory.filter { !$0.isPinned }
    }
    
    var pinnedHistory: [ClipboardItem] {
        pinnedItems
    }
    
    // The archive is the source of truth; in-memory arrays only back the live UI.
    static let clipboardArchiveDirectory: URL = {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = applicationSupport
            .appendingPathComponent("Atoll", isDirectory: true)
            .appendingPathComponent("Clipboard", isDirectory: true)

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static let clipboardDataDirectory: URL = {
        let directory = clipboardArchiveDirectory.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static let clipboardPayloadDirectory: URL = {
        let directory = clipboardArchiveDirectory.appendingPathComponent("Payloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static let clipboardImageExportDirectory: URL = {
        let directory = clipboardArchiveDirectory.appendingPathComponent("Image Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static let imageExportQueue = DispatchQueue(
        label: "com.Ebullioscopic.Atoll.clipboard-image-export",
        qos: .userInitiated
    )

    private static let archiveFileURL = clipboardArchiveDirectory.appendingPathComponent("history.json")
    private static let legacyClipboardDataDirectory: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClipboardData", isDirectory: true)
    }()
    
    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
        loadArchive()
        DispatchQueue.main.async { [weak self] in
            self?.performDatabaseMaintenance()
        }

        Defaults.publisher(.clipboardHistorySize)
            .dropFirst()
            .sink { [weak self] _ in
                self?.applyHistoryLimit()
            }
            .store(in: &cancellables)

        Defaults.publisher(.clipboardExpirationDays)
            .dropFirst()
            .sink { [weak self] _ in
                self?.performDatabaseMaintenance()
            }
            .store(in: &cancellables)
    }
    
    deinit {
        stopMonitoring()
    }
    
    // MARK: - Public Methods
    
    func startMonitoring() {
        guard !isMonitoring else { return }
        
        isMonitoring = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }
    
    func stopMonitoring() {
        isMonitoring = false
        timer?.invalidate()
        timer = nil
    }
    
    @discardableResult
    func copyToClipboard(_ item: ClipboardItem) -> Bool {
        // Resolve file-backed images and rich text before touching the system
        // pasteboard. A missing payload must not clear the user's latest copy.
        let preparedItems = pasteboardItems(for: [item])
        guard !preparedItems.isEmpty else { return false }

        // The monitor polls every 0.5 seconds. A user can copy something in
        // another app and activate a history item before the next poll. Capture
        // that pending external value before replacing the system pasteboard,
        // otherwise advancing lastChangeCount below would lose it forever.
        captureCurrentClipboardChangeIfNeeded(protecting: [item.id])

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let didWrite = pasteboard.writeObjects(preparedItems)

        // This is an intentional write from the history UI. Consume its
        // change count so the monitor does not create a duplicate entry.
        lastChangeCount = pasteboard.changeCount
        guard didWrite else { return false }

        lastCopiedItemDate = Date()
        return true
    }

    @discardableResult
    func copyGroupToClipboard(_ group: ClipboardGroup) -> Bool {
        let preparedItems: [NSPasteboardItem]
        let textCompatibleItems = group.items.filter {
            [.text, .url, .rtf, .unknown].contains($0.type) && $0.stringData != nil
        }
        let isMultiImageGroup = group.items.count > 1
            && group.items.allSatisfy { $0.type == .image }

        // Text destinations usually consume only the first pasteboard item.
        // A single newline-delimited representation guarantees that every
        // selected text value is pasted, in the same order it had in the list.
        if isMultiImageGroup,
           let imageItems = multiImagePasteboardItems(for: group.items) {
            preparedItems = imageItems
        } else if textCompatibleItems.count == group.items.count,
           let combinedItem = combinedTextPasteboardItem(for: textCompatibleItems) {
            preparedItems = [combinedItem]
        } else {
            preparedItems = pasteboardItems(for: group.items)
        }
        guard !preparedItems.isEmpty else { return false }

        // Group activation is also an intentional pasteboard write, so it must
        // preserve any external copy that arrived between monitor ticks.
        captureCurrentClipboardChangeIfNeeded()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let didWrite = pasteboard.writeObjects(preparedItems)
        lastChangeCount = pasteboard.changeCount
        guard didWrite else { return false }

        lastCopiedItemDate = Date()
        return true
    }

    @discardableResult
    func activateItem(_ item: ClipboardItem) -> Bool {
        guard copyToClipboard(item) else { return false }

        if let index = pinnedItems.firstIndex(where: { $0.id == item.id }) {
            let promotedItem = pinnedItems.remove(at: index)
            pinnedItems.insert(promotedItem, at: 0)
        } else if let index = clipboardHistory.firstIndex(where: { $0.id == item.id }) {
            let promotedItem = clipboardHistory.remove(at: index)
            clipboardHistory.insert(promotedItem, at: 0)
        }

        saveArchive()
        return true
    }

    @discardableResult
    func createGroup(from items: [ClipboardItem]) -> ClipboardGroup? {
        var seenIDs = Set<UUID>()
        let uniqueItems = items.filter { seenIDs.insert($0.id).inserted }
        guard uniqueItems.count > 1 else { return nil }

        if let existingIndex = groups.firstIndex(where: {
            hasSameGroupItems($0.items, uniqueItems)
        }) {
            let existingGroup = groups.remove(at: existingIndex)
            groups.insert(existingGroup, at: 0)
            saveArchive()
            return existingGroup
        }

        let group = ClipboardGroup(items: uniqueItems)
        groups.insert(group, at: 0)
        saveArchive()
        return group
    }

    @discardableResult
    func activateGroup(_ group: ClipboardGroup) -> Bool {
        guard copyGroupToClipboard(group) else { return false }
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            let promotedGroup = groups.remove(at: index)
            groups.insert(promotedGroup, at: 0)
        }
        saveArchive()
        return true
    }

    func deleteGroup(_ group: ClipboardGroup) {
        groups.removeAll { $0.id == group.id }
        cleanupOldFiles()
        saveArchive()
    }

    func clearGroups() {
        groups.removeAll()
        cleanupOldFiles()
        saveArchive()
    }
    
    func deleteItem(_ item: ClipboardItem) {
        clipboardHistory.removeAll { $0.id == item.id }
        pinnedItems.removeAll { $0.id == item.id }
        cleanupOldFiles()
        saveArchive()
    }
    
    func clearHistory() {
        clipboardHistory.removeAll()
        cleanupOldFiles()
        saveArchive()
    }
    
    func pinItem(_ item: ClipboardItem) {
        // Update the item to be pinned
        var pinnedItem = item
        pinnedItem.isPinned = true
        
        // Remove from regular history if it exists there
        clipboardHistory.removeAll { $0.id == item.id }
        
        // Add to pinned items if not already there
        if !pinnedItems.contains(where: { $0.id == item.id }) {
            pinnedItems.append(pinnedItem)
        }
        
        saveArchive()
    }
    
    func unpinItem(_ item: ClipboardItem) {
        // Remove from pinned items
        pinnedItems.removeAll { $0.id == item.id }
        
        // Update the item to be unpinned and add back to regular history
        var unpinnedItem = item
        unpinnedItem.isPinned = false
        
        // Add back to regular history at the top
        clipboardHistory.insert(unpinnedItem, at: 0)
        
        trimHistoryToLimit()
        saveArchive()
    }
    
    func togglePin(for item: ClipboardItem) {
        if item.isPinned || pinnedItems.contains(where: { $0.id == item.id }) {
            unpinItem(item)
        } else {
            pinItem(item)
        }
    }

    func clearPinnedItems() {
        pinnedItems.removeAll()
        cleanupOldFiles()
        saveArchive()
    }

    func applyHistoryLimit() {
        performDatabaseMaintenance()
    }

    func clearItems(in tab: ClipboardTab) {
        if tab == .groups {
            clearGroups()
            return
        }
        if tab == .favorites {
            clearPinnedItems()
            return
        }

        let itemsToRemove = clipboardHistory.filter { tab.includes($0) }
        let removedIDs = Set(itemsToRemove.map(\.id))
        clipboardHistory.removeAll { removedIDs.contains($0.id) }
        cleanupOldFiles()
        saveArchive()
    }

    private func combinedTextPasteboardItem(
        for items: [ClipboardItem]
    ) -> NSPasteboardItem? {
        let combinedText = items.compactMap(\.stringData).joined(separator: "\n")
        guard !combinedText.isEmpty else { return nil }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(combinedText, forType: .string)

        guard items.contains(where: { $0.type == .rtf }) else {
            return pasteboardItem
        }

        let combinedAttributedString = NSMutableAttributedString(string: "")
        for (index, item) in items.enumerated() {
            if index > 0 {
                combinedAttributedString.append(NSAttributedString(string: "\n"))
            }

            if item.type == .rtf,
               let rtfData = item.getRTFData(),
               let attributedString = NSAttributedString(
                   rtf: rtfData,
                   documentAttributes: nil
               ) {
                combinedAttributedString.append(attributedString)
            } else if let stringData = item.stringData {
                combinedAttributedString.append(NSAttributedString(string: stringData))
            }
        }

        let fullRange = NSRange(location: 0, length: combinedAttributedString.length)
        let documentAttributes: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf
        ]
        if let rtfData = try? combinedAttributedString.data(
            from: fullRange,
            documentAttributes: documentAttributes
        ) {
            pasteboardItem.setData(rtfData, forType: .rtf)
        }
        return pasteboardItem
    }

    private func pasteboardItems(for items: [ClipboardItem]) -> [NSPasteboardItem] {
        items.flatMap { item -> [NSPasteboardItem] in
            switch item.type {
            case .text, .unknown:
                guard let stringData = item.stringData else { return [] }
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(stringData, forType: .string)
                return [pasteboardItem]
            case .url:
                guard let stringData = item.stringData else { return [] }
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(stringData, forType: .string)
                pasteboardItem.setString(stringData, forType: .URL)
                return [pasteboardItem]
            case .image:
                guard let imageData = item.getImageData() else { return [] }
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setData(imageData, forType: item.imagePasteboardType)
                return [pasteboardItem]
            case .file:
                return (item.fileURLs ?? []).compactMap { urlString in
                    guard let url = URL(string: urlString) else { return nil }
                    let pasteboardItem = NSPasteboardItem()
                    pasteboardItem.setString(url.absoluteString, forType: .fileURL)
                    return pasteboardItem
                }
            case .rtf:
                let pasteboardItem = NSPasteboardItem()
                if let rtfData = item.getRTFData() {
                    pasteboardItem.setData(rtfData, forType: .rtf)
                }
                if let stringData = item.stringData {
                    pasteboardItem.setString(stringData, forType: .string)
                }
                return pasteboardItem.types.isEmpty ? [] : [pasteboardItem]
            }
        }
    }

    /// Build one Finder-compatible snapshot containing every selected image.
    /// TIFF archives are exported to PNG first so destinations such as Codex
    /// show the actual image previews instead of generic TIFF attachment cards.
    private func multiImagePasteboardItems(
        for items: [ClipboardItem]
    ) -> [NSPasteboardItem]? {
        let sourceURLs = items.compactMap(\.imageFileURL)
        guard sourceURLs.count == items.count else { return nil }

        let imageURLs = Self.imageExportQueue.sync {
            sourceURLs.compactMap(Self.shareableImageURL)
        }
        guard imageURLs.count == items.count else { return nil }

        let pasteboardItems = imageURLs.compactMap { imageURL -> NSPasteboardItem? in
            guard let imageData = try? Data(contentsOf: imageURL),
                  !imageData.isEmpty else {
                return nil
            }

            let pasteboardItem = NSPasteboardItem()
            let imageType = UTType(filenameExtension: imageURL.pathExtension)
                .map { NSPasteboard.PasteboardType($0.identifier) }
                ?? .png
            pasteboardItem.setData(imageData, forType: imageType)
            pasteboardItem.setString(imageURL.absoluteString, forType: .fileURL)
            return pasteboardItem
        }
        guard pasteboardItems.count == items.count else { return nil }

        return pasteboardItems
    }

    private static func shareableImageURL(_ sourceURL: URL) -> URL? {
        let sourceExtension = sourceURL.pathExtension.lowercased()
        guard ["tif", "tiff"].contains(sourceExtension) else {
            return sourceURL
        }

        let exportURL = clipboardImageExportDirectory
            .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("png")
        if FileManager.default.fileExists(atPath: exportURL.path) {
            return exportURL
        }

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let destination = CGImageDestinationCreateWithURL(
                exportURL as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            return sourceURL
        }

        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: exportURL)
            return sourceURL
        }
        return exportURL
    }

    private func hasSameGroupItems(
        _ lhs: [ClipboardItem],
        _ rhs: [ClipboardItem]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.type == right.type
                && left.stringData == right.stringData
                && left.imageFileName == right.imageFileName
                && left.fileURLs == right.fileURLs
                && left.rtfFileName == right.rtfFileName
        }
    }
    
    // MARK: - Private Methods
    
    private func checkClipboard() {
        if Date().timeIntervalSince(lastMaintenanceDate) >= 86_400 {
            performDatabaseMaintenance()
        }
        captureCurrentClipboardChangeIfNeeded()
    }

    @discardableResult
    private func captureCurrentClipboardChangeIfNeeded(
        protecting protectedItemIDs: Set<UUID> = []
    ) -> Bool {
        let currentChangeCount = NSPasteboard.general.changeCount

        guard currentChangeCount != lastChangeCount else { return false }
        lastChangeCount = currentChangeCount

        guard let clipboardItem = getCurrentClipboardItem() else { return false }

        // Re-copying an existing item should promote it to the top. addToHistory
        // removes the older matching entry and its payload before inserting this
        // freshly captured item, so duplicate images do not leak orphaned files.
        addToHistory(clipboardItem, protecting: protectedItemIDs)
        return true
    }
    
    private func getCurrentClipboardItem() -> ClipboardItem? {
        let pasteboard = NSPasteboard.general

        let fileURLs = (
            pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        ) ?? []

        // Apps such as WeChat commonly publish both a temporary file URL and
        // image data. Inspect image files before removing temporary URLs.
        for imageURL in fileURLs {
            if let (imageData, fileExtension) = readableImagePayload(at: imageURL) {
                return ClipboardItem(imageData: imageData, fileExtension: fileExtension)
            }
        }

        // Finder files should remain file entries. Temporary and virtual URLs
        // are deliberately excluded here, but no longer prevent the image
        // payload fallback below.
        let persistentFileURLs = fileURLs.filter(isPersistentFileURL)
        if !persistentFileURLs.isEmpty {
            return ClipboardItem(fileURLs: persistentFileURLs.map(\.absoluteString))
        }

        // Do not turn a temporary non-image file's Quick Look preview into an
        // image history entry. A real image file has already been recognized
        // above through ImageIO, including files without an extension.
        let hasReadableNonImageFile = fileURLs.contains { url in
            url.isFileURL && FileManager.default.fileExists(atPath: url.path)
        }
        if hasReadableNonImageFile {
            return nil
        }

        // Read image payloads regardless of whether the source also advertised
        // a temporary URL. This is the path used by WeChat conversation images.
        if let imageItem = imageClipboardItem(from: pasteboard) {
            return imageItem
        }

        // Plain text (including copied text)
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            // Determine if it's a URL
            if string.hasPrefix("http://") || string.hasPrefix("https://") {
                return ClipboardItem(stringData: string, type: .url)
            }
            return ClipboardItem(stringData: string, type: .text)
        }

        // Rich text
        if let rtfData = pasteboard.data(forType: .rtf),
           let rtfString = NSAttributedString(rtf: rtfData, documentAttributes: nil)?.string, !rtfString.isEmpty {
            return ClipboardItem(rtfData: rtfData, plainText: rtfString)
        }

        // URL strings
        if let url = pasteboard.string(forType: .URL) {
            return ClipboardItem(stringData: url, type: .url)
        }

        return nil
    }

    private func readableImagePayload(at url: URL) -> (Data, String)? {
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        let detectedExtension = (CGImageSourceGetType(source) as String?)
            .flatMap { UTType($0)?.preferredFilenameExtension }
        let fileExtension = detectedExtension
            ?? (url.pathExtension.isEmpty ? nil : url.pathExtension)
            ?? "png"
        return (data, fileExtension)
    }

    private func isPersistentFileURL(_ url: URL) -> Bool {
        url.isFileURL
            && !url.path.contains("/.file/id=")
            && !url.path.contains("/tmp/")
            && !url.path.hasPrefix("/private/var/")
            && !url.path.contains("/ClipboardViewer")
            && FileManager.default.fileExists(atPath: url.path)
    }

    private func imageClipboardItem(from pasteboard: NSPasteboard) -> ClipboardItem? {
        let candidates: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "png"),
            (.tiff, "tiff"),
            (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
            (NSPasteboard.PasteboardType("public.heic"), "heic"),
            (NSPasteboard.PasteboardType("public.heif"), "heif"),
            (NSPasteboard.PasteboardType("com.compuserve.gif"), "gif"),
            (NSPasteboard.PasteboardType("com.microsoft.bmp"), "bmp"),
            (NSPasteboard.PasteboardType("org.webmproject.webp"), "webp")
        ]

        for (type, fileExtension) in candidates {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return ClipboardItem(imageData: data, fileExtension: fileExtension)
            }
        }

        // Some apps expose a vendor-specific image UTI that NSImage can decode
        // even though no standard representation is listed directly.
        let declaresImageType = pasteboard.types?.contains { type in
            UTType(type.rawValue)?.conforms(to: .image) == true
        } == true
        guard declaresImageType,
              let image = NSImage(pasteboard: pasteboard),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return ClipboardItem(imageData: pngData, fileExtension: "png")
    }
    
    private func addToHistory(
        _ item: ClipboardItem,
        protecting protectedItemIDs: Set<UUID> = []
    ) {
        // Remove any existing items with the same data
        let itemsToRemove = clipboardHistory.filter { existingItem in
            return isSameContent(existingItem, item)
        }

        // Remove records by their already resolved IDs before deleting
        // payloads. Once an image file is deleted, data-based comparison can
        // no longer identify its history record.
        let itemIDsToRemove = Set(itemsToRemove.map(\.id))
        clipboardHistory.removeAll { itemIDsToRemove.contains($0.id) }

        // Clipboard observation and intentional writes both run on the main
        // thread. Updating synchronously preserves their exact order; queuing
        // this work allowed a later activation to overtake a captured copy.
        clipboardHistory.insert(item, at: 0)
        lastCopiedItemDate = item.timestamp

        trimHistoryToLimit(protecting: protectedItemIDs)
        cleanupOldFiles()
        saveArchive()
    }
    
    // Helper to compare clipboard items for duplicates
    private func isSameContent(_ item1: ClipboardItem, _ item2: ClipboardItem) -> Bool {
        if item1.type != item2.type { return false }
        
        switch item1.type {
        case .text, .url, .unknown:
            return item1.stringData == item2.stringData
        case .image:
            // For images, compare the actual data if both are available
            let data1 = item1.getImageData()
            let data2 = item2.getImageData()
            return data1 == data2
        case .file:
            return item1.fileURLs == item2.fileURLs
        case .rtf:
            return item1.stringData == item2.stringData && item1.getRTFData() == item2.getRTFData()
        }
    }
    
    // Clean up old image files that are no longer referenced
    private func cleanupOldFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: ClipboardManager.clipboardDataDirectory, includingPropertiesForKeys: nil) else { return }
        
        let allItems = clipboardHistory + pinnedItems + groups.flatMap(\.items)
        let referencedFiles = Set(allItems.compactMap { $0.imageFileName })
        
        for file in files {
            let fileName = file.lastPathComponent
            if !referencedFiles.contains(fileName) {
                try? FileManager.default.removeItem(at: file)
            }
        }

        let referencedExportFiles = Set(
            referencedFiles.map {
                URL(fileURLWithPath: $0)
                    .deletingPathExtension()
                    .appendingPathExtension("png")
                    .lastPathComponent
            }
        )
        if let exportFiles = try? FileManager.default.contentsOfDirectory(
            at: ClipboardManager.clipboardImageExportDirectory,
            includingPropertiesForKeys: nil
        ) {
            for file in exportFiles where !referencedExportFiles.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }

        guard let payloadFiles = try? FileManager.default.contentsOfDirectory(at: ClipboardManager.clipboardPayloadDirectory, includingPropertiesForKeys: nil) else { return }
        let referencedPayloads = Set(allItems.compactMap { $0.rtfFileName })
        for file in payloadFiles where !referencedPayloads.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func trimHistoryToLimit(
        protecting protectedItemIDs: Set<UUID> = []
    ) {
        let limit = max(1, maxHistoryItems)
        while clipboardHistory.count > limit {
            guard let removalIndex = clipboardHistory.lastIndex(where: {
                !protectedItemIDs.contains($0.id)
            }) else {
                clipboardHistory = Array(clipboardHistory.prefix(limit))
                return
            }
            clipboardHistory.remove(at: removalIndex)
        }
    }

    private func removeExpiredItems() {
        guard expirationDays > 0 else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -expirationDays, to: Date()) ?? .distantPast
        clipboardHistory.removeAll { $0.timestamp < cutoff }
    }

    private func removeItemsWithMissingImagePayloads() {
        let hasImagePayload: (ClipboardItem) -> Bool = { item in
            guard item.type == .image else { return true }
            guard let fileName = item.imageFileName else { return false }
            let fileURL = ClipboardManager.clipboardDataDirectory.appendingPathComponent(fileName)
            return FileManager.default.fileExists(atPath: fileURL.path)
        }

        clipboardHistory.removeAll { !hasImagePayload($0) }
        pinnedItems.removeAll { !hasImagePayload($0) }
        groups = groups.compactMap { group in
            var repairedGroup = group
            repairedGroup.items = group.items.filter(hasImagePayload)
            return repairedGroup.items.isEmpty ? nil : repairedGroup
        }
    }

    private func performDatabaseMaintenance() {
        removeItemsWithMissingImagePayloads()
        removeDuplicateGroups()
        removeExpiredItems()
        trimHistoryToLimit()
        cleanupOldFiles()
        lastMaintenanceDate = Date()
        saveArchive()
    }

    /// Keep the newest occurrence when older versions created the same group
    /// more than once after repeated Enter events.
    private func removeDuplicateGroups() {
        var uniqueGroups: [ClipboardGroup] = []
        for group in groups where !uniqueGroups.contains(where: {
            hasSameGroupItems($0.items, group.items)
        }) {
            uniqueGroups.append(group)
        }
        groups = uniqueGroups
    }

    // MARK: - Persistence
    
    @discardableResult
    private func saveArchive() -> Bool {
        let archive = ClipboardArchive(
            history: clipboardHistory,
            pinnedItems: pinnedItems,
            groups: groups
        )

        do {
            let encoded = try JSONEncoder().encode(archive)
            try encoded.write(to: ClipboardManager.archiveFileURL, options: .atomic)
            return true
        } catch {
            print("Failed to save clipboard archive: \(error)")
            return false
        }
    }

    private func loadArchive() {
        if let data = try? Data(contentsOf: ClipboardManager.archiveFileURL),
           let archive = try? JSONDecoder().decode(ClipboardArchive.self, from: data) {
            clipboardHistory = archive.history
            pinnedItems = archive.pinnedItems
            groups = archive.groups ?? []
            migrateLegacyImageFiles()
            migrateLegacyRTFPayloads()
            return
        }

        let legacyHistory = UserDefaults.standard.data(forKey: "ClipboardHistory")
            .flatMap { try? JSONDecoder().decode([ClipboardItem].self, from: $0) } ?? []
        let legacyPinnedItems = UserDefaults.standard.data(forKey: "ClipboardPinnedItems")
            .flatMap { try? JSONDecoder().decode([ClipboardItem].self, from: $0) } ?? []

        clipboardHistory = legacyHistory
        pinnedItems = legacyPinnedItems
        groups = []
        migrateLegacyImageFiles()
        migrateLegacyRTFPayloads()

        guard !legacyHistory.isEmpty || !legacyPinnedItems.isEmpty else { return }
        if saveArchive() {
            UserDefaults.standard.removeObject(forKey: "ClipboardHistory")
            UserDefaults.standard.removeObject(forKey: "ClipboardPinnedItems")
        }
    }

    private func migrateLegacyImageFiles() {
        let fileManager = FileManager.default
        let allItems = clipboardHistory + pinnedItems + groups.flatMap(\.items)

        for fileName in Set(allItems.compactMap(\.imageFileName)) {
            let sourceURL = ClipboardManager.legacyClipboardDataDirectory.appendingPathComponent(fileName)
            let destinationURL = ClipboardManager.clipboardDataDirectory.appendingPathComponent(fileName)

            guard fileManager.fileExists(atPath: sourceURL.path), !fileManager.fileExists(atPath: destinationURL.path) else { continue }
            try? fileManager.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    private func migrateLegacyRTFPayloads() {
        migrateLegacyRTFPayloads(in: &clipboardHistory)
        migrateLegacyRTFPayloads(in: &pinnedItems)
        for index in groups.indices {
            migrateLegacyRTFPayloads(in: &groups[index].items)
        }
    }

    private func migrateLegacyRTFPayloads(in items: inout [ClipboardItem]) {
        for index in items.indices {
            guard items[index].rtfFileName == nil, let rtfData = items[index].rtfData else { continue }

            let fileName = "clipboard_rtf_\(UUID().uuidString).rtf"
            let fileURL = ClipboardManager.clipboardPayloadDirectory.appendingPathComponent(fileName)
            guard (try? rtfData.write(to: fileURL)) != nil else { continue }

            items[index].rtfFileName = fileName
            items[index].rtfData = nil
        }
    }
}
