import Foundation
import os
import ResticSchedulerKit

class ResticRunnerService: ResticRunnerProtocol {
    private typealias TypeLogger = ResticSchedulerKit.TypeLogger<ResticRunnerService>

    private enum Status {
        case preparation, backup, pruning, idle
    }

    private struct Message: Decodable {
        enum CodingKeys: String, CodingKey {
            case messageType = "message_type"
        }

        let messageType: String
    }

    private struct StatusMessage: Decodable {
        enum CodingKeys: String, CodingKey {
            case secondsElapsed = "seconds_elapsed"
            case secondsRemaining = "seconds_remaining"
            case percentDone = "percent_done"
            case totalFiles = "total_files"
            case filesDone = "files_done"
            case totalBytes = "total_bytes"
            case bytesDone = "bytes_done"
            case errorCount = "error_count"
        }

        let secondsElapsed: UInt64?
        let secondsRemaining: UInt64?
        let percentDone: Float64
        let totalFiles: UInt64?
        let filesDone: UInt64?
        let totalBytes: UInt64?
        let bytesDone: UInt64?
        let errorCount: UInt64?
    }

    private struct SummaryMessage: Decodable {
        enum CodingKeys: String, CodingKey {
            case totalDuration = "total_duration"
        }

        let totalDuration: TimeInterval
    }

    private struct ErrorMessage: Decodable {
        struct ResticError: Decodable {
            let message: String
        }

        let error: ResticError
        let item: String?
    }

    private struct RepositoryStatsMessage: Decodable {
        enum CodingKeys: String, CodingKey {
            case totalSize = "total_size"
            case totalBlobCount = "total_blob_count"
            case snapshotsCount = "snapshots_count"
        }

        let totalSize: UInt64
        let totalBlobCount: UInt64
        let snapshotsCount: UInt64
    }

    private struct VerboseStatusMessage: Decodable {
        enum CodingKeys: String, CodingKey {
            case action, item
            case dataSize = "data_size"
            case dataSizeInRepo = "data_size_in_repo"
        }

        let action: String
        let item: String?
        let dataSize: UInt64?
        let dataSizeInRepo: UInt64?
    }

    private enum HookType: String, CustomStringConvertible {
        case beforeBackup = "before_backup"
        case onSuccess = "on_success"
        case onFailure = "on_failure"

        var description: String {
            switch self {
            case .beforeBackup:
                "before backup"
            case .onSuccess:
                "on success"
            case .onFailure:
                "on failure"
            }
        }
    }

    private static let status = OSAllocatedUnfairLock(initialState: Status.idle)
    private static let process = OSAllocatedUnfairLock<Process?>(initialState: nil)
    private static let logPadding = String(repeating: " ", count: 16)
    private static let brewBinaryPaths = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]
    private static let appleBackupExclusionQuery = "com_apple_backup_excludeItem = 'com.apple.backupd'"
    private static let repositoryStatsTimeout: TimeInterval = 15 * 60
    private static let largeChangedFileLogThresholdBytes: UInt64 = 100 * 1024 * 1024

    private let connection: NSXPCConnection

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    private static func brewBinaryURL() -> URL? {
        for path in brewBinaryPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(filePath: path)
        }

        return nil
    }

    private static func brewfilePath(for homeDirectory: String) -> String {
        "\(homeDirectory)/.config/brew/Brewfile"
    }

    private static func prepareSmartBackupFiles(for homeDirectories: [String], loggingTo logURL: URL) -> [String] {
        guard !homeDirectories.isEmpty else {
            return []
        }

        guard let brewBinaryURL = brewBinaryURL() else {
            try? "\(logPadding)Homebrew not found; skipping Brewfile generation\n".append(to: logURL, encoding: .utf8)
            return []
        }

        return homeDirectories.compactMap { dumpBrewfile(using: brewBinaryURL, for: $0, loggingTo: logURL) }
    }

    private static func dumpBrewfile(using brewBinaryURL: URL, for homeDirectory: String, loggingTo logURL: URL) -> String? {
        let brewfilePath = brewfilePath(for: homeDirectory)
        let brewfileURL = URL(filePath: brewfilePath)
        do {
            try FileManager.default.createDirectory(at: brewfileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            let process = Process()
            process.qualityOfService = .utility
            process.executableURL = brewBinaryURL
            process.arguments = [
                "bundle",
                "dump",
                "--file=\(brewfilePath)",
                "--force",
            ]
            process.environment = ProcessInfo.processInfo.environment.merging(["HOME": homeDirectory]) { _, new in new }

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            try "\(logPadding)Updating Homebrew bundle file: \(brewfilePath)\n".append(to: logURL, encoding: .utf8)
            try process.run()
            process.waitUntilExit()

            let output = String(contentsOfPipe: outputPipe)
            guard process.terminationStatus == 0 else {
                try "\(logPadding)brew bundle dump failed with code \(process.terminationStatus): \(output)\n".append(to: logURL, encoding: .utf8)
                return (try? brewfileURL.checkResourceIsReachable()) == true ? brewfilePath : nil
            }

            if !output.isEmpty {
                try output.prefixingLines(with: "\(logPadding)brew: ").append(to: logURL, encoding: .utf8)
            }
            return brewfilePath
        } catch {
            try? "\(logPadding)Unable to update Homebrew bundle file at \(brewfilePath): \(error.localizedDescription)\n".append(to: logURL, encoding: .utf8)
            return (try? brewfileURL.checkResourceIsReachable()) == true ? brewfilePath : nil
        }
    }

    private static func appleSpecifiedExcludes(for homeDirectories: [String], loggingTo logURL: URL) -> [String] {
        guard !homeDirectories.isEmpty else {
            return []
        }

        guard let output = runAppleSpecifiedExclusionsQuery(loggingTo: logURL) else {
            return []
        }

        let normalizedHomeDirectories = homeDirectories.map { normalizedPath($0) }
        let excludes = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { normalizedPath(String($0)) }
            .filter { candidatePath in normalizedHomeDirectories.contains { homeDirectory in path(candidatePath, isInside: homeDirectory) } }
            .appendingUnique([])

        do {
            try "\(logPadding)Apple-specified exclusions: \(excludes.count) path\(excludes.count == 1 ? "" : "s")\n".append(to: logURL, encoding: .utf8)
        } catch {
            TypeLogger.function().warning("Couldn't write Apple-specified exclusions log: \(error.localizedDescription, privacy: .public)")
        }
        return excludes
    }

    private static func runAppleSpecifiedExclusionsQuery(loggingTo logURL: URL) -> String? {
        let process = Process()
        process.qualityOfService = .utility
        process.executableURL = URL(filePath: "/usr/bin/mdfind")
        process.arguments = [appleBackupExclusionQuery]

        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "\(Bundle.main.bundleIdentifier!).apple-backup-exclusions.stdout.\(UUID().uuidString)", directoryHint: .notDirectory)
        let errorURL = FileManager.default.temporaryDirectory
            .appending(path: "\(Bundle.main.bundleIdentifier!).apple-backup-exclusions.stderr.\(UUID().uuidString)", directoryHint: .notDirectory)
        _ = FileManager.default.createFile(atPath: outputURL.path(percentEncoded: false), contents: nil)
        _ = FileManager.default.createFile(atPath: errorURL.path(percentEncoded: false), contents: nil)
        guard
            let outputFileHandle = try? FileHandle(forWritingTo: outputURL),
            let errorFileHandle = try? FileHandle(forWritingTo: errorURL)
        else {
            try? "\(logPadding)Apple-specified exclusions unavailable; couldn't open temporary output files\n".append(to: logURL, encoding: .utf8)
            return nil
        }
        defer {
            outputFileHandle.closeFile()
            errorFileHandle.closeFile()
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        process.standardOutput = outputFileHandle
        process.standardError = errorFileHandle

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? "\(logPadding)Apple-specified exclusions unavailable; mdfind failed to start: \(error.localizedDescription)\n".append(to: logURL, encoding: .utf8)
            return nil
        }

        let output = ((try? String(contentsOf: outputURL, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let errorOutput = ((try? String(contentsOf: errorURL, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            try? "\(logPadding)Apple-specified exclusions unavailable; mdfind exited \(process.terminationStatus)\(errorOutput.isEmpty ? "" : " - \(errorOutput)")\n".append(to: logURL, encoding: .utf8)
            return nil
        }

        if output.isEmpty {
            try? "\(logPadding)Apple-specified exclusions: no paths returned by mdfind\n".append(to: logURL, encoding: .utf8)
            return nil
        }
        return output
    }

    private static func normalizedPath(_ path: String) -> String {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func path(_ path: String, isInside directory: String) -> Bool {
        path == directory || path.hasPrefix("\(directory)/")
    }

    private static func formattedDuration(from startedAt: Date, to finishedAt: Date) -> String {
        formattedDuration(finishedAt.timeIntervalSince(startedAt))
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        let hours = seconds / 3600
        let minutes = seconds % 3600 / 60
        let remainingSeconds = seconds % 60

        var components = [String]()
        if hours > 0 {
            components.append("\(hours)h")
        }
        if minutes > 0 || hours > 0 {
            components.append("\(minutes)m")
        }
        components.append("\(remainingSeconds)s")
        return components.joined(separator: " ")
    }

    func version(binary: String?, reply: @escaping (String?, Error?) -> Void) {
        let process = Process()
        process.qualityOfService = .userInitiated
        guard let executableURL = resticURL(forBinary: binary) else {
            reply(nil, ProcessError.missingRestic)
            return
        }

        process.executableURL = executableURL
        process.arguments = ["version"]
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                reply(String(contentsOfPipe: standardOutput), nil)
            } else {
                let error = ProcessError.abnormalTermination(terminationStatus: process.terminationStatus, standardError: String(contentsOfPipe: standardError))
                TypeLogger.function().error("\(error.localizedDescription, privacy: .public)")
                reply(nil, error)
            }
        } catch {
            TypeLogger.function().error("\(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func repositoryStats(binary: String?, repository: String, environment: [String: String], logURL: URL, reply: @escaping (RepositoryStats?, Error?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.qualityOfService = .utility
            guard let executableURL = resticURL(forBinary: binary) else {
                reply(nil, ProcessError.missingRestic)
                return
            }

            process.executableURL = executableURL
            let arguments = [
                "--json",
                "--no-lock",
                "stats",
                "--mode", "raw-data",
            ]
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, new in new }
                .merging(["RESTIC_REPOSITORY": repository]) { _, new in new }
            let command = ([executableURL.path] + arguments)
                .map(Self.shellQuoted)
                .joined(separator: " ")
            Self.writeRepositoryStatsLog("repository stats command: \(command)\n", to: logURL)
            Self.writeRepositoryStatsLog("repository stats repository: \(repository)\n", to: logURL)

            let standardOutput = Pipe()
            let standardError = Pipe()
            process.standardOutput = standardOutput
            process.standardError = standardError
            let outputLock = NSLock()
            var outputData = Data()
            var errorData = Data()
            let processFinished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in
                processFinished.signal()
            }
            standardOutput.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }

                outputLock.withLock {
                    outputData.append(data)
                }
            }
            standardError.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }

                outputLock.withLock {
                    errorData.append(data)
                }
            }
            do {
                try process.run()
                let timedOut = processFinished.wait(timeout: .now() + Self.repositoryStatsTimeout) == .timedOut
                if timedOut {
                    Self.writeRepositoryStatsLog("repository stats timed out after \(Self.formattedDuration(Self.repositoryStatsTimeout)); terminating process\n", to: logURL)
                    process.terminate()
                    _ = processFinished.wait(timeout: .now() + 10)
                }
                standardOutput.fileHandleForReading.readabilityHandler = nil
                standardError.fileHandleForReading.readabilityHandler = nil
                if !process.isRunning {
                    outputLock.withLock {
                        outputData.append(standardOutput.fileHandleForReading.readDataToEndOfFile())
                        errorData.append(standardError.fileHandleForReading.readDataToEndOfFile())
                    }
                }

                let output = outputLock.withLock { String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
                let errorOutput = outputLock.withLock { String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
                Self.writeRepositoryStatsOutputLog(name: "stdout", output: output, to: logURL)
                Self.writeRepositoryStatsOutputLog(name: "stderr", output: errorOutput, to: logURL)
                if timedOut {
                    let error = ProcessError.abnormalTermination(terminationStatus: -1, standardError: "Repository stats timed out after \(Self.formattedDuration(Self.repositoryStatsTimeout))")
                    TypeLogger.function().error("\(error.localizedDescription, privacy: .public)")
                    reply(nil, error)
                } else if process.terminationStatus == 0, let data = output.data(using: .utf8) {
                    do {
                        let stats = try JSONDecoder().decode(RepositoryStatsMessage.self, from: data)
                        reply(RepositoryStats(fileCount: stats.totalBlobCount, snapshotCount: stats.snapshotsCount, totalBytes: stats.totalSize, updatedAt: Date()), nil)
                    } catch {
                        TypeLogger.function().error("Couldn't decode repository stats: \(error.localizedDescription, privacy: .public)")
                        reply(nil, error)
                    }
                } else {
                    let error = ProcessError.abnormalTermination(terminationStatus: process.terminationStatus, standardError: errorOutput)
                    TypeLogger.function().error("\(error.localizedDescription, privacy: .public)")
                    reply(nil, error)
                }
            } catch {
                TypeLogger.function().error("\(error.localizedDescription, privacy: .public)")
                reply(nil, error)
            }
        }
    }

    func forgetPrune(binary: String?, repository: String, environment: [String: String], logURL: URL, reply: @escaping (Error?) -> Void) {
        let idle = Self.status.withLock { value in
            if value != .idle {
                reply(value == .preparation ? BackupError.preparationInProcess : BackupError.backupInProcess)
                return false
            }

            value = .pruning
            return true
        }
        if !idle {
            return
        }

        DispatchQueue.global(qos: .utility).async {
            defer { Self.status.withLock { value in value = .idle } }
            guard let executableURL = resticURL(forBinary: binary) else {
                reply(ProcessError.missingRestic)
                return
            }

            let arguments = [
                "forget",
                "--keep-within-hourly", "48h",
                "--keep-within-daily", "30d",
                "--keep-within-weekly", "6m",
                "--keep-within-monthly", "2y",
                "--prune",
            ]
            let unlockArguments = ["unlock"]
            let processEnvironment = ProcessInfo.processInfo.environment
                .merging(environment) { _, new in new }
                .merging(["RESTIC_REPOSITORY": repository]) { _, new in new }
            let startedAt = Date()

            do {
                try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "\(startedAt.formatted(.rfc3164)) Starting repository forget/prune...\n".append(to: logURL, encoding: .utf8)
                try "\(Self.logPadding)repository forget/prune command: \(Self.commandString(executableURL: executableURL, arguments: arguments))\n".append(to: logURL, encoding: .utf8)
                try "\(Self.logPadding)repository forget/prune repository: \(repository)\n".append(to: logURL, encoding: .utf8)
            } catch {
                TypeLogger.function().warning("Couldn't write repository forget/prune log: \(error.localizedDescription, privacy: .public)")
            }

            do {
                var result = try Self.runResticProcess(executableURL: executableURL, arguments: arguments, environment: processEnvironment)
                Self.writeRepositoryForgetPruneOutputLog(name: "stdout", output: result.standardOutput, to: logURL)
                Self.writeRepositoryForgetPruneOutputLog(name: "stderr", output: result.standardError, to: logURL)

                if result.terminationStatus == 11 {
                    try "\(Self.logPadding)repository forget/prune found a repository lock; running unlock for stale locks\n".append(to: logURL, encoding: .utf8)
                    try "\(Self.logPadding)repository unlock command: \(Self.commandString(executableURL: executableURL, arguments: unlockArguments))\n".append(to: logURL, encoding: .utf8)
                    let unlockResult = try Self.runResticProcess(executableURL: executableURL, arguments: unlockArguments, environment: processEnvironment)
                    Self.writeRepositoryForgetPruneOutputLog(name: "unlock stdout", output: unlockResult.standardOutput, to: logURL)
                    Self.writeRepositoryForgetPruneOutputLog(name: "unlock stderr", output: unlockResult.standardError, to: logURL)
                    if unlockResult.terminationStatus == 0 {
                        try "\(Self.logPadding)repository unlock succeeded; retrying forget/prune once\n".append(to: logURL, encoding: .utf8)
                        try "\(Self.logPadding)repository forget/prune retry command: \(Self.commandString(executableURL: executableURL, arguments: arguments))\n".append(to: logURL, encoding: .utf8)
                        result = try Self.runResticProcess(executableURL: executableURL, arguments: arguments, environment: processEnvironment)
                        Self.writeRepositoryForgetPruneOutputLog(name: "retry stdout", output: result.standardOutput, to: logURL)
                        Self.writeRepositoryForgetPruneOutputLog(name: "retry stderr", output: result.standardError, to: logURL)
                    } else {
                        result = unlockResult
                    }
                }

                let finishedAt = Date()
                let duration = Self.formattedDuration(from: startedAt, to: finishedAt)
                if result.terminationStatus == 0 {
                    try "\(finishedAt.formatted(.rfc3164)) Finished repository forget/prune in \(duration)\n\n".append(to: logURL, encoding: .utf8)
                    reply(nil)
                } else {
                    let error = ProcessError.abnormalTermination(terminationStatus: result.terminationStatus, standardError: result.standardError)
                    TypeLogger.function().error("\(error.localizedDescription, privacy: .public)")
                    try "\(finishedAt.formatted(.rfc3164)) Repository forget/prune failed after \(duration): \(error.localizedDescription)\n\n".append(to: logURL, encoding: .utf8)
                    reply(error)
                }
            } catch {
                TypeLogger.function().error("\(error.localizedDescription, privacy: .public)")
                do {
                    let finishedAt = Date()
                    try "\(finishedAt.formatted(.rfc3164)) Repository forget/prune failed after \(Self.formattedDuration(from: startedAt, to: finishedAt)): \(error.localizedDescription)\n\n".append(to: logURL, encoding: .utf8)
                } catch {
                    TypeLogger.function().warning("Couldn't write repository forget/prune failure log: \(error.localizedDescription, privacy: .public)")
                }
                reply(error)
            }
        }
    }

    private struct ProcessResult {
        let terminationStatus: Int32
        let standardOutput: String
        let standardError: String
    }

    private static func runResticProcess(executableURL: URL, arguments: [String], environment: [String: String]) throws -> ProcessResult {
        let process = Process()
        process.qualityOfService = .utility
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        let outputLock = NSLock()
        var outputData = Data()
        var errorData = Data()
        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            outputLock.withLock {
                outputData.append(data)
            }
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            outputLock.withLock {
                errorData.append(data)
            }
        }

        try process.run()
        Self.process.withLock { value in value = process }
        defer {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            Self.process.withLock { value in
                if value === process {
                    value = nil
                }
            }
        }
        process.waitUntilExit()
        outputLock.withLock {
            outputData.append(standardOutput.fileHandleForReading.readDataToEndOfFile())
            errorData.append(standardError.fileHandleForReading.readDataToEndOfFile())
        }
        return ProcessResult(
            terminationStatus: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            standardError: String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func commandString(executableURL: URL, arguments: [String]) -> String {
        ([executableURL.path] + arguments)
            .map(shellQuoted)
            .joined(separator: " ")
    }

    private static func writeRepositoryForgetPruneOutputLog(name: String, output: String, to logURL: URL) {
        if output.isEmpty {
            writeRepositoryForgetPruneLog("repository forget/prune \(name): <empty>\n", to: logURL)
        } else {
            writeRepositoryForgetPruneLog("repository forget/prune \(name):\n\(output.prefixingLines(with: "\(logPadding)  "))", to: logURL)
        }
    }

    private static func writeRepositoryForgetPruneLog(_ value: String, to logURL: URL) {
        do {
            try "\(logPadding)\(value)".append(to: logURL, encoding: .utf8)
        } catch {
            TypeLogger.function().warning("Couldn't write repository forget/prune log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func writeRepositoryStatsOutputLog(name: String, output: String, to logURL: URL) {
        if output.isEmpty {
            writeRepositoryStatsLog("repository stats \(name): <empty>\n", to: logURL)
        } else {
            writeRepositoryStatsLog("repository stats \(name):\n\(output.prefixingLines(with: "\(logPadding)  "))", to: logURL)
        }
    }

    private static func writeRepositoryStatsLog(_ value: String, to logURL: URL) {
        do {
            try "\(logPadding)\(value)".append(to: logURL, encoding: .utf8)
        } catch {
            TypeLogger.function().warning("Couldn't write repository stats log: \(error.localizedDescription, privacy: .public)")
        }
    }

    func backup(binary: String?, options: BackupOptions, reply: @escaping (Error?, [String]) -> Void) {
        let idle = Self.status.withLock { value in
            if value != .idle {
                reply(value == .preparation ? BackupError.preparationInProcess : BackupError.backupInProcess, [])
                return false
            }

            value = .preparation
            return true
        }
        if !idle {
            return
        }

        defer { Self.status.withLock { value in value = .idle }}
        let resticScheduler = OSAllocatedUnfairLock<ResticSchedulerProtocol?>(initialState: nil)
        resticScheduler.withLock { value in
            value = connection.activateRemoteObjectProxyWithErrorHandler(protocol: ResticSchedulerProtocol.self) { error in
                TypeLogger.function().warning("Error in Restic Runner <-> Restic Scheduler XPC: \(error.localizedDescription, privacy: .public)")
                resticScheduler.withLock { value in value = nil }
            }
        }
        let process = Process()
        process.qualityOfService = .background
        guard let executableURL = resticURL(forBinary: binary) else {
            reply(ProcessError.missingRestic, [])
            return
        }

        process.executableURL = executableURL
        process.environment = ProcessInfo.processInfo.environment
            .merging(options.environment) { _, new in new }
            .merging(["RESTIC_PROGRESS_FPS": "0.2"]) { _, new in new }
        let startedAt = Date()
        do {
            try FileManager.default.createDirectory(at: options.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "\(startedAt.formatted(.rfc3164)) Starting backup...\n".append(to: options.logURL, encoding: .utf8)
            let smartBackupIncludes = Self.prepareSmartBackupFiles(for: options.smartBackupHomeDirectories, loggingTo: options.logURL)
            let includes = options.includes.appendingUnique(smartBackupIncludes)
            let appleSpecifiedExcludes = Self.appleSpecifiedExcludes(for: options.smartBackupHomeDirectories, loggingTo: options.logURL)
            let excludes = options.excludes.appendingUnique(appleSpecifiedExcludes)
            try "\(Self.logPadding)includes:\n".append(to: options.logURL, encoding: .utf8)
            for include in includes {
                try "\(Self.logPadding)  \(include)\n".append(to: options.logURL, encoding: .utf8)
            }
            try "\(Self.logPadding)excludes:\n".append(to: options.logURL, encoding: .utf8)
            for exclude in excludes {
                try "\(Self.logPadding)  \(exclude)\n".append(to: options.logURL, encoding: .utf8)
            }
            if let beforeBackup = options.beforeBackup {
                runHook(beforeBackup, ofType: .beforeBackup, loggingTo: options.logURL)
            }
            let cacheURL = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: Bundle.main.bundleIdentifier!, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
            let supportURL = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: Bundle.main.bundleIdentifier!, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
            let includesURL = supportURL.appending(path: "includes", directoryHint: .notDirectory)
            let excludesURL = supportURL.appending(path: "excludes", directoryHint: .notDirectory)
            try includes.joined(separator: "\n").write(to: includesURL, atomically: true, encoding: .utf8)
            try excludes.joined(separator: "\n").write(to: excludesURL, atomically: true, encoding: .utf8)
            process.arguments = [
                "--json",
                "--verbose=2",
                "--cache-dir", cacheURL.path(percentEncoded: false), "--cleanup-cache",
                "backup",
            ] + options.arguments + [
                "--files-from", includesURL.path(percentEncoded: false),
                "--exclude-file", excludesURL.path(percentEncoded: false),
            ]
            let standardOutput = Pipe()
            let standardError = Pipe()
            var standardErrorOutput = ""
            process.standardOutput = standardOutput
            process.standardError = standardError
            var summary: String?
            var activeDuration: TimeInterval?
            var standardOutputBuffer = Data()
            var standardErrorBuffer = Data()
            var didLogJSONStreamStart = false
            let permissionDeniedItems = OSAllocatedUnfairLock<Set<String>>(initialState: [])
            let decoder = JSONDecoder()

            func logResticJSONLine(_ data: Data) {
                do {
                    if !didLogJSONStreamStart {
                        try "\(Self.logPadding)restic JSON stream started\n".append(to: options.logURL, encoding: .utf8)
                        didLogJSONStreamStart = true
                    }
                    let line = String(data: data, encoding: .utf8) ?? "<non-utf8 JSON output>"
                    try "\(Self.logPadding)restic JSON: \(line)\n".append(to: options.logURL, encoding: .utf8)
                } catch {
                    TypeLogger.function().warning("Couldn't write restic JSON log: \(error.localizedDescription, privacy: .public)")
                }
            }

            func processPermissionDeniedErrorLine(_ data: Data) {
                guard let error = try? decoder.decode(ErrorMessage.self, from: data),
                      error.error.message.localizedCaseInsensitiveContains("permission denied"),
                      let item = error.item?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !item.isEmpty
                else {
                    return
                }

                let inserted = permissionDeniedItems.withLock { value in
                    value.insert(item).inserted
                }
                if inserted {
                    do {
                        try "\(Self.logPadding)permission-denied item detected: \(item)\n".append(to: options.logURL, encoding: .utf8)
                    } catch {
                        TypeLogger.function().warning("Couldn't write permission-denied detection log: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }

            func processVerboseStatusLine(_ data: Data) {
                guard let status = try? decoder.decode(VerboseStatusMessage.self, from: data),
                      status.action == "new" || status.action == "modified",
                      let item = status.item?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !item.isEmpty,
                      let dataSize = status.dataSize,
                      dataSize >= Self.largeChangedFileLogThresholdBytes
                else {
                    return
                }

                let action = status.action == "new" ? "new" : "changed"
                let size = dataSize.formatted(.byteCount(style: .file))
                let repoSize = status.dataSizeInRepo.map { ", repo delta \($0.formatted(.byteCount(style: .file)))" } ?? ""
                do {
                    try "\(Self.logPadding)large \(action) file: \(size)\(repoSize): \(item)\n".append(to: options.logURL, encoding: .utf8)
                } catch {
                    TypeLogger.function().warning("Couldn't write large changed file log: \(error.localizedDescription, privacy: .public)")
                }
            }

            func processStandardOutputLine(_ data: Data) {
                if let message = try? decoder.decode(Message.self, from: data) {
                    switch message.messageType {
                    case "status":
                        logResticJSONLine(data)
                        if let status = try? decoder.decode(StatusMessage.self, from: data) {
                            resticScheduler.withLock {
                                value in value?.progressDidUpdate(
                                    percentDone: status.percentDone,
                                    bytesDone: status.bytesDone ?? 0,
                                    totalBytes: status.totalBytes ?? 0,
                                    secondsElapsed: status.secondsElapsed ?? 0,
                                    secondsRemaining: status.secondsRemaining ?? 0,
                                    filesDone: status.filesDone ?? 0,
                                    totalFiles: status.totalFiles ?? 0,
                                    errorCount: status.errorCount ?? 0
                                )
                            }
                        } else {
                            let value = String(data: data, encoding: .utf8)
                            TypeLogger.function().warning("Invalid status message: \(value ?? "<no value>", privacy: .public)")
                        }
                    case "summary":
                        logResticJSONLine(data)
                        summary = String(data: data, encoding: .utf8)
                        activeDuration = (try? decoder.decode(SummaryMessage.self, from: data))?.totalDuration
                        resticScheduler.withLock { value in value?.backupDidFinishCopying() }
                    case "error":
                        logResticJSONLine(data)
                        processPermissionDeniedErrorLine(data)
                    case "verbose_status":
                        processVerboseStatusLine(data)
                    default:
                        logResticJSONLine(data)
                        break
                    }
                } else {
                    logResticJSONLine(data)
                    let value = String(data: data, encoding: .utf8)
                    TypeLogger.function().warning("Unexpected message: \(value ?? "<no value>", privacy: .public)")
                }
            }
            standardOutput.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }

                standardOutputBuffer.append(data)
                while let lineEnd = standardOutputBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = standardOutputBuffer[..<lineEnd]
                    standardOutputBuffer.removeSubrange(...lineEnd)
                    if !line.isEmpty {
                        processStandardOutputLine(Data(line))
                    }
                }
            }
            standardError.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }

                let value = String(data: data, encoding: .utf8)
                if let value {
                    standardErrorOutput += value
                }
                standardErrorBuffer.append(data)
                while let lineEnd = standardErrorBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = standardErrorBuffer[..<lineEnd]
                    standardErrorBuffer.removeSubrange(...lineEnd)
                    if !line.isEmpty {
                        processPermissionDeniedErrorLine(Data(line))
                    }
                }
                do {
                    try value?
                        .prefixingLines(with: Self.logPadding)
                        .append(to: options.logURL, encoding: .utf8)
                } catch {
                    TypeLogger.function().warning("Couldn't write log: \(error.localizedDescription, privacy: .public)")
                }
            }
            try process.run()
            Self.process.withLock { value in value = process }
            defer {
                Self.process.withLock { value in
                    if value === process {
                        value = nil
                    }
                }
            }
            process.waitUntilExit()
            if !standardOutputBuffer.isEmpty {
                processStandardOutputLine(standardOutputBuffer)
                standardOutputBuffer.removeAll()
            }
            if !standardErrorBuffer.isEmpty {
                processPermissionDeniedErrorLine(standardErrorBuffer)
                standardErrorBuffer.removeAll()
            }
            let deniedItems = permissionDeniedItems.withLock { $0.sorted() }
            if !deniedItems.isEmpty {
                resticScheduler.withLock { value in value?.backupDidEncounterPermissionDeniedItems(deniedItems) }
            }
            if process.terminationStatus == 0 || process.terminationStatus == 3 {
                if summary != nil {
                    do {
                        try FileManager.default.createDirectory(at: options.summaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try summary!.write(to: options.summaryURL, atomically: true, encoding: .utf8)
                    } catch {
                        TypeLogger.function().warning("Couldn't write summary: \(error.localizedDescription, privacy: .public)")
                    }
                }
                if let onSuccess = options.onSuccess {
                    runHook(onSuccess, ofType: .onSuccess, loggingTo: options.logURL)
                }
                do {
                    let finishedAt = Date()
                    let wallClockDuration = Self.formattedDuration(from: startedAt, to: finishedAt)
                    let duration = activeDuration.map { "\(Self.formattedDuration($0)) active (\(wallClockDuration) wall clock)" } ?? wallClockDuration
                    try "\(finishedAt.formatted(.rfc3164)) Finished backup in \(duration)\n\n".append(to: options.logURL, encoding: .utf8)
                } catch {
                    TypeLogger.function().warning("Couldn't write log: \(error.localizedDescription, privacy: .public)")
                }
                reply(nil, deniedItems)
            } else {
                let error = ProcessError.abnormalTermination(terminationStatus: process.terminationStatus, standardError: standardErrorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
                TypeLogger.function().error("\(error.localizedDescription, privacy: .public)")
                if let onFailure = options.onFailure {
                    runHook(onFailure, ofType: .onFailure, loggingTo: options.logURL)
                }
                do {
                    let finishedAt = Date()
                    try "\(finishedAt.formatted(.rfc3164)) Backup failed after \(Self.formattedDuration(from: startedAt, to: finishedAt))\n\n".append(to: options.logURL, encoding: .utf8)
                } catch {
                    TypeLogger.function().warning("Couldn't write log: \(error.localizedDescription, privacy: .public)")
                }
                reply(error, deniedItems)
            }
        } catch {
            TypeLogger.function().error("\(error.localizedDescription, privacy: .public)")
            do {
                let finishedAt = Date()
                try "\(finishedAt.formatted(.rfc3164)) Backup failed after \(Self.formattedDuration(from: startedAt, to: finishedAt)): \(error.localizedDescription)\n\n".append(to: options.logURL, encoding: .utf8)
            } catch {
                TypeLogger.function().warning("Couldn't write log: \(error.localizedDescription, privacy: .public)")
            }
            reply(error, [])
        }
    }

    func stop(reply: @escaping (Error?) -> Void) {
        Self.process.withLock { value in
            guard value != nil else {
                let error = BackupError.backupNotRunning
                TypeLogger.function().error("\(error.localizedDescription, privacy: .public)")
                reply(error)
                return
            }

            value!.terminate()
            reply(nil)
        }
    }

    func includesBuiltIn(reply: @escaping (Bool) -> Void) {
        reply(resticURL(forBinary: nil) != nil)
    }

    private func runHook(_ hook: String, ofType type: HookType, loggingTo logURL: URL) {
        do {
            try "\(Self.logPadding)Invoking \(type) hook...\n".append(to: logURL, encoding: .utf8)
        } catch {
            TypeLogger.function().warning("Couldn't write log: \(error.localizedDescription, privacy: .public)")
        }
        let process = Process()
        process.qualityOfService = .background
        process.executableURL = URL(fileURLWithPath: hook)
        process.arguments = [type.rawValue]
        process.environment = ProcessInfo.processInfo.environment
        process.standardOutput = nil
        let standardError = Pipe()
        var standardErrorOutput = ""
        process.standardError = standardError
        do {
            standardError.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }

                let value = String(data: data, encoding: .utf8)
                if let value {
                    standardErrorOutput += value
                }
                do {
                    try value?
                        .prefixingLines(with: Self.logPadding)
                        .append(to: logURL, encoding: .utf8)
                } catch {
                    TypeLogger.function().warning("Couldn't write log: \(error.localizedDescription, privacy: .public)")
                }
            }
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let error = ProcessError.abnormalTermination(terminationStatus: process.terminationStatus, standardError: standardErrorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
                TypeLogger.function().error("Failed to run \(type) hook: \(error.localizedDescription, privacy: .public)")
            }
        } catch {
            TypeLogger.function().error("\(error.localizedDescription, privacy: .public)")
        }
    }
}

func resticURL(forBinary binary: String?) -> URL? {
    guard let binary, !binary.isEmpty else {
        return Bundle.main.url(forResource: "restic", withExtension: "")
    }

    return URL(fileURLWithPath: binary)
}
