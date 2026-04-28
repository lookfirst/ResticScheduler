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
        "*.cache",
        "*.cache.*",
        "*.cache-*",
        "*.dmg",
        ".dart_tool",
        "*.fdd",
        "*.hdd",
        "*.hds",
        "*.iso",
        "*.journal",
        "*.log",
        "*.nvram",
        "*.pvi",
        "*.pvm",
        "*.pvs",
        "*.qcow2",
        "*.qcow2.xz",
        "*.sparsebundle",
        "*.sparseimage",
        "*.swp",
        "*.temp",
        "*.tmp",
        "*.vdi",
        "*.vhd",
        "*.vhdx",
        "*.vmdk",
        "*.vmem",
        "*.vmsd",
        "*.vmsn",
        "*.vmx",
        "*.vmxf",
        "*~",
        "**/.gradle/caches",
        "**/.next/cache",
        ".DS_Store",
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
        "*( Not synced)",
        "*(Not synced)",
    ]

    private static func intelligentMacOSHomeExcludes(for homeDirectory: String) -> [String] {
        [
            "\(homeDirectory)/.Trash",
            "\(homeDirectory)/.bun/install/cache",
            "\(homeDirectory)/.cargo/git",
            "\(homeDirectory)/.cargo/registry",
            "\(homeDirectory)/.composer/cache",
            "\(homeDirectory)/.deno",
            "\(homeDirectory)/.electron",
            "\(homeDirectory)/.gradle/caches",
            "\(homeDirectory)/.ivy2/cache",
            "\(homeDirectory)/.m2/repository",
            "\(homeDirectory)/.node-gyp",
            "\(homeDirectory)/.npm",
            "\(homeDirectory)/.nuget/packages",
            "\(homeDirectory)/.pnpm-store",
            "\(homeDirectory)/.pub-cache",
            "\(homeDirectory)/.rustup/downloads",
            "\(homeDirectory)/.rustup/tmp",
            "\(homeDirectory)/.terraform.d/plugin-cache",
            "\(homeDirectory)/.vagrant.d/boxes",
            "\(homeDirectory)/.yarn/berry/cache",
            "\(homeDirectory)/.yarn/cache",
            "\(homeDirectory)/.local/share/pnpm/store",
            "\(homeDirectory)/Library/Android/sdk",
            "\(homeDirectory)/Library/CloudStorage",
            "\(homeDirectory)/Library/Application Support/MobileSync/Backup",
            "\(homeDirectory)/Library/Application Support/CrashReporter",
            "\(homeDirectory)/Library/Application Support/CocoaPods",
            "\(homeDirectory)/Library/Application Support/AddressBook",
            "\(homeDirectory)/Library/Application Support/CallHistoryDB",
            "\(homeDirectory)/Library/Application Support/CallHistoryTransactions",
            "\(homeDirectory)/Library/Application Support/CloudKit",
            "\(homeDirectory)/Library/Application Support/com.apple.sharedfilelist",
            "\(homeDirectory)/Library/Application Support/CloudDocs",
            "\(homeDirectory)/Library/Application Support/FileProvider",
            "\(homeDirectory)/Library/Application Support/Books",
            "\(homeDirectory)/Library/Application Support/com.docker.install",
            "\(homeDirectory)/Library/Application Support/com.apple.wallpaper",
            "\(homeDirectory)/Library/Application Support/com.apple.wallpaper.*",
            "\(homeDirectory)/Library/Application Support/Google/AndroidStudio*/plugins",
            "\(homeDirectory)/Library/Application Support/JetBrains/Toolbox/apps",
            "\(homeDirectory)/Library/Application Support/JetBrains/*/plugins",
            "\(homeDirectory)/Library/Application Support/Mimestream",
            "\(homeDirectory)/Library/Application Support/UnrealEngine/Common/DerivedDataCache",
            "\(homeDirectory)/Library/Application Support/google-cloud-tools-java/managed-cloud-sdk",
            "\(homeDirectory)/Library/Application Support/virtualenv",
            "\(homeDirectory)/Library/Application Scripts/com.apple.*Diagnostic*",
            "\(homeDirectory)/Library/Application Scripts/com.apple.*Telemetry*",
            "\(homeDirectory)/Library/Application Scripts/com.apple.DiagnosticExtensions.*",
            "\(homeDirectory)/Library/Application Scripts/com.apple.wallpaper*",
            "\(homeDirectory)/Library/Application Scripts/com.mimestream*",
            "\(homeDirectory)/Library/Accounts",
            "\(homeDirectory)/Library/AppleMediaServices",
            "\(homeDirectory)/Library/Autosave Information",
            "\(homeDirectory)/Library/Biome",
            "\(homeDirectory)/Library/Calendars",
            "\(homeDirectory)/Library/CallServices",
            "\(homeDirectory)/Library/ContainerManager",
            "\(homeDirectory)/Library/Contacts",
            "\(homeDirectory)/Library/CoreFollowUp",
            "\(homeDirectory)/Library/**/Cache",
            "\(homeDirectory)/Library/**/Cache*",
            "\(homeDirectory)/Library/**/Crash Reports",
            "\(homeDirectory)/Library/**/CrashPad",
            "\(homeDirectory)/Library/**/Crashpad",
            "\(homeDirectory)/Library/**/CrashpadMetrics*",
            "\(homeDirectory)/Library/**/DawnCache",
            "\(homeDirectory)/Library/**/DawnGraphiteCache",
            "\(homeDirectory)/Library/**/DawnWebGPUCache",
            "\(homeDirectory)/Library/**/GPUCache",
            "\(homeDirectory)/Library/**/GrShaderCache",
            "\(homeDirectory)/Library/**/ImageCache",
            "\(homeDirectory)/Library/**/NSDataCache",
            "\(homeDirectory)/Library/**/ShaderCache",
            "\(homeDirectory)/Library/**/Temporary",
            "\(homeDirectory)/Library/**/Temp",
            "\(homeDirectory)/Library/**/Temp*",
            "\(homeDirectory)/Library/**/*TempItems",
            "\(homeDirectory)/Library/**/WebCache",
            "\(homeDirectory)/Library/**/*CACHE*",
            "\(homeDirectory)/Library/**/*Cache*",
            "\(homeDirectory)/Library/**/*cache*",
            "\(homeDirectory)/Library/**/temp",
            "\(homeDirectory)/Library/**/temp*",
            "\(homeDirectory)/Library/**/tmp",
            "\(homeDirectory)/Library/**/tmp*",
            "\(homeDirectory)/Library/Caches",
            "\(homeDirectory)/Library/Daemon Containers",
            "\(homeDirectory)/Library/DataAccess",
            "\(homeDirectory)/Library/DataDeliveryServices",
            "\(homeDirectory)/Library/DES",
            "\(homeDirectory)/Library/DiagnosticReports",
            "\(homeDirectory)/Library/DoNotDisturb",
            "\(homeDirectory)/Library/DuetExpertCenter",
            "\(homeDirectory)/Library/**/CacheSnap",
            "\(homeDirectory)/Library/**/fsCachedData",
            "\(homeDirectory)/Library/**/SentryCrash",
            "\(homeDirectory)/Library/**/*Diagnostic*",
            "\(homeDirectory)/Library/**/*diagnostic*",
            "\(homeDirectory)/Library/**/*Telemetry*",
            "\(homeDirectory)/Library/**/*telemetry*",
            "\(homeDirectory)/Library/Family",
            "\(homeDirectory)/Library/FileProvider",
            "\(homeDirectory)/Library/FrontBoard",
            "\(homeDirectory)/Library/GameKit",
            "\(homeDirectory)/Library/HomeKit",
            "\(homeDirectory)/Library/HTTPStorages",
            "\(homeDirectory)/Library/IdentityCaches",
            "\(homeDirectory)/Library/IdentityServices",
            "\(homeDirectory)/Library/IntelligencePlatform",
            "\(homeDirectory)/Library/LanguageModeling/TrialData",
            "\(homeDirectory)/Library/Logs",
            "\(homeDirectory)/Library/Mail Downloads",
            "\(homeDirectory)/Library/Maps",
            "\(homeDirectory)/Library/Messages",
            "\(homeDirectory)/Library/Metadata",
            "\(homeDirectory)/Library/PersonalizationPortrait",
            "\(homeDirectory)/Library/PrivateCloudCompute",
            "\(homeDirectory)/Library/News",
            "\(homeDirectory)/Library/Photos",
            "\(homeDirectory)/Library/Passes",
            "\(homeDirectory)/Library/Reminders",
            "\(homeDirectory)/Library/ResponseKit",
            "\(homeDirectory)/Library/Safari",
            "\(homeDirectory)/Library/SafariSafeBrowsing",
            "\(homeDirectory)/Library/SafariSandboxBroker",
            "\(homeDirectory)/Library/Saved Application State",
            "\(homeDirectory)/Library/ScreenRecordings",
            "\(homeDirectory)/Library/Shortcuts",
            "\(homeDirectory)/Library/Spotlight",
            "\(homeDirectory)/Library/StatusKit",
            "\(homeDirectory)/Library/Suggestions",
            "\(homeDirectory)/Library/SyncedPreferences",
            "\(homeDirectory)/Library/Translation",
            "\(homeDirectory)/Library/Trial",
            "\(homeDirectory)/Library/UIKitSystem",
            "\(homeDirectory)/Library/UnifiedAssetFramework",
            "\(homeDirectory)/Library/VoiceTrigger",
            "\(homeDirectory)/Library/Weather",
            "\(homeDirectory)/Library/com.apple.aiml.instrumentation",
            "\(homeDirectory)/Library/com.apple.appleaccountd",
            "\(homeDirectory)/Library/com.apple.AppleMediaServices",
            "\(homeDirectory)/Library/com.apple.bluetooth.services.cloud",
            "\(homeDirectory)/Library/com.apple.bluetoothuser",
            "\(homeDirectory)/Library/com.apple.internal.ck",
            "\(homeDirectory)/Library/com.apple.iTunesCloud",
            "\(homeDirectory)/Library/Mobile Documents",
            "\(homeDirectory)/Library/Java/JavaVirtualMachines",
            "\(homeDirectory)/Library/Jupyter/runtime",
            "\(homeDirectory)/Library/org.swift.swiftpm",
            "\(homeDirectory)/Library/pnpm",
            "\(homeDirectory)/Library/Python",
            "\(homeDirectory)/Library/Ruby/Gems",
            "\(homeDirectory)/Library/Developer/CoreSimulator",
            "\(homeDirectory)/Library/Developer/CoreDevice",
            "\(homeDirectory)/Library/Developer/DeveloperDiskImages",
            "\(homeDirectory)/Library/Developer/Toolchains",
            "\(homeDirectory)/Library/Developer/XCPGDevices",
            "\(homeDirectory)/Library/Developer/XCTestDevices",
            "\(homeDirectory)/Library/Developer/Xcode/Archives",
            "\(homeDirectory)/Library/Developer/Xcode/DerivedData",
            "\(homeDirectory)/Library/Developer/Xcode/DeviceSupport",
            "\(homeDirectory)/Library/Developer/Xcode/DocumentationCache",
            "\(homeDirectory)/Library/Developer/Xcode/DocumentationIndex",
            "\(homeDirectory)/Library/Developer/Xcode/Products",
            "\(homeDirectory)/Library/Developer/Xcode/UserData/Previews/Simulator Devices",
            "\(homeDirectory)/Library/Developer/Xcode/iOS DeviceSupport",
            "\(homeDirectory)/Library/Developer/Xcode/iOS Device Logs",
            "\(homeDirectory)/Library/Developer/Xcode/tvOS DeviceSupport",
            "\(homeDirectory)/Library/Developer/Xcode/watchOS DeviceSupport",
            "\(homeDirectory)/Library/Developer/Xcode/watchOS Device Logs",
            "\(homeDirectory)/Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches",
            "\(homeDirectory)/Library/Containers/*/Data/Library/Caches",
            "\(homeDirectory)/Library/Containers/*/Data/Library/Logs",
            "\(homeDirectory)/Library/Containers/*/Data/Library/Saved Application State",
            "\(homeDirectory)/Library/Containers/*/Data/tmp",
            "\(homeDirectory)/Library/Containers/com.apple.AddressBook*",
            "\(homeDirectory)/Library/Containers/com.apple.AMPArtworkAgent*",
            "\(homeDirectory)/Library/Containers/com.apple.BKAgentService*",
            "\(homeDirectory)/Library/Containers/com.apple.BKLibraryService*",
            "\(homeDirectory)/Library/Containers/com.apple.Books*",
            "\(homeDirectory)/Library/Containers/com.apple.Calendar*",
            "\(homeDirectory)/Library/Containers/com.apple.CloudDocs*",
            "\(homeDirectory)/Library/Containers/com.apple.*Diagnostic*",
            "\(homeDirectory)/Library/Containers/com.apple.*Telemetry*",
            "\(homeDirectory)/Library/Containers/com.apple.DiagnosticExtensions.*",
            "\(homeDirectory)/Library/Containers/com.apple.FaceTime*",
            "\(homeDirectory)/Library/Containers/com.apple.Home*",
            "\(homeDirectory)/Library/Containers/com.apple.MobileSMS*",
            "\(homeDirectory)/Library/Containers/com.apple.Maps*",
            "\(homeDirectory)/Library/Containers/com.apple.Notes*",
            "\(homeDirectory)/Library/Containers/com.apple.Photos.PhotosReliveWidget*",
            "\(homeDirectory)/Library/Containers/com.apple.Reminders*",
            "\(homeDirectory)/Library/Containers/com.apple.Safari*",
            "\(homeDirectory)/Library/Containers/com.apple.VoiceMemos*",
            "\(homeDirectory)/Library/Containers/com.apple.contacts*",
            "\(homeDirectory)/Library/Containers/com.apple.freeform*",
            "\(homeDirectory)/Library/Containers/com.apple.iBooks*",
            "\(homeDirectory)/Library/Containers/com.apple.iCal*",
            "\(homeDirectory)/Library/Containers/com.apple.iCloudDrive*",
            "\(homeDirectory)/Library/Containers/com.apple.icloud.apps.messages*",
            "\(homeDirectory)/Library/Containers/com.apple.journal*",
            "\(homeDirectory)/Library/Containers/com.apple.mail*",
            "\(homeDirectory)/Library/Containers/com.apple.messages*",
            "\(homeDirectory)/Library/Containers/com.apple.news*",
            "\(homeDirectory)/Library/Containers/com.apple.podcasts*",
            "\(homeDirectory)/Library/Containers/com.apple.stocks*",
            "\(homeDirectory)/Library/Containers/com.apple.wallpaper*",
            "\(homeDirectory)/Library/Containers/com.apple.weather*",
            "\(homeDirectory)/Library/Containers/com.mimestream*",
            "\(homeDirectory)/Library/Group Containers/*/Library/Caches",
            "\(homeDirectory)/Library/Group Containers/*/Library/Logs",
            "\(homeDirectory)/Library/Group Containers/*/tmp",
            "\(homeDirectory)/Library/Group Containers/*mimestream*",
            "\(homeDirectory)/Library/Group Containers/com.apple.Home.group",
            "\(homeDirectory)/Library/Group Containers/com.apple.MailPersonaStorage",
            "\(homeDirectory)/Library/Group Containers/com.apple.bird",
            "\(homeDirectory)/Library/Group Containers/com.apple.messages",
            "\(homeDirectory)/Library/Group Containers/group.com.apple.CloudDocs",
            "\(homeDirectory)/Library/Group Containers/group.com.apple.FaceTime",
            "\(homeDirectory)/Library/Group Containers/group.com.apple.Journal",
            "\(homeDirectory)/Library/Group Containers/group.com.apple.Maps",
            "\(homeDirectory)/Library/Group Containers/group.com.apple.Photos.PhotosFileProvider",
            "\(homeDirectory)/Library/Group Containers/group.com.apple.Safari.SandboxBroker",
            "\(homeDirectory)/Library/Group Containers/group.com.apple.VoiceMemos.shared",
            "\(homeDirectory)/Library/Group Containers/group.com.apple.calendar",
            "\(homeDirectory)/Library/Group Containers/group.com.apple.contacts",
            "\(homeDirectory)/Library/Group Containers/group.com.apple.freeform",
            "\(homeDirectory)/Library/Group Containers/group.com.apple.iBooks",
            "\(homeDirectory)/Library/Group Containers/group.com.apple.iCloudDrive",
            "\(homeDirectory)/Library/Group Containers/group.com.apple.mail",
            "\(homeDirectory)/Library/Group Containers/group.com.apple.notes",
            "\(homeDirectory)/Library/Group Containers/group.com.apple.notes.import",
            "\(homeDirectory)/Library/Group Containers/group.com.apple.reminders",
            "\(homeDirectory)/Library/Group Containers/group.com.apple.safari",
            "\(homeDirectory)/Library/Group Containers/group.com.apple.weather",
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
            "\(homeDirectory)/Library/Application Support/Steam/steamapps/common",
            "\(homeDirectory)/Library/Application Support/Steam/steamapps/downloading",
            "\(homeDirectory)/Library/Application Support/Steam/steamapps/workshop",
            "\(homeDirectory)/Library/Application Support/Steam/steamapps/shadercache",
            "\(homeDirectory)/Library/Caches/Homebrew",
            "\(homeDirectory)/Library/Mail/*/MailData/AvailableFeeds",
            "\(homeDirectory)/Library/Mail/*/MailData/Envelope Index",
            "\(homeDirectory)/Library/Mail/*/MailData/Envelope Index-shm",
            "\(homeDirectory)/Library/Mail/*/MailData/Envelope Index-wal",
            "\(homeDirectory)/Library/iTunes/iPad Software Updates",
            "\(homeDirectory)/Library/iTunes/iPhone Software Updates",
            "\(homeDirectory)/Library/iTunes/iPod Software Updates",
            "\(homeDirectory)/Library/Downloads/*.dmg",
            "\(homeDirectory)/Library/Downloads/*.iso",
            "\(homeDirectory)/Library/Downloads/*.mpkg",
            "\(homeDirectory)/Library/Downloads/*.pkg",
            "\(homeDirectory)/Library/Downloads/*.xip",
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
        ].appendingUnique(Self.goCacheExcludes(for: homeDirectory))
    }

    private static func goCacheExcludes(for homeDirectory: String) -> [String] {
        let goEnvironment = goEnvironment(for: homeDirectory)
        let goPaths = pathList(from: goEnvironment["GOPATH"], homeDirectory: homeDirectory)
        let goModuleCaches = pathList(from: goEnvironment["GOMODCACHE"], homeDirectory: homeDirectory)
        let goBuildCaches = pathList(from: goEnvironment["GOCACHE"], homeDirectory: homeDirectory)

        var excludes = goModuleCaches
        for goPath in goPaths {
            excludes.append("\(goPath)/pkg/mod")
            excludes.append("\(goPath)/pkg/sumdb")
        }
        excludes.append(contentsOf: goBuildCaches)
        return excludes
            .filter { path($0, isInside: homeDirectory) }
            .appendingUnique([])
    }

    private static func goEnvironment(for homeDirectory: String) -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        var values = ["GOPATH": "\(homeDirectory)/go"]
        for key in ["GOPATH", "GOMODCACHE", "GOCACHE"] where environment[key]?.isEmpty == false {
            values[key] = environment[key]
        }

        guard let output = runGoEnv(for: homeDirectory) else {
            return values
        }

        let keys = ["GOPATH", "GOMODCACHE", "GOCACHE"]
        for (key, value) in zip(keys, output.split(separator: "\n", omittingEmptySubsequences: false)) where !value.isEmpty {
            values[key] = String(value)
        }
        return values
    }

    private static func runGoEnv(for homeDirectory: String) -> String? {
        do {
            let process = Process()
            process.qualityOfService = .utility
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = ["go", "env", "GOPATH", "GOMODCACHE", "GOCACHE"]
            process.environment = ProcessInfo.processInfo.environment.merging([
                "HOME": homeDirectory,
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            ]) { _, new in new }

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return nil
            }
            return String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        } catch {
            return nil
        }
    }

    private static func pathList(from value: String?, homeDirectory: String) -> [String] {
        guard let value, !value.isEmpty else {
            return []
        }

        return value
            .split(separator: ":", omittingEmptySubsequences: true)
            .compactMap { normalizedPath(String($0), homeDirectory: homeDirectory) }
            .appendingUnique([])
    }

    private static func normalizedPath(_ path: String, homeDirectory: String) -> String? {
        guard !path.isEmpty else {
            return nil
        }

        return path
            .replacingOccurrences(of: "$HOME", with: homeDirectory)
            .replacingOccurrences(of: "${HOME}", with: homeDirectory)
            .replacingOccurrences(of: "~", with: homeDirectory, options: [.anchored])
            .deletingTrailingSlashes
    }

    private static func path(_ path: String, isInside directory: String) -> Bool {
        let path = path.deletingTrailingSlashes
        let directory = directory.deletingTrailingSlashes
        return path == directory || path.hasPrefix("\(directory)/")
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

    private var smartBackupHomeDirectories: [String] {
        guard intelligentMacOSBackupEnabled else {
            return []
        }

        return Self.includedHomeDirectories(includes)
    }

    private var effectiveIncludes: [String] {
        includes
    }

    private func effectiveExcludes(homeDirectories: [String]) -> [String] {
        guard intelligentMacOSBackupEnabled else {
            return excludes
        }

        var effectiveExcludes = excludes.appendingUnique(Self.intelligentMacOSGeneralExcludes)
        for homeDirectory in homeDirectories {
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

            let smartBackupHomeDirectories = self.smartBackupHomeDirectories
            let effectiveIncludes = self.effectiveIncludes
            let effectiveExcludes = self.effectiveExcludes(homeDirectories: smartBackupHomeDirectories)
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
                smartBackupHomeDirectories: smartBackupHomeDirectories,
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
                            if let nextScheduledBackupDate {
                                backupTimer?.fireDate = nextScheduledBackupDate
                            }
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
            let timer = Timer(timeInterval: intervalSeconds, repeats: false) { [weak self] _ in
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
        let shouldRun = lock.withLock {
            guard status == .idle else {
                nextScheduledBackupDate = nextBackupDate(from: Date())
                if let nextScheduledBackupDate {
                    TypeLogger.function().info("Skipped scheduled backup because another backup is in progress, next backup: \(nextScheduledBackupDate, privacy: .public)")
                } else {
                    TypeLogger.function().info("Skipped scheduled backup because another backup is in progress")
                }
                return false
            }
            return true
        }

        guard shouldRun else {
            rescheduleBackup()
            return
        }

        backup { error in
            if let error {
                TypeLogger.function().error("Failed to run scheduled backup: \(error.localizedDescription, privacy: .public)")
                self.lock.withLock {
                    self.nextScheduledBackupDate = self.nextBackupDate(from: Date())
                }
            } else {
                TypeLogger.function().info("Finished scheduled backup")
            }
            self.rescheduleBackup()
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
