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
    @Published var status = Status.idle

    @UserDefault(\.backupFrequency) private var backupFrequency
    @UserDefault(\.lastSuccessfulBackupDate) private var lastSuccessfulBackupDate
    @UserDefault(\.nextScheduledBackupDate) private var nextScheduledBackupDate
    @UserDefault(\.binary) private var binary
    @UserDefault(\.arguments) private var arguments
    @UserDefault(\.includes) private var includes
    @UserDefault(\.excludes) private var excludes
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

    init() {
        runner.scheduler = self
        rescheduleBackup()
        rescheduleStaleBackupCheck()
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
    }

    func progressDidUpdate(percentDone: Float64, bytesDone: UInt64) {
        lock.withLock {
            DispatchQueue.main.sync {
                if status == .preparation {
                    status = .backup
                }
                self.percentDone = percentDone
                self.bytesDone = bytesDone
                if percentDone >= 1, status == .backup {
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

            let options = BackupOptions(
                logURL: logURL,
                summaryURL: summaryURL,
                arguments: ["--host", host ?? Host.current().localizedName!] + arguments,
                includes: includes,
                excludes: excludes,
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

    func stop() {
        lock.withLock {
            guard status != .idle, status != .stopping else {
                return
            }

            runner.stop { [weak self] error in
                guard let self else {
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
                TypeLogger.function().info("Skipped scheduled backup because another backup is in progress")
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

private extension Date {
    func roundedDownToMinute(calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: calendar.component(.hour, from: self), minute: calendar.component(.minute, from: self), second: 0, of: self)!
    }

    func roundedDownToHour(calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: calendar.component(.hour, from: self), minute: 0, second: 0, of: self)!
    }
}
