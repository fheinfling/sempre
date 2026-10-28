import SwiftUI
import SempreCore
import ServiceManagement

@main
struct SempreApp: App {
    // Owned here but deliberately not observed: the menu bar animation ticks 15× a second, and
    // observing it at the app level would rebuild the whole panel each tick (closing open menus).
    // The views that need these objects observe them themselves.
    private let store: Store
    private let ticker: MenuTicker
    private let chime: HourChime
    private let updater: Updater

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        DevCommands.runIfRequested()
        LoginItem.enableOnFirstLaunch()
        store = Store()
        ticker = MenuTicker(store: store)
        chime = HourChime(store: store)
        updater = Updater()
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(store)
                .environmentObject(chime)
                .environmentObject(updater)
                .modifier(FitsWindowToContent())
        } label: {
            MenuBarLabel(store: store, ticker: ticker)
        }
        .menuBarExtraStyle(.window)
    }
}

enum Tab: String, CaseIterable { case track = "Track", stats = "Stats" }

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var tab: Tab
    @State private var importMessage: String?
    @AppStorage("showProjectName") private var showProjectName = true
    @AppStorage("menuBarTime") private var menuBarTime = MenuBarTime.timer
    @AppStorage("chimeStyle") private var chimeStyle = ChimeStyle.brassDust
    @EnvironmentObject var chime: HourChime
    @EnvironmentObject var updater: Updater
    @AppStorage(Updater.autoCheckKey) private var checkForUpdates = true
    @State private var openAtLogin = LoginItem.isEnabled

    init(initialTab: Tab = .track) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            Segmented(options: Tab.allCases, selection: $tab) { $0.rawValue }
                .padding(12)

            Group {
                switch tab {
                case .track: TrackView()
                case .stats: StatsView()
                }
            }

            if let msg = importMessage ?? store.lastError {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: store.usesICloud ? "icloud" : "internaldrive")
            Text(store.usesICloud ? "Synced via iCloud Drive" : "Saved locally")
            Spacer()
            Menu {
                Picker("Menu Bar Time", selection: $menuBarTime) {
                    Text("This Timer").tag(MenuBarTime.timer)
                    Text("Today on This Project").tag(MenuBarTime.projectToday)
                }
                Toggle("Show Project Name in Menu Bar", isOn: $showProjectName)
                Menu("Every Full Hour") {
                    // Toggles rather than a picker: choosing a chime plays it, even when it's already selected.
                    ForEach(ChimeStyle.allCases, id: \.self) { style in
                        Toggle(style.title, isOn: Binding(
                            get: { chimeStyle == style },
                            set: { _ in chimeStyle = style; chime.show(style) }
                        ))
                    }
                }
                Toggle("Open at Login", isOn: Binding(
                    get: { openAtLogin },
                    set: { LoginItem.set($0); openAtLogin = LoginItem.isEnabled }
                ))
                Divider()
                Button("Import CSV…") { runImport() }
                Button("Show Data File") { store.revealDataFile() }
                Divider()
                Text("Sempre \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "(development build)")")
                Button(updater.status == .checking ? "Checking for Updates…"
                       : updater.status == .installing ? "Installing Update…" : "Check for Updates…") {
                    Task { await updater.check(userInitiated: true) }
                }
                .disabled(updater.status != .idle)
                Toggle("Check for Updates Automatically", isOn: $checkForUpdates)
                Divider()
                Button("Quit Sempre") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func runImport() {
        do {
            guard let url = CSVImport.pickFile() else { return }
            let result = try CSVImport.read(url)
            let n = store.importEntries(result.rows)
            importMessage = "Imported \(n.entries) time entries and \(n.projects) new projects."
                + (result.skipped > 0 ? " Skipped \(result.skipped) rows without a start and end." : "")
        } catch {
            importMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}

/// Launch at login via the system's Login Items (System Settings › General › Login Items).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Sempre: login item change failed: \(error)")
        }
    }

    /// Turned on once by default; after that the user's choice sticks.
    static func enableOnFirstLaunch() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key), Bundle.main.bundlePath.hasSuffix(".app") else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}
