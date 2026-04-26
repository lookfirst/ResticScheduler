import Combine
import os
import ResticSchedulerKit
import SwiftUI
import UserNotifications

class ResticScheduler: ObservableObject, ResticSchedulerProtocol {
    enum Status {
        case idle, preparation, backup, finishing, stopping
    }

    private class Runner: ResticRunnerProtocol {
        private static let serviceName = Bundle.main.object(forInfoDictionaryKey: "APP_RESTIC_RUNNER_SERVICE_NAME") as! String

        var scheduler: ResticSchedulerProtocol?

        func version(binary: String?, reply: @escaping (String?, Error?) -> Void) {
            let replyOnce = withCallingReplyOnce(reply)
            activateRemoteObjectProxyWithErrorHandler { error in replyOnce(nil, error) }?.version(binary: binary, reply: replyOnce)
        }

        func backup(binary: String?, options: BackupOptions, reply: @escaping (Error?) -> Void) {
            let replyOnce = withCallingReplyOnce(reply)
            activateRemoteObjectProxyWithErrorHandler(exporting: ResticSchedulerProtocol.self, via: scheduler!) { error in replyOnce(error) }?.backup(binary: binary, options: options, reply: replyOnce)
        }

        func stop(reply: @escaping (Error?) -> Void) {
            let replyOnce = withCallingReplyOnce(reply)
            activateRemoteObjectProxyWithErrorHandler { error in replyOnce(error) }?.stop(reply: replyOnce)
        }

        func includesBuiltIn(reply: @escaping (Bool) -> Void) {
            let replyOnce = withCallingReplyOnce(reply)
            activateRemoteObjectProxyWithErrorHandler { _ in replyOnce(true) }?.includesBuiltIn(reply: replyOnce)
        }

        private func activateRemoteObjectProxyWithErrorHandler(_ handler: @escaping (XPCConnectionError) -> Void) -> ResticRunnerProtocol? {
            NSXPCConnection(serviceName: Self.serviceName).activateRemoteObjectProxyWithErrorHandler(protocol: ResticRunnerProtocol.self) { error in handler(error) }
        }

        private func activateRemoteObjectProxyWithErrorHandler(exporting protocol: Protocol, via object: Any, handler: @escaping (XPCConnectionError) -> Void) -> ResticRunnerProtocol? {
            let connection = NSXPCConnection(serviceName: Self.serviceName)
            connection.exportedInterface = NSXPCInterface(with: `protocol`)
            connection.exportedObject = object
            return connection.activateRemoteObjectProxyWithErrorHandler(protocol: ResticRunnerProtocol.self) { error in handler(error) }
        }
    }

    private typealias TypeLogger = ResticSchedulerKit.TypeLogger<ResticScheduler>

    private static let minStaleBackupCheckInterval: Int64 = 60
    private static let maxStaleBackupCheckInterval: Int64 = 3600
    private static let intelligentMacOSGeneralExcludes = [
        ".build",
        ".cache",
        ".dart_tool",
        "*.qcow2",
        "**/.gradle/caches",
        "**/.next/cache",
        ".parcel-cache",
        ".pytest_cache",
        ".Trash",
        "__pycache__",
        "build",
        "CacheStorage",
        "cache.d",
        "dist",
        "node_modules",
        "state.d",
        "target",
        "*(Not synced)",
    ]

    private static func intelligentMacOSHomeExcludes(for homeDirectory: String) -> [String] {
        [
            "\(homeDirectory)/.Trash",
            "\(homeDirectory)/Library/Android/sdk",
            "\(homeDirectory)/Library/CloudStorage",
            "\(homeDirectory)/Library/Application Support/MobileSync/Backup",
            "\(homeDirectory)/Library/Application Support/CrashReporter",
            "\(homeDirectory)/Library/Application Support/com.apple.sharedfilelist",
            "\(homeDirectory)/Library/Application Support/CloudDocs",
            "\(homeDirectory)/Library/Application Support/FileProvider",
            "\(homeDirectory)/Library/Autosave Information",
            "\(homeDirectory)/Library/Caches",
            "\(homeDirectory)/Library/DiagnosticReports",
            "\(homeDirectory)/Library/HTTPStorages",
            "\(homeDirectory)/Library/IdentityCaches",
            "\(homeDirectory)/Library/Logs",
            "\(homeDirectory)/Library/Mail Downloads",
            "\(homeDirectory)/Library/Messages/Attachments",
            "\(homeDirectory)/Library/Metadata",
            "\(homeDirectory)/Library/Saved Application State",
            "\(homeDirectory)/Library/Spotlight",
            "\(homeDirectory)/Library/Suggestions",
            "\(homeDirectory)/Library/Trial",
            "\(homeDirectory)/Library/Developer/CoreSimulator",
            "\(homeDirectory)/Library/Developer/Xcode/Archives",
            "\(homeDirectory)/Library/Developer/Xcode/DerivedData",
            "\(homeDirectory)/Library/Developer/Xcode/DocumentationCache",
            "\(homeDirectory)/Library/Developer/Xcode/DocumentationIndex",
            "\(homeDirectory)/Library/Developer/Xcode/Products",
            "\(homeDirectory)/Library/Developer/Xcode/iOS Device Logs",
            "\(homeDirectory)/Library/Developer/Xcode/watchOS Device Logs",
            "\(homeDirectory)/Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches",
            "\(homeDirectory)/Library/Containers/*/Data/Library/Caches",
            "\(homeDirectory)/Library/Containers/*/Data/Library/Logs",
            "\(homeDirectory)/Library/Containers/*/Data/Library/Saved Application State",
            "\(homeDirectory)/Library/Containers/*/Data/tmp",
            "\(homeDirectory)/Library/Group Containers/*/Library/Caches",
            "\(homeDirectory)/Library/Group Containers/*/Library/Logs",
            "\(homeDirectory)/Library/Group Containers/*/tmp",
            "\(homeDirectory)/Library/Application Support/Google/Chrome/*/Application Cache",
            "\(homeDirectory)/Library/Application Support/Google/Chrome/*/Cache",
            "\(homeDirectory)/Library/Application Support/Google/Chrome/*/Code Cache",
            "\(homeDirectory)/Library/Application Support/Google/Chrome/*/GPUCache",
            "\(homeDirectory)/Library/Application Support/Google/Chrome/*/Service Worker/ScriptCache",
            "\(homeDirectory)/Library/Application Support/Firefox/Profiles/*/cache2",
            "\(homeDirectory)/Library/Application Support/Slack/Cache",
            "\(homeDirectory)/Library/Application Support/Slack/Code Cache",
            "\(homeDirectory)/Library/Application Support/Slack/GPUCache",
            "\(homeDirectory)/Library/Application Support/discord/Cache",
            "\(homeDirectory)/Library/Application Support/discord/Code Cache",
            "\(homeDirectory)/Library/Application Support/discord/GPUCache",
            "\(homeDirectory)/Library/Application Support/Code/Cache",
            "\(homeDirectory)/Library/Application Support/Code/CachedData",
            "\(homeDirectory)/Library/Application Support/Code/CachedExtensions",
            "\(homeDirectory)/Library/Application Support/Code/logs",
            "\(homeDirectory)/Library/Application Support/Steam/appcache",
            "\(homeDirectory)/Library/Application Support/Steam/depotcache",
            "\(homeDirectory)/Library/Application Support/Steam/htmlcache",
            "\(homeDirectory)/Library/Application Support/Steam/logs",
            "\(homeDirectory)/Library/Application Support/Steam/steamapps/shadercache",
            "\(homeDirectory)/Library/Caches/Homebrew",
            "\(homeDirectory)/Library/Downloads/*.dmg",
            "\(homeDirectory)/Library/Downloads/*.iso",
            "\(homeDirectory)/Library/Downloads/*.mpkg",
            "\(homeDirectory)/Library/Downloads/*.pkg",
            "\(homeDirectory)/Library/Downloads/*.xip",
            "\(homeDirectory)/Library/Mobile Documents/com~apple~CloudDocs/Downloads/*.dmg",
            "\(homeDirectory)/Library/Mobile Documents/com~apple~CloudDocs/Downloads/*.iso",
            "\(homeDirectory)/Library/Mobile Documents/com~apple~CloudDocs/Downloads/*.mpkg",
            "\(homeDirectory)/Library/Mobile Documents/com~apple~CloudDocs/Downloads/*.pkg",
            "\(homeDirectory)/Library/Mobile Documents/com~apple~CloudDocs/Downloads/*.xip",
            "\(homeDirectory)/Downloads/*.dmg",
            "\(homeDirectory)/Downloads/*.iso",
            "\(homeDirectory)/Downloads/*.mpkg",
            "\(homeDirectory)/Downloads/*.pkg",
            "\(homeDirectory)/Downloads/*.xip",
            "\(homeDirectory)/Downloads/*.zip",
            "\(homeDirectory)/Desktop/*.dmg",
            "\(homeDirectory)/Desktop/*.iso",
            "\(homeDirectory)/Desktop/*.mpkg",
            "\(homeDirectory)/Desktop/*.pkg",
            "\(homeDirectory)/Desktop/*.xip",
            "\(homeDirectory)/Documents/*.dmg",
            "\(homeDirectory)/Documents/*.iso",
            "\(homeDirectory)/Documents/*.mpkg",
            "\(homeDirectory)/Documents/*.pkg",
            "\(homeDirectory)/Documents/*.xip",
        ]
    }

    var logURL: URL {
        try! FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Logs", directoryHint: .isDirectory)
            .appending(path: Bundle.main.bundleIdentifier!, directoryHint: .isDirectory)
            .appending(path: "restic.log", directoryHint: .notDirectory)
    }

    var summaryURL: URL {
        try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: Bundle.main.bundleIdentifier!, directoryHint: .isDirectory)
            .appending(path: "summary.json", directoryHint: .notDirectory)
    }

    @Published private(set) var percentDone: Float64 = 0
    @Published private(set) var bytesDone: UInt64 = 0
    @Published private(set) var totalBytes: UInt64 = 0
    @Published private(set) var secondsElapsed: UInt64 = 0
    @Published private(set) var secondsRemaining: UInt64 = 0
    @Published private(set) var filesDone: UInt64 = 0
    @Published private(set) var totalFiles: UInt64 = 0
    @Published private(set) var errorCount: UInt64 = 0
    @Published var status = Status.idle

    @UserDefault(\.backupFrequency) private var backupFrequency
    @UserDefault(\.lastSuccessfulBackupDate) private var lastSuccessfulBackupDate
    @UserDefault(\.nextScheduledBackupDate) private var nextScheduledBackupDate
    @UserDefault(\.binary) private var binary
    @UserDefault(\.arguments) private var arguments
    @UserDefault(\.includes) private var includes
    @UserDefault(\.excludes) private var excludes
    @UserDefault(\.intelligentMacOSBackupEnabled) private var intelligentMacOSBackupEnabled
    @UserDefault(\.repository) private var repository
    @KeychainPassword(\.password) private var password
    @UserDefault(\.s3AccessKeyId) private var s3AccessKeyId
    @KeychainPassword(\.s3SecretAccessKey) private var s3SecretAccessKey
    @UserDefault(\.restUsername) private var restUsername
    @KeychainPassword(\.restPassword) private var restPassword
    @UserDefault(\.host) private var host
    @UserDefault(\.beforeBackup) private var beforeBackup
    @UserDefault(\.onSuccess) private var onSuccess
    @UserDefault(\.onFailure) private var onFailure
    @UserDefault(\.localizedError) private var localizedError

    private let runner = Runner()
    private let lock = OSAllocatedUnfairLock()
    private var backupTimer: Timer?
    private var staleBackupScheduler: NSBackgroundActivityScheduler?
    private var bag = Set<AnyCancellable>()

    private var effectiveIncludes: [String] {
        includes
    }

    private var effectiveExcludes: [String] {
        guard intelligentMacOSBackupEnabled else {
            return excludes
        }

        var effectiveExcludes = excludes.appendingUnique(Self.intelligentMacOSGeneralExcludes)
        for homeDirectory in Self.includedHomeDirectories(includes) {
            effectiveExcludes = effectiveExcludes.appendingUnique(Self.intelligentMacOSHomeExcludes(for: homeDirectory))
        }
        return effectiveExcludes
    }

    private var isBackupStale: Bool {
        let interval = Duration.seconds(backupFrequency)
        guard interval.components.seconds > 0 else {
            return false
        }
        if let nextScheduledBackupDate, nextScheduledBackupDate > Date() {
            return false
        }

        return lastSuccessfulBackupDate == nil || abs(lastSuccessfulBackupDate!.timeIntervalSinceNow) >= TimeInterval(interval.components.seconds * 2)
    }

    private static func includedHomeDirectories(_ includes: [String]) -> [String] {
        var homeDirectories = [String]()
        let candidateHomes = [
            "/Users/\(NSUserName())",
            NSHomeDirectoryForUser(NSUserName()),
            FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false),
        ]
            .compactMap { $0?.deletingTrailingSlashes }
            .appendingUnique([])

        for include in includes {
            let expandedInclude = (include as NSString).expandingTildeInPath.deletingTrailingSlashes
            for candidateHome in candidateHomes where expandedInclude == candidateHome || expandedInclude.hasPrefix("\(candidateHome)/") {
                homeDirectories = homeDirectories.appendingUnique([candidateHome])
            }

            let components = expandedInclude.split(separator: "/", omittingEmptySubsequences: true)
            if components.count >= 2, components[0] == "Users", components[1] == Substring(NSUserName()) {
                homeDirectories = homeDirectories.appendingUnique(["/Users/\(components[1])"])
            }
        }

        return homeDirectories
    }

    init() {
        AppDelegate.resticScheduler = self
        runner.scheduler = self
        rescheduleBackup()
        rescheduleStaleBackupCheck()
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
    }

    func progressDidUpdate(percentDone: Float64, bytesDone: UInt64, totalBytes: UInt64, secondsElapsed: UInt64, secondsRemaining: UInt64, filesDone: UInt64, totalFiles: UInt64, errorCount: UInt64) {
        lock.withLock {
            DispatchQueue.main.sync {
                if status == .preparation {
                    status = .backup
                }
                self.percentDone = percentDone
                self.bytesDone = bytesDone
                self.totalBytes = totalBytes
                self.secondsElapsed = secondsElapsed
                self.secondsRemaining = secondsRemaining
                self.filesDone = filesDone
                self.totalFiles = totalFiles
                self.errorCount = errorCount
            }
        }
    }

    func backupDidFinishCopying() {
        lock.withLock {
            DispatchQueue.main.sync {
                if status == .backup {
                    status = .finishing
                }
            }
        }
    }

    func backup(completion: @escaping ((Error?) -> Void)) {
        lock.withLock {
            guard status == .idle else {
                completion(status == .preparation ? BackupError.preparationInProcess : BackupError.backupInProcess)
                return
            }

            status = .preparation
            percentDone = 0
            bytesDone = 0
            totalBytes = 0
            secondsElapsed = 0
            secondsRemaining = 0
            filesDone = 0
            totalFiles = 0
            errorCount = 0
            let startedContent = UNMutableNotificationContent()
            startedContent.title = "Backup Started"
            startedContent.body = "Restic Scheduler started backing up “\(formatRepository(repository))”."
            AppDelegate.shared?.addNotification(content: startedContent)

            var environment = [
                "RESTIC_REPOSITORY": repository,
                "RESTIC_PASSWORD": password,
            ]
            if let s3AccessKeyId {
                environment["AWS_ACCESS_KEY_ID"] = s3AccessKeyId
            }
            if let s3SecretAccessKey {
                environment["AWS_SECRET_ACCESS_KEY"] = s3SecretAccessKey
            }
            if let restUsername {
                environment["RESTIC_REST_USERNAME"] = restUsername
            }
            if let restPassword {
                environment["RESTIC_REST_PASSWORD"] = restPassword
            }

            let effectiveIncludes = self.effectiveIncludes
            let effectiveExcludes = self.effectiveExcludes
            TypeLogger.function().info("Starting backup with includes:")
            for include in effectiveIncludes {
                TypeLogger.function().info("include: \(include, privacy: .public)")
            }
            TypeLogger.function().info("Starting backup with excludes:")
            for exclude in effectiveExcludes {
                TypeLogger.function().info("exclude: \(exclude, privacy: .public)")
            }

            let options = BackupOptions(
                logURL: logURL,
                summaryURL: summaryURL,
                arguments: ["--host", host ?? Host.current().localizedName!] + arguments,
                includes: effectiveIncludes,
                excludes: effectiveExcludes,
                environment: environment,
                beforeBackup: beforeBackup?.hook,
                onSuccess: onSuccess?.hook,
                onFailure: onFailure?.hook
            )
            runner.backup(binary: binary, options: options) { [weak self] error in
                guard let self else {
                    return
                }

                lock.withLock {
                    DispatchQueue.main.sync { [weak self] in
                        guard let self else {
                            return
                        }

                        if let error {
                            localizedError = error.localizedDescription
                            let content = UNMutableNotificationContent()
                            content.title = "Backup Not Completed"
                            content.body = "Restic Scheduler couldn’t complete the backup."
                            content.userInfo[AppDelegate.NotificationUserInfoKey.localizedError.rawValue] = localizedError
                            content.userInfo[AppDelegate.NotificationUserInfoKey.repository.rawValue] = repository
                            content.categoryIdentifier = AppDelegate.NotificationCategoryIdentifier.backupFailure.rawValue
                            AppDelegate.shared?.addNotification(content: content)
                        } else {
                            localizedError = nil
                            let completedAt = Date()
                            lastSuccessfulBackupDate = completedAt
                            nextScheduledBackupDate = nextBackupDate(from: completedAt)
                            let content = UNMutableNotificationContent()
                            content.title = "Backup Completed"
                            content.body = "Restic Scheduler finished backing up “\(formatRepository(repository))”."
                            AppDelegate.shared?.addNotification(content: content)
                        }
                        status = .idle
                        completion(error)
                    }
                }
            }
        }
    }

    func stop(completion: ((Error?) -> Void)? = nil) {
        lock.withLock {
            guard status != .idle, status != .stopping else {
                completion?(nil)
                return
            }

            status = .stopping
            runner.stop { [weak self] error in
                guard let self else {
                    completion?(error)
                    return
                }

                lock.withLock {
                    DispatchQueue.main.sync {
                        if error != nil {
                            if self.status == .stopping {
                                self.status = .idle
                            }
                            TypeLogger.function().error("\(error!.localizedDescription, privacy: .public)")
                        } else {
                            self.status = .idle
                        }
                    }
                }
                completion?(error)
            }
        }
    }

    func version(completion: @escaping (String?, Error?) -> Void) {
        runner.version(binary: binary, reply: completion)
    }

    func includesBuiltIn(completion: @escaping (Bool) -> Void) {
        runner.includesBuiltIn(reply: completion)
    }

    func rescheduleBackup() {
        lock.withLock {
            backupTimer?.invalidate()
            backupTimer = nil
            let interval = Duration.seconds(backupFrequency)
            guard interval.components.seconds > 0 else {
                return
            }

            let intervalSeconds = TimeInterval(interval.components.seconds)
            if nextScheduledBackupDate == nil || nextScheduledBackupDate! <= Date() {
                nextScheduledBackupDate = nextBackupDate(from: Date())
            }
            let timer = Timer(timeInterval: intervalSeconds, repeats: true) { [weak self] _ in
                self?.scheduledBackup()
            }
            timer.fireDate = nextScheduledBackupDate!
            backupTimer = timer
            DispatchQueue.main.async {
                guard timer.isValid else {
                    return
                }
                RunLoop.main.add(timer, forMode: .common)
            }
            TypeLogger.function().info("Rescheduled backups, interval: \(interval.formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .wide)), privacy: .public), next backup: \(timer.fireDate, privacy: .public)")
        }
    }

    func backupFrequencyDidChange() {
        lock.withLock {
            nextScheduledBackupDate = nextBackupDate(from: Date())
        }
        rescheduleBackup()
        rescheduleStaleBackupCheck()
    }

    private func nextBackupDate(from date: Date) -> Date? {
        let interval = Duration.seconds(backupFrequency)
        let intervalSeconds = interval.components.seconds
        guard intervalSeconds > 0 else {
            return nil
        }

        let nextDate = date.addingTimeInterval(TimeInterval(intervalSeconds))
        if intervalSeconds % 3600 == 0 {
            return nextDate.roundedDownToHour()
        }
        if intervalSeconds % 60 == 0 {
            return nextDate.roundedDownToMinute()
        }
        return nextDate
    }

    private func scheduledBackup() {
        lock.withLock {
            guard status == .idle else {
                nextScheduledBackupDate = nextBackupDate(from: Date())
                if let nextScheduledBackupDate {
                    backupTimer?.fireDate = nextScheduledBackupDate
                    TypeLogger.function().info("Skipped scheduled backup because another backup is in progress, next backup: \(nextScheduledBackupDate, privacy: .public)")
                } else {
                    TypeLogger.function().info("Skipped scheduled backup because another backup is in progress")
                }
                return
            }
        }

        backup { error in
            if let error {
                TypeLogger.function().error("Failed to run scheduled backup: \(error.localizedDescription, privacy: .public)")
            } else {
                TypeLogger.function().info("Finished scheduled backup")
            }
        }
    }

    func rescheduleStaleBackupCheck() {
        lock.withLock {
            staleBackupScheduler?.invalidate()
            let interval = Duration.seconds(backupFrequency)
            guard interval.components.seconds > 0 else {
                return
            }

            staleBackupScheduler = NSBackgroundActivityScheduler(identifier: "\(Bundle.main.bundleIdentifier!).staleBackupCheck")
            staleBackupScheduler!.qualityOfService = .background
            let staleCheckInterval = min(max(Self.minStaleBackupCheckInterval, interval.components.seconds / 2), Self.maxStaleBackupCheckInterval)
            staleBackupScheduler!.interval = TimeInterval(staleCheckInterval)
            staleBackupScheduler!.schedule { [weak self] completion in
                guard let self, let scheduler = staleBackupScheduler else {
                    completion(.deferred)
                    return
                }
                guard !scheduler.shouldDefer else {
                    TypeLogger.function().info("Deferred stale backup check as suggested")
                    completion(.deferred)
                    return
                }
                guard isBackupStale else {
                    completion(.finished)
                    return
                }

                DispatchQueue.main.sync {
                    self.backup { error in
                        if let error {
                            TypeLogger.function().error("Failed to run scheduled stale backup: \(error.localizedDescription, privacy: .public)")
                        } else {
                            TypeLogger.function().info("Finished scheduled stale backup")
                        }
                        completion(.finished)
                    }
                }
            }
            TypeLogger.function().info("Rescheduled stale backup check, interval: \(Duration.seconds(staleCheckInterval).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .wide)), privacy: .public), stale: \(self.isBackupStale, privacy: .public)")
        }
    }
}

private extension Array where Element == String {
    func appendingUnique(_ values: [String]) -> [String] {
        var result = self
        var seen = Set(self)
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}

private extension String {
    var deletingTrailingSlashes: String {
        var result = self
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}

private extension Date {
    func roundedDownToMinute(calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: calendar.component(.hour, from: self), minute: calendar.component(.minute, from: self), second: 0, of: self)!
    }

    func roundedDownToHour(calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: calendar.component(.hour, from: self), minute: 0, second: 0, of: self)!
    }
}
