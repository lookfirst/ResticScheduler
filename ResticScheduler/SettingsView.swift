import AppKit
import SwiftUI

struct SettingsView: View {
    private enum Tab: Int, Hashable {
        case general, restic, advanced
    }

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(Tab.general)
            ResticSettingsView()
                .tabItem {
                    Label("Connection", systemImage: "umbrella")
                }
                .tag(Tab.restic)
            AdvancedSettingsView()
                .tabItem {
                    Label("Configuration", systemImage: "gearshape.2")
                }
                .tag(Tab.advanced)
        }
        .padding(.horizontal, 40)
        .frame(minWidth: 880, minHeight: 680)
        .background(SettingsWindowConfigurator())
    }
}

enum SettingsWindow {
    static func configure(_ window: NSWindow?) {
        guard let window, isSettingsWindow(window) else {
            return
        }

        window.styleMask.insert(.resizable)
        window.collectionBehavior.remove(.fullScreenNone)
        window.minSize = NSSize(width: 880, height: 680)
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        window.showsResizeIndicator = true
    }

    static func configureOpenWindows() {
        NSApp.windows.forEach(configure)
    }

    static func configureOpenWindowsSoon() {
        DispatchQueue.main.async {
            configureOpenWindows()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            configureOpenWindows()
        }
    }

    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue.contains("Settings") == true {
            return true
        }

        return window.title == "Restic"
    }
}

struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            SettingsWindow.configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            SettingsWindow.configure(nsView.window)
        }
    }
}

final class SettingsWindowController {
    private static var window: NSWindow?

    static func show(resticScheduler: ResticScheduler) {
        if let window {
            SettingsWindow.configure(window)
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = SettingsView()
            .environmentObject(resticScheduler)
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("ResticSchedulerSettingsWindow")
        window.title = "Restic"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 880, height: 680)
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        window.showsResizeIndicator = true
        window.center()

        self.window = window
        SettingsWindow.configure(window)
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

#Preview {
    SettingsView()
}
