import Cocoa
import ResticSchedulerKit
@preconcurrency import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private typealias TypeLogger = ResticSchedulerKit.TypeLogger<AppDelegate>

    enum NotificationCategoryIdentifier: String {
        case backupFailure = "BACKUP_FAILURE"
    }

    enum NotificationUserInfoKey: String {
        case localizedError = "LOCALIZED_ERROR"
        case repository = "REPOSITORY"
    }

    private enum NotificationActionIdentifier: String {
        case details = "DETAILS"
    }

    private(set) static var shared: AppDelegate?
    static weak var resticScheduler: ResticScheduler?

    private static let authorizationOptions: UNAuthorizationOptions = [.alert, .sound]
    private var notificationCenter: UNUserNotificationCenter?
    private var isTerminating = false

    func applicationDidFinishLaunching(_: Notification) {
        Self.shared = self
        notificationCenter = UNUserNotificationCenter.current()
        notificationCenter!.delegate = self
        let detailsAction = UNNotificationAction(identifier: NotificationActionIdentifier.details.rawValue, title: "Details", options: [])
        let backupFailureCategory = UNNotificationCategory(
            identifier: NotificationCategoryIdentifier.backupFailure.rawValue,
            actions: [detailsAction],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "",
            options: .hiddenPreviewsShowTitle
        )
        notificationCenter!.setNotificationCategories([backupFailureCategory])
        notificationCenter!.requestAuthorization(options: Self.authorizationOptions) { granted, error in
            guard error == nil else {
                TypeLogger.function().warning("Notification authorization request error: \(error!.localizedDescription, privacy: .public)")
                return
            }
            guard granted else {
                TypeLogger.function().warning("Notification authorization request denied")
                return
            }
        }
    }

    func userNotificationCenter(_: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        TypeLogger.function().info("Presenting notification: \(notification.request.content.title, privacy: .public)")
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive notification: UNNotificationResponse) async {
        DispatchQueue.main.async {
            switch notification.actionIdentifier {
            case NotificationActionIdentifier.details.rawValue, UNNotificationDefaultActionIdentifier:
                guard notification.notification.request.content.categoryIdentifier == NotificationCategoryIdentifier.backupFailure.rawValue else {
                    return
                }
                guard let repository = notification.notification.request.content.userInfo[NotificationUserInfoKey.repository.rawValue] as? String else {
                    TypeLogger.function().warning("No repository name found in notification user info")
                    return
                }
                guard let localizedError = notification.notification.request.content.userInfo[NotificationUserInfoKey.localizedError.rawValue] as? String else {
                    TypeLogger.function().warning("No localized error found in notification user info")
                    return
                }

                NSAlert.showError(.backupFailure(repository: repository), informativeText: localizedError)
            default:
                break
            }
        }
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else {
            return .terminateNow
        }
        guard let resticScheduler = Self.resticScheduler, resticScheduler.status != .idle else {
            return .terminateNow
        }

        isTerminating = true
        TypeLogger.function().info("Application is quitting; stopping running restic process before termination")
        do {
            try "\(Date().formatted(.rfc3164)) Application is quitting; stopping running restic process...\n"
                .append(to: resticScheduler.logURL, encoding: .utf8)
        } catch {
            TypeLogger.function().warning("Couldn't write shutdown notice to restic log: \(error.localizedDescription, privacy: .public)")
        }
        resticScheduler.stop { error in
            if let error {
                TypeLogger.function().error("Restic process stop during application termination failed: \(error.localizedDescription, privacy: .public)")
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func addNotification(content: UNMutableNotificationContent, deliveryDelay: TimeInterval = 0) {
        content.sound = .default
        content.interruptionLevel = .active

        notificationCenter!.requestAuthorization(options: Self.authorizationOptions) { granted, error in
            guard error == nil else {
                TypeLogger.function().warning("Notification authorization request error: \(error!.localizedDescription, privacy: .public)")
                return
            }
            guard granted else {
                TypeLogger.function().warning("Notification authorization request denied")
                return
            }

            let trigger = deliveryDelay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: deliveryDelay, repeats: false) : nil
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            self.notificationCenter!.add(request, withCompletionHandler: { error in
                guard error == nil else {
                    TypeLogger.function().warning("Couldn't add notification request: \(error!.localizedDescription, privacy: .public)")
                    return
                }
                TypeLogger.function().info("Queued notification: \(content.title, privacy: .public)")
            })
        }
    }
}
