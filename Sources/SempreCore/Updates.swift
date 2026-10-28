import Foundation
import Security

/// Over-the-air updates from GitHub Releases: what the latest release is, whether a download is genuine,
/// and swapping it in. The app's Updater does the networking, asking and relaunching.
///
/// Trust doesn't rest on GitHub alone: a new version is only installed if it's notarized and satisfies
/// the running app's own designated requirement (same bundle identifier, same Developer ID team).
public enum Updates {
    /// A published release, as GitHub's `releases/latest` endpoint describes it (drafts and pre-releases never appear there).
    public struct Release: Equatable, Sendable {
        /// "1.2" for the tag "v1.2".
        public var version: String
        public var notes: String
        public var page: URL
        /// The `Sempre-v1.2.zip` asset, if the release has one.
        public var download: URL?
        public var size: Int?

        public init(version: String, notes: String, page: URL, download: URL? = nil, size: Int? = nil) {
            self.version = version
            self.notes = notes
            self.page = page
            self.download = download
            self.size = size
        }
    }

    public struct UpdateError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    private struct APIRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int
        }
        let tag_name: String
        let body: String?
        let html_url: URL
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    /// Reads the JSON of GitHub's `releases/latest`.
    public static func parseLatest(_ data: Data) throws -> Release {
        guard let r = try? JSONDecoder().decode(APIRelease.self, from: data) else {
            throw UpdateError(message: "GitHub's answer wasn't a release.")
        }
        guard r.draft != true, r.prerelease != true else { throw UpdateError(message: "The latest release isn't published yet.") }
        // The page gets opened as a fallback, so like the download it has to be a web address.
        guard r.html_url.scheme == "https" else { throw UpdateError(message: "GitHub's answer wasn't a release.") }
        let asset = r.assets.first { $0.name == "Sempre-\(r.tag_name).zip" && $0.browser_download_url.scheme == "https" }
        return Release(version: strip(r.tag_name), notes: r.body ?? "", page: r.html_url,
                       download: asset?.browser_download_url, size: asset?.size)
    }

    /// Compares dotted versions number by number ("1.10" is newer than "1.9"); a leading "v" is ignored.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    public enum Decision: Equatable, Sendable {
        case upToDate
        case available(Release)
        /// Newer, but the user chose to skip this version.
        case skipped(Release)
    }

    public static func decide(latest: Release, current: String, skipped: String?) -> Decision {
        guard isNewer(latest.version, than: current) else { return .upToDate }
        return skipped.map(strip) == latest.version ? .skipped(latest) : .available(latest)
    }

    // MARK: Verifying a download

    /// The requirement a new version has to meet: the designated requirement of the app at `app`.
    /// nil unless it's signed by a Developer ID team; ad-hoc and unsigned builds can't vouch for anything.
    public static func requirement(of app: URL) -> SecRequirement? {
        guard let code = staticCode(app) else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] is String else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// Throws unless the app's signature is intact (all architectures, nested code) and satisfies `requirement`,
    /// and, when asked, carries Apple's notarization.
    public static func verify(app: URL, satisfies requirement: SecRequirement, notarized: Bool) throws {
        guard let code = staticCode(app) else { throw UpdateError(message: "The download isn't an app.") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdateError(message: "The download isn't signed by Sempre's developer.")
        }
        guard notarized else { return }
        var isNotarized: SecRequirement?
        guard SecRequirementCreateWithString("notarized" as CFString, [], &isNotarized) == errSecSuccess,
              let isNotarized, SecStaticCodeCheckValidity(code, flags, isNotarized) == errSecSuccess else {
            throw UpdateError(message: "The download isn't notarized by Apple.")
        }
    }

    /// CFBundleShortVersionString of the app at `app`.
    public static func version(of app: URL) -> String? {
        Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Throws unless the app can start on this Mac: its minimum macOS version and its processor architecture.
    /// Checked before the swap, so an update that couldn't launch never replaces one that can.
    public static func checkRunsHere(_ app: URL, os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) throws {
        guard let bundle = Bundle(url: app) else { throw UpdateError(message: "The download isn't an app.") }
        if let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String {
            let p = minimum.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]
            guard (os.majorVersion, os.minorVersion, os.patchVersion) >= (p[0], p[1], p[2]) else {
                throw UpdateError(message: "This version needs macOS \(minimum) or later.")
            }
        }
        #if arch(arm64)
        let here = NSBundleExecutableArchitectureARM64
        #else
        let here = NSBundleExecutableArchitectureX86_64
        #endif
        guard bundle.executableArchitectures?.contains(NSNumber(value: here)) == true else {
            throw UpdateError(message: "This version doesn't run on this Mac's processor.")
        }
    }

    // MARK: Installing

    /// Unpacks a release zip into `dir` and returns the Sempre.app inside it. Before anything is written the zip
    /// has to hold nothing but Sempre.app and stay within a size budget (a release is ~10 entries, ~5 MB), and
    /// afterwards Sempre.app has to be a real folder: a symlink would pass every check by pointing at a genuine
    /// app elsewhere in the archive, then dangle once it's moved into place.
    public static func unpack(zip: URL, into dir: URL, maxEntries: Int = 2000, maxBytes: Int = 200_000_000) throws -> URL {
        let names = try zipinfo(["-1", zip.path]).split(separator: "\n").map(String.init)
        guard !names.isEmpty, names.allSatisfy({ $0 == "Sempre.app/" || ($0.hasPrefix("Sempre.app/") && !$0.split(separator: "/").contains("..")) }) else {
            throw UpdateError(message: "The download contains more than Sempre.app.")
        }
        // "10 files, 5263719 bytes uncompressed, 2168572 bytes compressed:  58.8%"
        let totals = try zipinfo(["-t", zip.path]).split(separator: " ").compactMap { Int($0) }
        guard totals.count >= 2, totals[0] <= maxEntries, totals[1] <= maxBytes else {
            throw UpdateError(message: "The download is too large to be Sempre.")
        }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, dir.path]
        try ditto.run()
        ditto.waitUntilExit()
        let app = dir.appendingPathComponent("Sempre.app")
        let kind = try? app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard ditto.terminationStatus == 0, kind?.isSymbolicLink == false, kind?.isDirectory == true else {
            throw UpdateError(message: "The download doesn't contain Sempre.app.")
        }
        return app
    }

    private static func zipinfo(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError(message: "The download isn't a valid zip.") }
        return String(decoding: data, as: UTF8.self)
    }

    /// Swaps `new` into the place of `current` in one step (both must be on the same volume) and returns
    /// where the old version ended up, next to the new one, for the caller to move to the Trash.
    /// The old version gets a name nothing else has, so no existing file is ever overwritten.
    @discardableResult
    public static func replace(_ current: URL, with new: URL) throws -> URL {
        let backupName = "Sempre (replaced \(UUID().uuidString.prefix(8))).app"
        _ = try FileManager.default.replaceItemAt(current, withItemAt: new, backupItemName: backupName,
                                                  options: .withoutDeletingBackupItem)
        return current.deletingLastPathComponent().appendingPathComponent(backupName)
    }

    private static func staticCode(_ app: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }

    private static func strip(_ v: String) -> String { v.hasPrefix("v") ? String(v.dropFirst()) : v }
    private static func parts(_ v: String) -> [Int] { strip(v).split(separator: ".").map { Int($0) ?? 0 } }
}
