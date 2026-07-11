/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
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

import AtollExtensionKit
import SwiftUI
import Defaults
import AppKit
import UniformTypeIdentifiers

@MainActor
private final class TabDragSession: ObservableObject {
    private weak var viewModel: DynamicIslandViewModel?
    private var token: UUID?
    private var localMouseUpMonitor: Any?
    private var globalMouseUpMonitor: Any?

    func begin(using viewModel: DynamicIslandViewModel) {
        end()

        let token = UUID()
        self.token = token
        self.viewModel = viewModel
        viewModel.setAutoCloseSuppression(true, token: token)

        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            Task { @MainActor in
                self?.end()
            }
            return event
        }
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            Task { @MainActor in
                self?.end()
            }
        }
    }

    func end() {
        if let token {
            viewModel?.setAutoCloseSuppression(false, token: token)
        }
        token = nil
        viewModel = nil

        if let localMouseUpMonitor {
            NSEvent.removeMonitor(localMouseUpMonitor)
            self.localMouseUpMonitor = nil
        }
        if let globalMouseUpMonitor {
            NSEvent.removeMonitor(globalMouseUpMonitor)
            self.globalMouseUpMonitor = nil
        }
    }

}

struct TabModel: Identifiable {
    let id: String
    let label: String
    let icon: String
    let customIcon: AtollIconDescriptor?
    let view: NotchViews
    let experienceID: String?
    let accentColor: Color?

    init(label: String, icon: String, customIcon: AtollIconDescriptor? = nil, view: NotchViews, experienceID: String? = nil, accentColor: Color? = nil) {
        self.id = experienceID.map { "extension-\($0)" } ?? "system-\(view)-\(label)"
        self.label = label
        self.icon = icon
        self.customIcon = customIcon
        self.view = view
        self.experienceID = experienceID
        self.accentColor = accentColor
    }
}

struct TabSelectionView: View {
    @EnvironmentObject private var vm: DynamicIslandViewModel
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
    @ObservedObject private var extensionNotchExperienceManager = ExtensionNotchExperienceManager.shared
    @StateObject private var quickShareService = QuickShareService.shared
    @Default(.quickShareProvider) private var quickShareProvider
    @State private var showQuickSharePopover = false
    @Default(.enableTimerFeature) var enableTimerFeature
    @Default(.enableStatsFeature) var enableStatsFeature
    @Default(.enableColorPickerFeature) var enableColorPickerFeature
    @Default(.timerDisplayMode) var timerDisplayMode
    @Default(.enableThirdPartyExtensions) private var enableThirdPartyExtensions
    @Default(.enableExtensionNotchExperiences) private var enableExtensionNotchExperiences
    @Default(.enableExtensionNotchTabs) private var enableExtensionNotchTabs
    @Default(.showCalendar) private var showCalendar
    @Default(.showMirror) private var showMirror
    @Default(.showStandardMediaControls) private var showStandardMediaControls
    @Default(.enableMinimalisticUI) private var enableMinimalisticUI
    @Default(.notchTabOrder) private var notchTabOrder
    @Default(.hiddenNotchTabIDs) private var hiddenNotchTabIDs
    @Namespace var animation
    @StateObject private var tabDragSession = TabDragSession()

    private static let tabDragType = UTType(exportedAs: "com.atoll.notch-tab")
    
    private var tabs: [TabModel] {
        var tabsArray: [TabModel] = []

        if homeTabVisible {
            tabsArray.append(TabModel(label: "Home", icon: "house.fill", view: .home))
        }

        if Defaults[.dynamicShelf] {
            tabsArray.append(TabModel(label: "Shelf", icon: "tray.fill", view: .shelf))
        }
        
        if enableTimerFeature && timerDisplayMode == .tab {
            tabsArray.append(TabModel(label: "Timer", icon: "timer", view: .timer))
        }

        // Stats tab only shown when stats feature is enabled
        if Defaults[.enableStatsFeature] {
            tabsArray.append(TabModel(label: "Stats", icon: "chart.xyaxis.line", view: .stats))
        }

        if Defaults[.enableNotes] || (Defaults[.enableClipboardManager] && Defaults[.clipboardDisplayMode] == .separateTab) {
            let label = Defaults[.enableNotes] ? "Notes" : "Clipboard"
            let icon = Defaults[.enableNotes] ? "note.text" : "doc.on.clipboard"
            tabsArray.append(TabModel(label: label, icon: icon, view: .notes))
        }
        if Defaults[.enableTerminalFeature] {
            tabsArray.append(TabModel(label: "Terminal", icon: "apple.terminal", view: .terminal))
        }
        if extensionTabsEnabled {
            for payload in extensionTabPayloads {
                guard let tab = payload.descriptor.tab else { continue }
                let accent = payload.descriptor.accentColor.swiftUIColor
                let iconName = tab.iconSymbolName ?? "puzzlepiece.extension"
                tabsArray.append(
                    TabModel(
                        label: tab.title,
                        icon: iconName,
                        customIcon: tab.badgeIcon,
                        view: .extensionExperience,
                        experienceID: payload.descriptor.id,
                        accentColor: accent
                    )
                )
            }
        }
        return applySavedLayout(to: tabsArray)
    }
    var body: some View {
        HStack(spacing: 24) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { idx, tab in
                let isSelected = isSelected(tab)
                let activeAccent = tab.accentColor ?? .white

                // Render the tab button
                TabButton(label: tab.label, icon: tab.icon, customIcon: tab.customIcon, selected: isSelected) {
                    if tab.view == .extensionExperience {
                        coordinator.selectedExtensionExperienceID = tab.experienceID
                    }
                    coordinator.currentView = tab.view
                }
                .frame(height: 26)
                .onDrag {
                    tabDragProvider(for: tab)
                }
                .onDrop(of: [Self.tabDragType], isTargeted: nil) { providers in
                    moveTab(from: providers, before: tab.id)
                }
                .contextMenu {
                    Button("Hide from Tab Bar", role: .destructive) {
                        hideTab(tab)
                    }
                }
                .foregroundStyle(isSelected ? activeAccent : .gray)
                .background {
                    if isSelected {
                        Capsule()
                            .fill((tab.accentColor ?? Color(nsColor: .secondarySystemFill)).opacity(0.25))
                            .shadow(color: (tab.accentColor ?? .clear).opacity(0.4), radius: 8)
                            .matchedGeometryEffect(id: "capsule", in: animation)
                    } else {
                        Capsule()
                            .fill(Color.clear)
                            .matchedGeometryEffect(id: "capsule", in: animation)
                            .hidden()
                    }
                }

                
            }
        }
        .animation(.smooth(duration: 0.3), value: coordinator.currentView)
        .clipShape(Capsule())
        .contextMenu {
            Button("Restore Hidden Tabs") {
                hiddenNotchTabIDs.removeAll()
                ensureValidSelection(with: tabs)
            }
            .disabled(hiddenNotchTabIDs.isEmpty)

            Button("Reset Tab Order") {
                notchTabOrder.removeAll()
            }
            .disabled(notchTabOrder.isEmpty)
        }
        .onAppear {
            ensureValidSelection(with: tabs)
        }
        .onDisappear {
            tabDragSession.end()
        }
    }

    private var extensionTabsEnabled: Bool {
        enableThirdPartyExtensions && enableExtensionNotchExperiences && enableExtensionNotchTabs
    }

    private var extensionTabPayloads: [ExtensionNotchExperiencePayload] {
        extensionNotchExperienceManager.activeExperiences.filter { $0.descriptor.tab != nil }
    }

    private var homeTabVisible: Bool {
        if enableMinimalisticUI {
            return true
        }
        return showStandardMediaControls || showCalendar || showMirror
    }

    private func isSelected(_ tab: TabModel) -> Bool {
        if tab.view == .extensionExperience {
            return coordinator.currentView == .extensionExperience
                && coordinator.selectedExtensionExperienceID == tab.experienceID
        }
        return coordinator.currentView == tab.view
    }

    private func applySavedLayout(to availableTabs: [TabModel]) -> [TabModel] {
        let visibleTabs = availableTabs.filter { !hiddenNotchTabIDs.contains($0.id) }
        let tabsByID = Dictionary(uniqueKeysWithValues: visibleTabs.map { ($0.id, $0) })
        let orderedTabs = notchTabOrder.compactMap { tabsByID[$0] }
        let unorderedTabs = visibleTabs.filter { !notchTabOrder.contains($0.id) }
        return orderedTabs + unorderedTabs
    }

    private func moveTab(from providers: [NSItemProvider], before destinationID: String) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: Self.tabDragType.identifier) { data, _ in
            guard let data,
                  let sourceID = String(data: data, encoding: .utf8),
                  sourceID != destinationID else { return }

            DispatchQueue.main.async {
                var orderedIDs = tabs.map(\.id)
                guard let sourceIndex = orderedIDs.firstIndex(of: sourceID) else { return }

                orderedIDs.remove(at: sourceIndex)
                guard let destinationIndex = orderedIDs.firstIndex(of: destinationID) else { return }
                orderedIDs.insert(sourceID, at: destinationIndex)
                notchTabOrder = orderedIDs
                tabDragSession.end()
            }
        }
        return true
    }

    private func tabDragProvider(for tab: TabModel) -> NSItemProvider {
        guard NSEvent.modifierFlags.contains(.command) else {
            return NSItemProvider()
        }

        tabDragSession.begin(using: vm)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: Self.tabDragType.identifier, visibility: .all) { completion in
            completion(Data(tab.id.utf8), nil)
            return nil
        }
        return provider
    }

    private func hideTab(_ tab: TabModel) {
        guard !hiddenNotchTabIDs.contains(tab.id) else { return }
        hiddenNotchTabIDs.append(tab.id)
        ensureValidSelection(with: tabs)
    }

    private func ensureValidSelection(with tabs: [TabModel]) {
        guard !tabs.isEmpty else { return }
        if tabs.contains(where: { isSelected($0) }) {
            return
        }
        guard let first = tabs.first else { return }
        if first.view == .extensionExperience {
            coordinator.selectedExtensionExperienceID = first.experienceID
        } else {
            coordinator.selectedExtensionExperienceID = nil
        }
        coordinator.currentView = first.view
    }
}

#Preview {
    DynamicIslandHeader().environmentObject(DynamicIslandViewModel())
}
