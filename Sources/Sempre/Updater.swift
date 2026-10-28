import AppKit
import SempreCore

/// Checks GitHub for a newer published release, asks, and installs it in place.
/// Checks a minute after launch and then once a day (unless turned off), and on demand from the menu.
@MainActor
final class Updater: ObservableObject {
    static let latestURL = URL(string: "https://api.github.com/repos/fheinfling/sempre/releases/latest")!
    static let autoCheckKey = "checkForUpdates"
    private static let skippedKey = "skippedVersion"
    private static let lastCheckKey = "lastUpdateCheck"

    @Published private(set) var busy = false
    private var timer: Timer?
    private let session = URLSession(configuration: .ephemeral)

    /// nil when not running from a built app (e.g. `swift run`).
    private var current: String? { Updates.version(of: Bundle.main.bundleURL) }

    init() {
        UserDefaults.standard.register(defaults: [Self.autoCheckKey: true])
        guard current != nil else { return }
        // Hourly tick; the daily check only happens when a day has passed since the last one.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        let d = UserDefaults.standard
        guard d.bool(forKey: Self.autoCheckKey), !busy else { return }
        let last = d.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 23 * 3600 else { return }
        Task { await check(userInitiated: false) }
    }

    /// Asks GitHub for the latest release and offers it. Only a check the user asked for reports
    /// "up to date" or errors, and offers a version they skipped before.
    func check(userInitiated: Bool) async {
        guard !busy, let current else { return }
        busy = true
        defer { busy = false }
        do {
            let latest = try await fetchLatest()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            switch Updates.decide(latest: latest, current: current, skipped: UserDefaults.standard.string(forKey: Self.skippedKey)) {
            case .available(let r): await offer(r, current: current)
            case .skipped(let r): if userInitiated { await offer(r, current: current) }
            case .upToDate: if userInitiated { inform("You're up to date", "Sempre \(current) is the latest version.") }
            }
        } catch {
            if userInitiated { inform("Couldn't check for updates", error.localizedDescription) }
        }
    }

    func fetchLatest() async throws -> Updates.Release {
        var request = URLRequest(url: Self.latestURL, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Sempre/\(current ?? "dev")", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Updates.UpdateError(message: "GitHub didn't answer (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        return try Updates.parseLatest(data)
    }

    private func offer(_ release: Updates.Release, current: String) async {
        let alert = NSAlert()
        alert.messageText = "Sempre \(release.version) is available"
        alert.informativeText = "You have \(current).\n\n" + Self.summary(release.notes)
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: await install(release)
        case .alertThirdButtonReturn: UserDefaults.standard.set(release.version, forKey: Self.skippedKey)
        default: break
        }
    }

    /// Downloads, verifies and swaps in the release, then relaunches. Where it can't install by itself
    /// (development build, read-only or translocated location), it opens the release page instead.
    private func install(_ release: Updates.Release) async {
        let app = Bundle.main.bundleURL
        guard let requirement = Updates.requirement(of: app), let download = release.download,
              !app.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(release.page)
            return
        }
        do {
            let new = try await downloadAndVerify(release, from: download, satisfying: requirement,
                                                  nextTo: app, newerThan: current ?? "0")
            let old = try Updates.replace(app, with: new)
            try? FileManager.default.trashItem(at: old, resultingItemURL: nil)
            relaunch(app)
        } catch {
            inform("Couldn't install Sempre \(release.version)", error.localizedDescription + "\n\nYou can download it from the release page instead.")
            NSWorkspace.shared.open(release.page)
        }
    }

    /// Downloads the release zip into a folder on the same volume as `app` (so the swap is a single
    /// rename) and returns the unpacked app once it has passed every check.
    func downloadAndVerify(_ release: Updates.Release, from url: URL, satisfying requirement: SecRequirement,
                           nextTo app: URL, newerThan current: String) async throws -> URL {
        let dir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        let (file, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Updates.UpdateError(message: "The download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        if let size = release.size, (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) != size {
            throw Updates.UpdateError(message: "The download is incomplete.")
        }
        let new = try Updates.unpack(zip: file, into: dir)
        try Updates.verify(app: new, satisfies: requirement, notarized: true)
        guard let version = Updates.version(of: new), version == release.version, Updates.isNewer(version, than: current) else {
            throw Updates.UpdateError(message: "The download isn't version \(release.version).")
        }
        return new
    }

    /// Starts the new version once this one has quit. The path goes to the shell as an argument, never as code.
    private func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? shell.run()
        NSApp.terminate(nil)
    }

    private func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Release notes as plain text, short enough for an alert.
    static func summary(_ notes: String) -> String {
        let lines = notes.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("**Full Changelog**") }
            .map { $0.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression) }
        let text = lines.prefix(12).joined(separator: "\n")
        return text.count > 600 ? String(text.prefix(600)) + "…" : text
    }
}
