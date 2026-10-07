//
//  MacmonUpdater.swift
//  MacMonMenu
//

import Foundation
import os

nonisolated struct MacmonUpdate: Equatable, Sendable {
    let installed: String
    let latest: String
}

nonisolated enum MacmonUpgradeOutcome: Sendable {
    case success
    case failure(String)
}

/// Checks Homebrew for a newer macmon formula and upgrades that formula only.
///
/// Explicitly nonisolated: the app's default actor is the main thread, and these
/// Homebrew calls must not block the menu bar.
nonisolated enum MacmonUpdater {

    private static let formula = "macmon"
    private static let checkTimeout: TimeInterval = 180
    private static let upgradeTimeout: TimeInterval = 600

    /// Asks Homebrew whether macmon is outdated.
    ///
    /// Homebrew refreshes its formula index on its own schedule during this call.
    /// A missing brew install, a pinned formula, or an unreadable result means there
    /// is nothing to offer.
    static func checkForUpdate() -> MacmonUpdate? {
        guard let output = runBrew(
            arguments: ["outdated", "--formula", "--json=v2", formula],
            timeout: checkTimeout
        ) else {
            return nil
        }
        return parseUpdate(from: output.stdout)
    }

    static func upgrade() -> MacmonUpgradeOutcome {
        guard let output = runBrew(
            arguments: ["upgrade", "--formula", formula],
            timeout: upgradeTimeout
        ) else {
            return .failure("Homebrew is not installed.")
        }
        if output.timedOut {
            return .failure("Timed out waiting for Homebrew to upgrade macmon.")
        }
        let text = output.stdout + "\n" + output.stderr
        if output.status == 0 || text.contains("already installed") {
            return .success
        }
        return .failure(failureSummary(output))
    }

    // MARK: - Parsing

    static func parseUpdate(from stdout: String) -> MacmonUpdate? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let formulae: [[String: Any]]
        if let entries = json as? [[String: Any]] {
            formulae = entries
        } else if let object = json as? [String: Any],
                  let entries = object["formulae"] as? [[String: Any]] {
            formulae = entries
        } else {
            return nil
        }

        guard let item = formulae.first(where: { ($0["name"] as? String) == formula }) else {
            return nil
        }
        if (item["pinned"] as? Bool) == true {
            return nil
        }

        let installedVersions = item["installed_versions"] as? [String] ?? []
        guard let latest = item["current_version"] as? String, !latest.isEmpty else {
            return nil
        }
        let installed = installedVersions.last ?? "unknown"
        guard installed != latest else { return nil }
        return MacmonUpdate(installed: installed, latest: latest)
    }

    // MARK: - Homebrew process

    private struct CommandOutput {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    private static var brewExecutable: String? {
        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func brewEnvironment(brewPath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let brewBin = (brewPath as NSString).deletingLastPathComponent
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(brewBin):/usr/bin:/bin:\(path)"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_COLOR"] = "0"
        env["HOMEBREW_NO_EMOJI"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }

    private static func runBrew(arguments: [String], timeout: TimeInterval) -> CommandOutput? {
        guard let brew = brewExecutable else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = arguments
        process.environment = brewEnvironment(brewPath: brew)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return CommandOutput(status: 1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            guard process.isRunning else { return }
            timedOut.withLock { $0 = true }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        timer.resume()
        defer { timer.cancel() }

        let stdoutReady = DispatchSemaphore(value: 0)
        let stderrReady = DispatchSemaphore(value: 0)
        let stdoutData = OSAllocatedUnfairLock(initialState: Data())
        let stderrData = OSAllocatedUnfairLock(initialState: Data())
        DispatchQueue.global().async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutData.withLock { $0 = data }
            stdoutReady.signal()
        }
        DispatchQueue.global().async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrData.withLock { $0 = data }
            stderrReady.signal()
        }

        process.waitUntilExit()
        stdoutReady.wait()
        stderrReady.wait()

        let stdout = stdoutData.withLock { $0 }
        let stderr = stderrData.withLock { $0 }
        return CommandOutput(
            status: process.terminationStatus,
            stdout: String(data: stdout, encoding: .utf8) ?? "",
            stderr: String(data: stderr, encoding: .utf8) ?? "",
            timedOut: timedOut.withLock { $0 }
        )
    }

    private static func failureSummary(_ output: CommandOutput) -> String {
        let lines = (output.stderr + "\n" + output.stdout)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let error = lines.last(where: { $0.hasPrefix("Error:") }) {
            return String(error.prefix(500))
        }
        if let last = lines.last {
            return String(last.prefix(500))
        }
        return "brew upgrade macmon exited with status \(output.status)."
    }
}
