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
import AtollExtensionKit
import Combine
import Defaults
import Foundation

extension Notification.Name {
    static let extensionAuthorizationConfigurationDidChange =
        Notification.Name("AtollExtensionAuthorizationConfigurationDidChange")
}

/// Hosts Codex usage directly inside Atoll.
///
/// Older builds relied on a separately launched AtollCodexUsage.app. That made
/// the permission toggle and the process lifecycle independent: a switch could
/// be on while no process was publishing data. This manager makes Atoll the
/// single owner of registration, refresh scheduling, and presentation.
@MainActor
final class CodexUsageIntegrationManager: ObservableObject {
    static let shared = CodexUsageIntegrationManager()

    static let bundleIdentifier = "dev.atoll.extensions.codexusage"
    static let experienceID = "codex-usage-tab"

    @Published private(set) var isRunning = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var status = String(localized: "Stopped")

    private let fetcher = CodexUsageFetcher()
    private let authorizationManager = ExtensionAuthorizationManager.shared
    private let notchManager = ExtensionNotchExperienceManager.shared
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var notificationToken: NSObjectProtocol?
    private var hasStarted = false

    private init() {}

    func start() {
        guard !hasStarted else {
            reconcile()
            return
        }
        hasStarted = true

        terminateLegacyHelper()
        observeConfiguration()
        registerBuiltInIntegrationIfNeeded()
        reconcile()
    }

    func shutdown() {
        hasStarted = false
        stopAndDismiss(status: String(localized: "Stopped"))
        cancellables.removeAll()
        if let notificationToken {
            NotificationCenter.default.removeObserver(notificationToken)
            self.notificationToken = nil
        }
    }

    func reconcile() {
        guard hasStarted else { return }
        if shouldRun {
            beginRefreshingIfNeeded()
        } else {
            stopAndDismiss(status: disabledReason)
        }
    }

    func refreshNow() {
        guard shouldRun, !isRefreshing else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    func setEnabledFromSettings(_ enabled: Bool) {
        if enabled {
            Defaults[.enableExtensionNotchExperiences] = true
            Defaults[.enableExtensionNotchTabs] = true
            Defaults[.enableExtensionNotchInteractiveWebViews] = true
        }
        authorizationManager.setExtensionEnabled(
            bundleIdentifier: Self.bundleIdentifier,
            enabled: enabled
        )
        reconcile()
    }

    private var shouldRun: Bool {
        guard Defaults[.enableThirdPartyExtensions],
              Defaults[.enableExtensionNotchExperiences],
              Defaults[.enableExtensionNotchTabs],
              Defaults[.enableExtensionNotchInteractiveWebViews],
              authorizationManager.isExtensionEnabled(bundleIdentifier: Self.bundleIdentifier),
              let entry = authorizationManager.authorizationEntry(for: Self.bundleIdentifier),
              entry.isAuthorized,
              entry.allowedScopes.contains(.notchExperiences) else {
            return false
        }
        return true
    }

    private var disabledReason: String {
        guard authorizationManager.isExtensionEnabled(bundleIdentifier: Self.bundleIdentifier) else {
            return String(localized: "Stopped")
        }
        guard Defaults[.enableThirdPartyExtensions],
              Defaults[.enableExtensionNotchExperiences],
              Defaults[.enableExtensionNotchTabs],
              Defaults[.enableExtensionNotchInteractiveWebViews] else {
            return String(localized: "Waiting for extension features")
        }
        return String(localized: "Not authorized")
    }

    private func observeConfiguration() {
        let reconcile: () -> Void = { [weak self] in
            Task { @MainActor in self?.reconcile() }
        }

        Defaults.publisher(.enableThirdPartyExtensions, options: [])
            .sink { _ in reconcile() }
            .store(in: &cancellables)
        Defaults.publisher(.enableExtensionNotchExperiences, options: [])
            .sink { _ in reconcile() }
            .store(in: &cancellables)
        Defaults.publisher(.enableExtensionNotchTabs, options: [])
            .sink { _ in reconcile() }
            .store(in: &cancellables)
        Defaults.publisher(.enableExtensionNotchInteractiveWebViews, options: [])
            .sink { _ in reconcile() }
            .store(in: &cancellables)

        notificationToken = NotificationCenter.default.addObserver(
            forName: .extensionAuthorizationConfigurationDidChange,
            object: nil,
            queue: .main
        ) { _ in
            reconcile()
        }
    }

    private func registerBuiltInIntegrationIfNeeded() {
        if authorizationManager.authorizationEntry(for: Self.bundleIdentifier) == nil {
            _ = authorizationManager.ensureEntryExists(
                bundleIdentifier: Self.bundleIdentifier,
                appName: "Codex Usage"
            )
            authorizationManager.authorize(
                bundleIdentifier: Self.bundleIdentifier,
                appName: "Codex Usage",
                scopes: [.notchExperiences]
            )
        } else {
            authorizationManager.updateAppNameIfPlaceholder(
                bundleIdentifier: Self.bundleIdentifier,
                appName: "Codex Usage"
            )
        }
    }

    private func beginRefreshingIfNeeded() {
        guard refreshTimer == nil else {
            isRunning = true
            return
        }

        isRunning = true
        status = String(localized: "Starting…")
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        refreshNow()
    }

    private func stopAndDismiss(status: String) {
        refreshTask?.cancel()
        refreshTask = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        isRefreshing = false
        isRunning = false
        self.status = status
        notchManager.dismiss(
            experienceID: Self.experienceID,
            bundleIdentifier: Self.bundleIdentifier
        )
    }

    private func refresh() async {
        guard shouldRun, !isRefreshing else { return }
        isRefreshing = true
        status = String(localized: "Refreshing…")
        defer { isRefreshing = false }

        do {
            let usage = try await fetcher.fetch()
            try Task.checkCancellation()
            guard shouldRun else { return }

            let descriptor = CodexUsageDashboard.descriptor(for: usage)
            if notchManager.payload(
                bundleIdentifier: Self.bundleIdentifier,
                experienceID: Self.experienceID
            ) == nil {
                try notchManager.present(
                    descriptor: descriptor,
                    bundleIdentifier: Self.bundleIdentifier
                )
            } else {
                try notchManager.update(
                    descriptor: descriptor,
                    bundleIdentifier: Self.bundleIdentifier
                )
            }

            lastUpdated = .now
            status = String(localized: "Running in Atoll")
        } catch is CancellationError {
            return
        } catch {
            status = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            Logger.log("Codex usage refresh failed: \(status)", category: .extensions)
        }
    }

    private func terminateLegacyHelper() {
        for app in NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        ) {
            _ = app.terminate()
        }
    }
}

@MainActor
private enum CodexUsageDashboard {
    static func descriptor(for usage: CodexUsageSnapshot) -> AtollNotchExperienceDescriptor {
        AtollNotchExperienceDescriptor(
            id: CodexUsageIntegrationManager.experienceID,
            bundleIdentifier: CodexUsageIntegrationManager.bundleIdentifier,
            priority: .normal,
            accentColor: AtollColorDescriptor(
                red: 0.25,
                green: 0.85,
                blue: 0.68
            ),
            metadata: [
                "fiveHourReset": resetString(usage.fiveHour.resetAt),
                "weeklyReset": resetString(usage.weekly.resetAt),
                "plan": usage.plan ?? ""
            ],
            tab: .init(
                title: "\u{200B}",
                iconSymbolName: "sparkles",
                badgeIcon: .symbol(name: "sparkles", size: 18, weight: .semibold),
                preferredHeight: 200,
                sections: [],
                webContent: .init(
                    html: html(for: usage),
                    preferredHeight: 162,
                    isTransparent: true,
                    allowLocalhostRequests: false,
                    maximumContentWidth: 640
                ),
                allowWebInteraction: true
            )
        )
    }

    private static func html(for usage: CodexUsageSnapshot) -> String {
        let plan = htmlEscape((usage.plan ?? "plus").uppercased())
        let fiveReset = htmlEscape(resetDescription(
            usage.fiveHour.resetAt,
            includeDate: false
        ))
        let weeklyReset = htmlEscape(resetDescription(
            usage.weekly.resetAt,
            includeDate: true
        ))
        let five = usage.fiveHour.remainingPercent
        let week = usage.weekly.remainingPercent
        let fiveHourTokens = compactTokenCount(usage.tokenUsage.fiveHour)
        let dailyTokens = compactTokenCount(usage.tokenUsage.twentyFourHour)
        let weeklyTokens = compactTokenCount(usage.tokenUsage.weekly)
        let fiveBars = barSegments(filledPercent: five)
        let weekBars = barSegments(filledPercent: week)

        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        *{box-sizing:border-box}html,body{margin:0;background:transparent;color:#f6f7fb;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display",sans-serif;overflow:hidden}
        body{height:162px;outline:none}.wrap{position:relative;height:162px;padding:2px 10px 0}.dashboard{position:relative;height:140px}
        .quota{height:62px;display:grid;grid-template-columns:102px minmax(0,1fr) minmax(0,1fr);gap:24px}.identity{position:absolute;left:0;top:0;width:102px;height:132px;display:flex;align-items:center;justify-content:flex-start;gap:7px}.openai{width:21px;height:21px;color:#f5f6f8;filter:drop-shadow(0 0 5px #ffffff28)}.pill{font-size:10px;font-weight:800;color:#d4d4da;background:#ffffff16;border:1px solid #ffffff12;border-radius:5px;padding:3px 7px;letter-spacing:.45px}
        .metric{padding-top:11px}.row{display:flex;align-items:baseline;justify-content:space-between;margin-bottom:8px}.label{font-size:13px;color:#a8aab3;font-weight:800;white-space:nowrap}.value-line{display:flex;align-items:baseline;gap:7px}.value{font-size:26px;font-weight:850;line-height:.85;letter-spacing:.2px}.value span{font-size:12px;color:#a8aab3;margin-left:2px}.inline-reset{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:10px;font-weight:750;color:#a6a8b0;white-space:nowrap}
        .bar{display:grid;grid-template-columns:repeat(30,1fr);gap:3px;height:14px}.seg{height:14px;border-radius:3px;background:#ffffff13}.seg.on{background:#75c6ff;box-shadow:0 0 7px #58baff70}
        .tokens{height:70px;margin-left:126px;display:grid;grid-template-columns:1fr 1fr 1fr;gap:0;border-top:1px solid #ffffff12}.stat{padding:9px 16px 0}.stat:not(:last-child){border-right:1px solid #ffffff12}.token-label{font-size:12px;color:#a8aab3;font-weight:800}.token-value{font-size:25px;font-weight:820;color:#73c4ff;text-shadow:0 0 15px #4db3ff70;line-height:1;margin-top:5px}.cap{font-size:10px;color:#737680;font-weight:750;margin-top:3px}.status{position:absolute;right:10px;bottom:0;font-size:10px;font-weight:760;color:#d9dbe2}.dotgreen{display:inline-block;width:7px;height:7px;border-radius:50%;background:#30d98b;box-shadow:0 0 8px #30d98b;margin-right:6px}
        </style></head><body><div class="wrap"><div class="dashboard">
        <section class="quota">
        <div class="identity"><svg class="openai" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round" aria-label="OpenAI"><path d="M12 3.2a4.3 4.3 0 0 1 7.37 3.03 4.3 4.3 0 0 1 1.95 7.73 4.3 4.3 0 0 1-5.41 5.83A4.3 4.3 0 0 1 8.63 20a4.3 4.3 0 0 1-5.95-5.3A4.3 4.3 0 0 1 4.6 7.04 4.3 4.3 0 0 1 12 3.2Z"/><path d="m8.1 7.1 7.8 4.5v8.1M4.7 14.5l7.3-4.2 7.2 4.2M12 3.2v8.4l-7.3 4.2"/></svg><div class="pill">\(plan)</div></div>
        <div aria-hidden="true"></div>
        <div class="metric"><div class="row"><div class="label">5h</div><div class="value-line"><div class="inline-reset">\(fiveReset)</div><div class="value">\(five)<span>%</span></div></div></div><div class="bar">\(fiveBars)</div></div>
        <div class="metric"><div class="row"><div class="label">1 week</div><div class="value-line"><div class="inline-reset">\(weeklyReset)</div><div class="value">\(week)<span>%</span></div></div></div><div class="bar">\(weekBars)</div></div>
        </section>
        <section class="tokens">
        <div class="stat"><div class="token-label">5h</div><div class="token-value">\(fiveHourTokens)</div><div class="cap">tokens used</div></div>
        <div class="stat"><div class="token-label">24h</div><div class="token-value">\(dailyTokens)</div><div class="cap">tokens used</div></div>
        <div class="stat"><div class="token-label">1 week</div><div class="token-value">\(weeklyTokens)</div><div class="cap">tokens used</div></div>
        </section></div><div class="status"><span class="dotgreen"></span>synced</div></div>
        </body></html>
        """
    }

    private static func resetDescription(_ date: Date?, includeDate: Bool) -> String {
        guard let date else { return "reset —" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = includeDate ? "HH:mm 'on' d MMM" : "HH:mm"
        return "↻ \(formatter.string(from: date))"
    }

    private static func barSegments(filledPercent: Int) -> String {
        let segmentCount = 30
        let filled = max(
            0,
            min(
                segmentCount,
                Int((Double(filledPercent) / 100 * Double(segmentCount)).rounded())
            )
        )
        return (0..<segmentCount).map { index in
            "<i class=\"seg\(index < filled ? " on" : "")\"></i>"
        }.joined()
    }

    private static func compactTokenCount(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }

    private static func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func resetString(_ date: Date?) -> String {
        guard let date else { return "" }
        return String(Int(date.timeIntervalSince1970))
    }
}
