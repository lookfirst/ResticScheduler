import ResticSchedulerKit
import SwiftUI

@main struct ResticSchedulerApp: App {
    private typealias TypeLogger = ResticSchedulerKit.TypeLogger<ResticSchedulerApp>

    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var resticScheduler = ResticScheduler()
    @UserDefault(\.repository) private var repository
    @UserDefault(\.backupFrequency) private var backupFrequency
    @UserDefault(\.lastSuccessfulBackupDate) private var lastSuccessfulBackupDate
    @UserDefault(\.nextScheduledBackupDate) private var nextScheduledBackupDate
    @UserDefault(\.localizedError) private var localizedError

    private var actionLabel: String {
        switch resticScheduler.status {
        case .stopping: lastSuccessfulBackupDate == nil ? "Stopping…" : "Skipping…"
        case .idle: "Back Up Now"
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

    private func formatBackupDate(_ date: Date) -> String {
        let relativeDateFormatter = DateFormatter()
        relativeDateFormatter.timeStyle = .short
        relativeDateFormatter.dateStyle = .short
        relativeDateFormatter.doesRelativeDateFormatting = true
        return relativeDateFormatter.string(from: date)
    }

    var body: some Scene {
        MenuBarExtra("Restic Scheduler", image: resticScheduler.status == .idle ? "custom.umbrella.fill" : "custom.umbrella.fill.badge.clock") {
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
                    if let nextBackup {
                        Text("Next Backup")
                        Text(nextBackup)
                    }
                    if localizedError != nil {
                        Button("Backup Failed…", action: showError)
                    }
                } else {
                    Text("Waiting to Complete First Backup")
                }
            }
            Divider()
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
            .disabled(resticScheduler.status == .stopping)
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
        Settings {
            SettingsView()
                .environmentObject(resticScheduler)
        }
        .windowResizability(.contentSize)
    }

    func showLogs() {
        guard let exists = try? resticScheduler.logURL.checkResourceIsReachable(), exists else {
            NSAlert.showError(.logNotFound(logURL: resticScheduler.logURL))
            return
        }

        NSWorkspace.shared.open(resticScheduler.logURL)
    }

    func showError() {
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
