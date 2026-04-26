import AppKit
import ResticSchedulerKit
import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    private enum BackupFrequencyType: Int {
        case manually = 0
        case hourly = 3600
        case daily = 86400
        case weekly = 604_800
        case custom = -1
        case customize = -2
    }

    private typealias TypeLogger = ResticSchedulerKit.TypeLogger<GeneralSettingsView>

    @State private var customizeFrequency = false
    @State private var launchAtLogin = false
    @State private var isUpdatingLaunchAtLogin = false
    @EnvironmentObject private var resticScheduler: ResticScheduler
    @UserDefault(\.backupFrequency) private var backupFrequency

    private static func isLaunchAtLoginEnabled(_ status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled, .requiresApproval:
            true
        default:
            false
        }
    }

    private func refreshLaunchAtLogin() {
        launchAtLogin = Self.isLaunchAtLoginEnabled(SMAppService.mainApp.status)
    }

    @MainActor
    private func setLaunchAtLogin(_ newValue: Bool) async {
        let previousValue = launchAtLogin
        launchAtLogin = newValue
        isUpdatingLaunchAtLogin = true
        defer { isUpdatingLaunchAtLogin = false }

        do {
            let service = SMAppService.mainApp
            let status = service.status

            if newValue {
                if !Self.isLaunchAtLoginEnabled(status) {
                    try service.register()
                }
            } else if Self.isLaunchAtLoginEnabled(status) {
                try await service.unregister()
            }

            refreshLaunchAtLogin()
            try? await Task.sleep(for: .milliseconds(300))
            refreshLaunchAtLogin()
        } catch {
            launchAtLogin = previousValue
            TypeLogger.function().error("\(error.localizedDescription, privacy: .public)")

            let alert = NSAlert()
            alert.messageText = "Restic Scheduler couldn't change the launch at login setting."
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    var body: some View {
        VStack {
            Form {
                let launchAtLoginBinding = Binding<Bool> {
                    launchAtLogin
                } set: { newValue in
                    Task {
                        await setLaunchAtLogin(newValue)
                    }
                }

                Toggle("Launch at login", isOn: launchAtLoginBinding)
                    .allowsHitTesting(!isUpdatingLaunchAtLogin)
                    .padding(.bottom, 10)

                let backupFrequencyType = Binding<BackupFrequencyType> {
                    if let backupFrequencyType = BackupFrequencyType(rawValue: backupFrequency) {
                        backupFrequencyType
                    } else {
                        .custom
                    }
                } set: { newValue in
                    switch newValue {
                    case .custom:
                        break
                    case .customize:
                        customizeFrequency = true
                    default:
                        backupFrequency = newValue.rawValue
                    }
                }

                Picker("Backup frequency:", selection: backupFrequencyType) {
                    if backupFrequencyType.wrappedValue == .custom {
                        Group {
                            let frequency = Frequency(seconds: backupFrequency)

                            Text("Automatically every \(frequency.amount) \(frequency.unit)")
                                .tag(BackupFrequencyType.custom)
                            Divider()
                        }
                    }
                    Text("Automatically every hour")
                        .tag(BackupFrequencyType.hourly)
                    Text("Automatically every day")
                        .tag(BackupFrequencyType.daily)
                    Text("Automatically every week")
                        .tag(BackupFrequencyType.weekly)
                    Text("Manually")
                        .tag(BackupFrequencyType.manually)
                    Divider()
                    Text("Custom…")
                        .tag(BackupFrequencyType.customize)
                }
                .sheet(isPresented: $customizeFrequency, onDismiss: { customizeFrequency = false }) {
                    FrequencySettingsView()
                }
            }
            .frame(width: 400, alignment: .center)
            .padding()
        }
        .onAppear(perform: refreshLaunchAtLogin)
        .onChange(of: backupFrequency) { _ in
            resticScheduler.backupFrequencyDidChange()
        }
    }
}

#Preview {
    GeneralSettingsView()
}
