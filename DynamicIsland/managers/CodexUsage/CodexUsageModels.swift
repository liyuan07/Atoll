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

struct CodexUsageWindow: Equatable, Sendable {
    let usedFraction: Double
    let resetAt: Date?

    init(usedFraction: Double, resetAt: Date?) {
        self.usedFraction = min(max(usedFraction, 0), 1)
        self.resetAt = resetAt
    }

    var remainingPercent: Int {
        Int(((1 - usedFraction) * 100).rounded())
    }
}

struct CodexTokenUsage: Equatable, Sendable {
    let fiveHour: Int
    let twentyFourHour: Int
    let weekly: Int

    init(fiveHour: Int = 0, twentyFourHour: Int = 0, weekly: Int = 0) {
        self.fiveHour = max(0, fiveHour)
        self.twentyFourHour = max(0, twentyFourHour)
        self.weekly = max(0, weekly)
    }

    static let zero = CodexTokenUsage()
}

struct CodexUsageSnapshot: Equatable, Sendable {
    let fiveHour: CodexUsageWindow
    let weekly: CodexUsageWindow
    let plan: String?
    let tokenUsage: CodexTokenUsage
}

enum CodexUsageIntegrationError: LocalizedError, Equatable {
    case missingCredentials
    case expiredCredentials
    case httpStatus(Int)
    case malformedResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return String(localized: "No Codex login found — run codex login")
        case .expiredCredentials:
            return String(localized: "Codex login expired — run codex login")
        case .httpStatus(let status):
            return String(localized: "Codex usage request failed (HTTP \(status))")
        case .malformedResponse:
            return String(localized: "Codex returned an unsupported usage response")
        case .transport(let message):
            return String(localized: "Could not refresh Codex usage: \(message)")
        }
    }
}

struct CodexUsageFetcher: Sendable {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let endpoint: URL
    private let authURL: URL

    init(
        endpoint: URL = CodexUsageFetcher.endpoint,
        authURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    ) {
        self.endpoint = endpoint
        self.authURL = authURL
    }

    func fetch() async throws -> CodexUsageSnapshot {
        let token = try accessToken()
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 4

        let remoteUsage: CodexUsageSnapshot
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                throw CodexUsageIntegrationError.expiredCredentials
            }
            guard status == 200 else {
                throw CodexUsageIntegrationError.httpStatus(status)
            }
            remoteUsage = try Self.decode(data: data)
        } catch let error as CodexUsageIntegrationError {
            throw error
        } catch {
            do {
                remoteUsage = try Self.decode(
                    data: try await Self.fetchUsingCurl(token: token, endpoint: endpoint)
                )
            } catch let fallbackError as CodexUsageIntegrationError {
                throw fallbackError
            } catch {
                throw CodexUsageIntegrationError.transport(error.localizedDescription)
            }
        }

        let tokens = await Task.detached(priority: .utility) {
            CodexTokenUsageScanner.scan()
        }.value
        return CodexUsageSnapshot(
            fiveHour: remoteUsage.fiveHour,
            weekly: remoteUsage.weekly,
            plan: remoteUsage.plan,
            tokenUsage: tokens
        )
    }

    private func accessToken() throws -> String {
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              !token.isEmpty else {
            throw CodexUsageIntegrationError.missingCredentials
        }
        return token
    }

    private static func fetchUsingCurl(token: String, endpoint: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            let errorOutput = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = [
                "--silent", "--show-error", "--fail",
                "--config", "-",
                endpoint.absoluteString
            ]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errorOutput
            process.terminationHandler = { completedProcess in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errors = errorOutput.fileHandleForReading.readDataToEndOfFile()
                if completedProcess.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    let message = String(data: errors, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: CodexUsageIntegrationError.transport(
                        message?.isEmpty == false ? message! : "curl fallback failed"
                    ))
                }
            }

            do {
                try process.run()
                let escapedToken = token
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "")
                    .replacingOccurrences(of: "\r", with: "")
                let config = """
                header = "Authorization: Bearer \(escapedToken)"
                header = "Accept: application/json"
                connect-timeout = 15
                max-time = 20

                """
                input.fileHandleForWriting.write(Data(config.utf8))
                try input.fileHandleForWriting.close()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    static func decode(data: Data) throws -> CodexUsageSnapshot {
        guard let response = try? JSONDecoder().decode(UsageResponse.self, from: data),
              let primary = parseWindow(response.rateLimit.primaryWindow) else {
            throw CodexUsageIntegrationError.malformedResponse
        }
        // The service omits `secondary_window` immediately after some weekly
        // resets. Treat that state as a fresh weekly allowance; a later refresh
        // will replace it once the server starts returning the window again.
        let secondary = response.rateLimit.secondaryWindow
            .flatMap(parseWindow)
            ?? CodexUsageWindow(usedFraction: 0, resetAt: nil)
        return CodexUsageSnapshot(
            fiveHour: primary,
            weekly: secondary,
            plan: response.planType,
            tokenUsage: .zero
        )
    }

    private static func parseWindow(_ window: UsageWindow) -> CodexUsageWindow? {
        guard window.usedPercent.isFinite else { return nil }
        return CodexUsageWindow(
            usedFraction: window.usedPercent / 100,
            resetAt: window.resetAt.map(Date.init(timeIntervalSince1970:))
        )
    }

    private struct UsageResponse: Decodable {
        let planType: String?
        let rateLimit: RateLimit

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
        }
    }

    private struct RateLimit: Decodable {
        let primaryWindow: UsageWindow
        let secondaryWindow: UsageWindow?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    private struct UsageWindow: Decodable {
        let usedPercent: Double
        let resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
        }
    }
}
