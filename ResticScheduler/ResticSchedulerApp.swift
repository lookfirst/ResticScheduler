import Foundation
import ResticSchedulerKit
import SwiftUI

@main struct ResticSchedulerApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    private let resticScheduler = ResticScheduler()

    var body: some Scene {
        MenuBarExtra {
            ResticSchedulerMenu(resticScheduler: resticScheduler)
        } label: {
            ResticSchedulerMenuLabel(resticScheduler: resticScheduler)
        }
        Settings {
            SettingsView()
                .environmentObject(resticScheduler)
        }
        .windowResizability(.contentSize)
    }
}

private struct ResticSchedulerMenuLabel: View {
    @ObservedObject var resticScheduler: ResticScheduler

    var body: some View {
        Label("Restic Scheduler", image: resticScheduler.status == .idle ? "custom.umbrella.fill" : "custom.umbrella.fill.badge.clock")
    }
}

private struct ResticSchedulerMenu: View {
    private typealias TypeLogger = ResticSchedulerKit.TypeLogger<ResticSchedulerMenu>
    private static let b2StorageDollarsPerTBMonth = 6.0
    private static let b2FreeStorageBytes = 10.0 * 1_000_000_000
    private static let bytesPerDecimalTB = 1_000_000_000_000.0
    private static let b2StorageCostHelp = "Storage-only estimate based on Backblaze B2 Pay-As-You-Go at $6/TB/month, billed over a 30-day month, with the first 10GB free. It does not include egress or API transaction costs."

    @ObservedObject var resticScheduler: ResticScheduler
    @UserDefault(\.repository) private var repository
    @UserDefault(\.backupFrequency) private var backupFrequency
    @UserDefault(\.lastSuccessfulBackupDate) private var lastSuccessfulBackupDate
    @UserDefault(\.lastSuccessfulPruneDate) private var lastSuccessfulPruneDate
    @UserDefault(\.nextScheduledBackupDate) private var nextScheduledBackupDate
    @UserDefault(\.localizedError) private var localizedError

    private var actionLabel: String {
        switch resticScheduler.status {
        case .stopping: lastSuccessfulBackupDate == nil ? "Stopping…" : "Skipping…"
        case .pruning: "Pruning…"
        case .idle: "Backup Now"
        default: lastSuccessfulBackupDate == nil ? "Stop This Backup" : "Skip This Backup"
        }
    }

    private var lastSuccessfulBackup: String {
        formatBackupDate(lastSuccessfulBackupDate!)
    }

    private var nextBackup: String? {
        guard backupFrequency > 0, let nextScheduledBackupDate else {
            return nil
        }

        return formatBackupDate(nextScheduledBackupDate)
    }

    private var lastPrune: String {
        guard let lastSuccessfulPruneDate else {
            return "Never"
        }

        return formatBackupDate(lastSuccessfulPruneDate)
    }

    private var backupBytesProgress: String {
        let copied = resticScheduler.bytesDone.formatted(.byteCount(style: .file, allowedUnits: [.gb, .mb]))
        if resticScheduler.totalBytes > 0 {
            return "\(copied) / \(resticScheduler.totalBytes.formatted(.byteCount(style: .file, allowedUnits: [.gb, .mb])))"
        }

        return copied
    }

    private var backupFilesProgress: String? {
        if resticScheduler.totalFiles > 0 {
            return "\(resticScheduler.filesDone.formatted()) / \(resticScheduler.totalFiles.formatted()) files"
        }

        return nil
    }

    private var backupErrors: String? {
        guard resticScheduler.errorCount > 0 else {
            return nil
        }

        return "\(resticScheduler.errorCount.formatted()) errors"
    }

    private var backupPercent: String {
        let percent = floor(resticScheduler.percentDone * 1000) / 10
        return "\(percent.formatted(.number.precision(.fractionLength(1))))% done"
    }

    private func formatDuration(_ seconds: UInt64) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(seconds))
    }

    private var backupElapsed: String? {
        guard let duration = formatDuration(resticScheduler.secondsElapsed) else {
            return nil
        }

        return "Running for \(duration)"
    }

    private var backupETA: String? {
        guard resticScheduler.secondsRemaining > 0 else {
            return nil
        }

        guard let duration = formatDuration(resticScheduler.secondsRemaining) else {
            return nil
        }

        return "\(duration) remaining"
    }

    private var isS3Repository: Bool {
        repository.hasPrefix(RepositoryType.s3.rawValue)
    }

    private var repositoryStorageSize: String? {
        guard let repositoryStats = resticScheduler.repositoryStats else {
            return nil
        }

        return "\(repositoryStats.totalBytes.formatted(.byteCount(style: .file))) stored"
    }

    private var repositoryStorageFiles: String? {
        guard let repositoryStats = resticScheduler.repositoryStats else {
            return nil
        }

        return "\(repositoryStats.fileCount.formatted()) files"
    }

    private var repositoryStorageSnapshots: String? {
        guard let repositoryStats = resticScheduler.repositoryStats else {
            return nil
        }

        return "\(repositoryStats.snapshotCount.formatted()) snapshot\(repositoryStats.snapshotCount == 1 ? "" : "s")"
    }

    private var repositoryStorageCosts: (day: String, month: String, year: String)? {
        guard let repositoryStats = resticScheduler.repositoryStats else {
            return nil
        }

        let chargeableBytes = max(0, Double(repositoryStats.totalBytes) - Self.b2FreeStorageBytes)
        let monthlyCost = chargeableBytes / Self.bytesPerDecimalTB * Self.b2StorageDollarsPerTBMonth
        return (
            "\(formatEstimatedCost(monthlyCost / 30))/day",
            "\(formatEstimatedCost(monthlyCost))/month",
            "\(formatEstimatedCost(monthlyCost * 12))/year"
        )
    }

    private func formatEstimatedCost(_ value: Double) -> String {
        guard value > 0 else {
            return "$0.00"
        }

        if value < 0.01 {
            return "<$0.01"
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$\(value.formatted(.number.precision(.fractionLength(2))))"
    }

    private func formatBackupDate(_ date: Date) -> String {
        let relativeDateFormatter = DateFormatter()
        relativeDateFormatter.timeStyle = .short
        relativeDateFormatter.dateStyle = .short
        relativeDateFormatter.doesRelativeDateFormatting = true
        return relativeDateFormatter.string(from: date)
    }

    var body: some View {
        Group {
            switch resticScheduler.status {
            case .preparation:
                Text("Preparing to back up…")
            case .backup:
                if let backupElapsed {
                    Text(backupElapsed)
                }
                Text(backupPercent)
                Text(backupBytesProgress)
                if let backupFilesProgress {
                    Text(backupFilesProgress)
                }
                if let backupErrors {
                    Text(backupErrors)
                }
                if let backupETA {
                    Text(backupETA)
                }
            case .finishing:
                Text("Finishing backup…")
                Text("\(resticScheduler.bytesDone.formatted(.byteCount(style: .file))) copied")
            default:
                if lastSuccessfulBackupDate != nil {
                    Text("Latest Backup to “\(formatRepository(repository))”")
                    Text(lastSuccessfulBackup)
                    Text("Last Prune")
                    Text(lastPrune)
                    if let nextBackup {
                        Text("Next Backup")
                        Text(nextBackup)
                    }
                    if isS3Repository {
                        Divider()
                        Text("Repository Storage")
                        if let repositoryStorageFiles, let repositoryStorageSize, let repositoryStorageSnapshots {
                            Text(repositoryStorageSnapshots)
                            Text(repositoryStorageFiles)
                            Text(repositoryStorageSize)
                            if let repositoryStorageCosts {
                                Divider()
                                Text("Estimated B2 Storage Cost")
                                    .help(Self.b2StorageCostHelp)
                                Text(repositoryStorageCosts.day)
                                    .help(Self.b2StorageCostHelp)
                                Text(repositoryStorageCosts.month)
                                    .help(Self.b2StorageCostHelp)
                                Text(repositoryStorageCosts.year)
                                    .help(Self.b2StorageCostHelp)
                            }
                        } else if resticScheduler.isUpdatingRepositoryStats {
                            Text("Updating storage stats…")
                        } else {
                            Text("Storage stats unavailable")
                                .help(resticScheduler.repositoryStatsError ?? "")
                        }
                    }
                } else {
                    Text("Waiting to Complete First Backup")
                }
            }
            Divider()
            if localizedError != nil {
                Button("Backup Issues…", action: showError)
            }
            Button(actionLabel) {
                if resticScheduler.status == .idle {
                    resticScheduler.backup { error in
                        if let error {
                            TypeLogger.function().error("Failed to run manual backup: \(error.localizedDescription, privacy: .public)")
                        } else {
                            TypeLogger.function().info("Finished manual backup")
                        }
                    }
                } else {
                    resticScheduler.stop()
                }
            }
            .disabled(resticScheduler.status == .stopping || resticScheduler.status == .pruning)
            if resticScheduler.status == .idle {
                Button("Prune Now") {
                    resticScheduler.runRepositoryPruneIfNeeded(reason: "manual request", ignoringRateLimit: true) { didStart in
                        if !didStart {
                            TypeLogger.function().info("Skipped manual prune request")
                        }
                    }
                }
            }
            Button("View Restic Logs…", action: showLogs)
            Divider()
            Button("Settings…") {
                SettingsWindowController.show(resticScheduler: resticScheduler)
            }
            Button("About Restic Scheduler") {
                NSApp.orderFrontStandardAboutPanel()
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit Restic Scheduler") { NSApplication.shared.terminate(nil) }
        }
    }

    private func showLogs() {
        guard let exists = try? resticScheduler.logURL.checkResourceIsReachable(), exists else {
            NSAlert.showError(.logNotFound(logURL: resticScheduler.logURL))
            return
        }

        NSWorkspace.shared.open(resticScheduler.logURL)
    }

    private func showError() {
        guard let localizedError else {
            return
        }

        NSAlert.showError(.backupFailure(repository: repository), informativeText: localizedError)
    }
}

func formatRepository(_ repository: String) -> String {
    var repositoryURL: URL?
    switch true {
    case repository.hasPrefix(RepositoryType.sftp.rawValue + "//"):
        repositoryURL = URL(string: repository)
    case repository.hasPrefix(RepositoryType.sftp.rawValue):
        repositoryURL = URL(string: repository.inserting(contentsOf: "//", at: RepositoryType.sftp.rawValue.endIndex))
    case repository.hasPrefix(RepositoryType.rest.rawValue):
        repositoryURL = URL(string: repository.droppingPrefix(RepositoryType.rest.rawValue))
    default:
        return FileManager.default.displayName(atPath: repository)
    }
    if let host = repositoryURL?.host(percentEncoded: false) {
        return host
    }

    return repository
}
