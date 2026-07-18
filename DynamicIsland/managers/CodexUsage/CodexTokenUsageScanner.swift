/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Foundation

enum CodexTokenUsageScanner {
    static func scan(now: Date = Date()) -> CodexTokenUsage {
        let fiveHourStart = now.addingTimeInterval(-5 * 3_600)
        let dayStart = now.addingTimeInterval(-24 * 3_600)
        let weekStart = now.addingTimeInterval(-7 * 24 * 3_600)
        let root = sessionsRoot()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return .zero
        }

        var fiveHour = 0
        var twentyFourHour = 0
        var weekly = 0

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl",
                  fileURL.lastPathComponent.hasPrefix("rollout-"),
                  let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt >= weekStart else {
                continue
            }

            streamLines(at: fileURL) { line in
                guard line.range(of: tokenCountMarker) != nil,
                      let raw = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      raw["type"] as? String == "event_msg",
                      let payload = raw["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let lastUsage = info["last_token_usage"] as? [String: Any],
                      let timestamp = parseDate(raw["timestamp"] as? String) else {
                    return
                }

                let tokens = max(0, number(lastUsage["input_tokens"]))
                    + max(0, number(lastUsage["output_tokens"]))
                guard tokens > 0, timestamp >= weekStart else { return }

                weekly += tokens
                if timestamp >= dayStart { twentyFourHour += tokens }
                if timestamp >= fiveHourStart { fiveHour += tokens }
            }
        }

        return CodexTokenUsage(
            fiveHour: fiveHour,
            twentyFourHour: twentyFourHour,
            weekly: weekly
        )
    }

    private static let tokenCountMarker = Data("token_count".utf8)

    private static func sessionsRoot() -> URL {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    private static func streamLines(at url: URL, onLine: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        let maximumUsefulLineBytes = 1 << 20
        var pending = Data()
        var discardingLongLine = false

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { break }

            var start = 0
            while let newline = chunk[start...].firstIndex(of: 0x0A) {
                let end = newline
                if discardingLongLine {
                    discardingLongLine = false
                    pending.removeAll(keepingCapacity: true)
                } else if pending.isEmpty {
                    if end - start <= maximumUsefulLineBytes {
                        onLine(chunk[start..<end])
                    }
                } else {
                    pending.append(chunk[start..<end])
                    onLine(pending)
                    pending.removeAll(keepingCapacity: true)
                }
                start = end + 1
            }

            if start < chunk.count, !discardingLongLine {
                pending.append(chunk[start..<chunk.count])
                if pending.count > maximumUsefulLineBytes {
                    pending.removeAll(keepingCapacity: true)
                    discardingLongLine = true
                }
            }
        }

        if !discardingLongLine, !pending.isEmpty {
            onLine(pending)
        }
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return fractionalDateFormatter.date(from: value)
            ?? plainDateFormatter.date(from: value)
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func number(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }
}
