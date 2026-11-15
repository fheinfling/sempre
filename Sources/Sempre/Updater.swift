import AppKit
import SempreCore

/// Checks GitHub for a newer published release and installs it when asked.
/// Checking is automatic and quiet: a minute after launch and then once a day (unless turned off), and on demand
/// from the menu. A newer version shows as a line in the panel; downloading and installing only happen on its
/// Update button. A helper swaps the app once it has quit and puts the old one back if the new one doesn't start.
@MainActor
final class Updater: ObservableObject {
    static let latestURL = URL(string: "https://api.github.com/repos/fheinfling/sempre/releases/latest")!
    static let autoCheckKey = "checkForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    /// The version handed to the install helper, until a launch shows whether it took.
    private static let pendingKey = "installingUpdate"

    enum Phase: Equatable {
        case available, downloading, verifying, installing
        case failed(String)

        var isBusy: Bool { [.downloading, .verifying, .installing].contains(self) }
    }

    /// A newer version and how far installing it got; nil while there's none.
    struct Offer: Equatable {
        var release: Updates.Release
        var phase: Phase
    }

    @Published private(set) var offer: Offer?
    @Published private(set) var checking = false
    private var timer: Timer?
    private let session = URLSession(configuration: .ephemeral)
    /// A version whose install didn't take: offered again as failed rather than as new.
    private var failedVersion: String?

    /// nil when not running from a built app (e.g. `swift run`).
    private var current: String? { Updates.version(of: Bundle.main.bundleURL) }

    /// Downloads, the helper's log and the file a new version acknowledges itself in: local, never in iCloud.
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sempre/Updates")
    static var ackFile: URL { folder.appendingPathComponent("update-ack") }
    static var logFile: URL { folder.appendingPathComponent("update.log") }

    /// `automatic: false` for developer commands: no scheduled checks, and nothing acknowledged.
    init(automatic: Bool = true) {
        UserDefaults.standard.register(defaults: [Self.autoCheckKey: true])
        guard automatic, let current else { return }
        // Tell an install helper that's waiting that this version came up: only then does it delete the old app.
        Updates.acknowledge(Self.ackFile, version: current)
        var firstCheck: TimeInterval = 60
        if let pending = UserDefaults.standard.string(forKey: Self.pendingKey) {
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
            if pending != current {
                // The helper put this version back (or never got to swap): say so as soon as the release is known.
                failedVersion = pending
                firstCheck = 5
            }
        }
        // Hourly tick; the daily check only happens when a day has passed since the last one.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + firstCheck) { [weak self] in
            if self?.failedVersion != nil { Task { await self?.check(userInitiated: false) } } else { self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        let d = UserDefaults.standard
        guard d.bool(forKey: Self.autoCheckKey) else { return }
        let last = d.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 23 * 3600 else { return }
        Task { await check(userInitiated: false) }
    }

    /// Asks GitHub for the latest release. A newer one becomes the panel's update line; only a check the user
    /// asked for says "up to date" or reports an error. A failed check never forgets an update already known.
    func check(userInitiated: Bool) async {
        guard !checking, offer?.phase.isBusy != true else { return }
        guard let current else {
            if userInitiated { inform("Can't check for updates", "This copy of Sempre wasn't built as an app, so it has no version to compare.") }
            return
        }
        checking = true
        defer { checking = false }
        let latest: Updates.Release
        do {
            latest = try await fetchLatest()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        } catch {
            if userInitiated { inform("Couldn't check for updates", error.localizedDescription) }
            return
        }
        guard Updates.isNewer(latest.version, than: current) else {
            offer = nil
            if userInitiated { inform("You're up to date", "Sempre \(current) is the latest version.") }
            return
        }
        if let known = offer, known.release.version == latest.version {
            offer?.release = latest
        } else if failedVersion == latest.version {
            offer = Offer(release: latest, phase: .failed("The update didn't finish, so Sempre \(current) is still installed (details in \(Self.logFile.path))."))
        } else {
            offer = Offer(release: latest, phase: .available)
        }
        failedVersion = nil
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

    /// The update line's Update (or Try Again): downloads and verifies the release, hands it to the install
    /// helper and quits; the helper reopens Sempre. Any problem shows in the line, with nothing changed.
    func install() async {
        guard let offer, !offer.phase.isBusy, let current else { return }
        let release = offer.release
        var staged: URL?
        do {
            // Whether this copy can be replaced in place, before downloading anything.
            let app = Bundle.main.bundleURL
            guard app.pathExtension == "app", let requirement = Updates.requirement(of: app),
                  let requirementText = Updates.text(of: requirement) else {
                throw Updates.UpdateError(message: "This copy of Sempre isn't a signed app; download the update from its release page.")
            }
            guard !app.path.contains("/AppTranslocation/") else {
                throw Updates.UpdateError(message: "macOS is running Sempre from a temporary location; move it to Applications first.")
            }
            guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
                throw Updates.UpdateError(message: "Sempre can't replace itself in \(app.deletingLastPathComponent().path); download the update from its release page.")
            }
            self.offer?.phase = .downloading
            let new = try await downloadAndVerify(release, satisfying: requirement, newerThan: current)
            staged = new
            self.offer?.phase = .installing
            try startHelper(Updates.installCommand(staged: new, target: app, pid: ProcessInfo.processInfo.processIdentifier,
                                                   ack: Self.ackFile, expected: current, requirement: requirementText))
            UserDefaults.standard.set(release.version, forKey: Self.pendingKey)
            // The helper waits for this process to exit, swaps the app and reopens it.
            NSApp.terminate(nil)
        } catch {
            // Once the helper runs it owns the download; before that, it goes.
            if let staged { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
            self.offer?.phase = .failed(error.localizedDescription)
        }
    }

    /// Downloads the release zip into a fresh folder of its own and returns the unpacked app once it has passed
    /// every check: size and checksum, notarization and signature, version, and whether it runs here.
    /// On failure the folder is removed.
    func downloadAndVerify(_ release: Updates.Release, satisfying requirement: SecRequirement, newerThan current: String) async throws -> URL {
        guard let url = release.download, let sha256 = release.sha256 else {
            throw Updates.UpdateError(message: "This release has no download Sempre can check.")
        }
        // A release zip is ~3 MB; refuse anything that announces itself as far bigger before downloading it.
        guard let size = release.size, size <= 100_000_000 else {
            throw Updates.UpdateError(message: "The download is too large to be Sempre.")
        }
        let dir = Self.folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let (file, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw Updates.UpdateError(message: "The download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
            }
            if (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) != size {
                throw Updates.UpdateError(message: "The download is incomplete.")
            }
            offer?.phase = .verifying
            // Hashing, unzipping and checking every architecture take a moment; keep them off the main thread.
            let new = try await Task.detached {
                guard try Updates.sha256(of: file) == sha256 else {
                    throw Updates.UpdateError(message: "The download is corrupted (its checksum doesn't match the release).")
                }
                let new = try Updates.unpack(zip: file, into: dir)
                try Updates.verify(app: new, satisfies: requirement, notarized: true)
                try Updates.checkRunsHere(new)
                return new
            }.value
            guard let version = Updates.version(of: new), version == release.version, Updates.isNewer(version, than: current) else {
                throw Updates.UpdateError(message: "The download isn't version \(release.version).")
            }
            return new
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// Starts the helper, which outlives Sempre; what it says goes to the update log, so a failed restore isn't silent.
    private func startHelper(_ arguments: [String]) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.logFile.path) { fm.createFile(atPath: Self.logFile.path, contents: nil) }
        let log = try FileHandle(forWritingTo: Self.logFile)
        try log.seekToEnd()
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = arguments
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = log
        helper.standardError = log
        try helper.run()
        try? log.close()
    }

    func openReleasePage() {
        if let page = offer?.release.page { NSWorkspace.shared.open(page) }
    }

    private func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// For snapshots: an update line in the given phase.
    func show(_ release: Updates.Release, _ phase: Phase) { offer = Offer(release: release, phase: phase) }
}
