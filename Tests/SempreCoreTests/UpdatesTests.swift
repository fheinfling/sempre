import Foundation
import Security
import Testing
@testable import SempreCore

private func release(_ version: String) -> Updates.Release {
    .init(version: version, notes: "", page: URL(string: "https://example.com/\(version)")!)
}

/// GitHub's `releases/latest` answer, trimmed to the fields Sempre reads.
private func latestJSON(tag: String = "v1.2", draft: Bool = false, assets: String? = nil) -> Data {
    let assets = assets ?? """
        [{"name": "Sempre-\(tag).zip", "browser_download_url": "https://github.com/fheinfling/sempre/releases/download/\(tag)/Sempre-\(tag).zip", "size": 2063619},
         {"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt", "size": 10}]
        """
    return Data("""
        {"tag_name": "\(tag)", "body": "## What's Changed\\n* CSV import", "html_url": "https://github.com/fheinfling/sempre/releases/tag/\(tag)",
         "draft": \(draft), "prerelease": false, "assets": \(assets)}
        """.utf8)
}

/// A minimal app bundle, ad-hoc signed by `codesign` under `identifier`, or left unsigned.
private func makeApp(in dir: URL, identifier: String? = "com.example.sempre-test", version: String = "1.2") throws -> URL {
    let app = dir.appendingPathComponent("Sempre.app")
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Sempre"))
    let plist: [String: Any] = ["CFBundleExecutable": "Sempre", "CFBundleIdentifier": identifier ?? "com.example.unsigned",
                                "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    if let identifier {
        try run("/usr/bin/codesign", "--force", "--sign", "-", "--identifier", identifier, app.path)
    }
    return app
}

private func run(_ tool: String, _ args: String...) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0, "\(tool) \(args.joined(separator: " "))")
}

private func requirement(_ text: String) throws -> SecRequirement {
    var r: SecRequirement?
    #expect(SecRequirementCreateWithString(text as CFString, [], &r) == errSecSuccess)
    return try #require(r)
}

@Suite("Updates")
struct UpdatesTests {
    @Test func versionsCompareNumberByNumber() {
        #expect(Updates.isNewer("1.2", than: "1.1"))
        #expect(Updates.isNewer("1.10", than: "1.9"))
        #expect(Updates.isNewer("v2.0", than: "1.9.9"))
        #expect(Updates.isNewer("1.1.1", than: "1.1"))
        #expect(!Updates.isNewer("1.1", than: "1.1"))
        #expect(!Updates.isNewer("1.1", than: "1.1.0"))
        #expect(!Updates.isNewer("1.0", than: "1.1"))
    }

    @Test func readsTheLatestRelease() throws {
        let r = try Updates.parseLatest(latestJSON())
        #expect(r.version == "1.2")
        #expect(r.notes.contains("CSV import"))
        #expect(r.page.absoluteString == "https://github.com/fheinfling/sempre/releases/tag/v1.2")
        #expect(r.download?.lastPathComponent == "Sempre-v1.2.zip")
        #expect(r.size == 2063619)
    }

    @Test func releaseWithoutTheZipStillReportsTheVersion() throws {
        let r = try Updates.parseLatest(latestJSON(assets: "[]"))
        #expect(r.version == "1.2")
        #expect(r.download == nil)
    }

    @Test func onlyHTTPSDownloadsAreUsed() throws {
        let r = try Updates.parseLatest(latestJSON(assets: #"[{"name": "Sempre-v1.2.zip", "browser_download_url": "http://example.com/Sempre-v1.2.zip", "size": 1}]"#))
        #expect(r.download == nil)
    }

    @Test func releasePageMustBeAWebAddress() {
        let json = String(decoding: latestJSON(), as: UTF8.self)
            .replacingOccurrences(of: "https://github.com/fheinfling/sempre/releases/tag/v1.2", with: "file:///Applications/Calculator.app")
        #expect(throws: Updates.UpdateError.self) { try Updates.parseLatest(Data(json.utf8)) }
    }

    @Test func draftsAndNonsenseAreRejected() {
        #expect(throws: Updates.UpdateError.self) { try Updates.parseLatest(latestJSON(draft: true)) }
        #expect(throws: Updates.UpdateError.self) { try Updates.parseLatest(Data(#"{"message": "Not Found"}"#.utf8)) }
    }

    @Test func decidesWhatToOffer() {
        #expect(Updates.decide(latest: release("1.2"), current: "1.1", skipped: nil) == .available(release("1.2")))
        #expect(Updates.decide(latest: release("1.1"), current: "1.1", skipped: nil) == .upToDate)
        #expect(Updates.decide(latest: release("1.0"), current: "1.1", skipped: nil) == .upToDate)
        #expect(Updates.decide(latest: release("1.2"), current: "1.1", skipped: "1.2") == .skipped(release("1.2")))
        // Skipping 1.2 doesn't hide 1.3.
        #expect(Updates.decide(latest: release("1.3"), current: "1.1", skipped: "1.2") == .available(release("1.3")))
    }

    @Test func acceptsAnIntactAppThatMeetsTheRequirement() throws {
        let app = try makeApp(in: tempDir())
        try Updates.verify(app: app, satisfies: requirement(#"identifier "com.example.sempre-test""#), notarized: false)
        #expect(Updates.version(of: app) == "1.2")
    }

    @Test func rejectsAnAppFromSomeoneElse() throws {
        let app = try makeApp(in: tempDir(), identifier: "com.example.impostor")
        #expect(throws: Updates.UpdateError.self) {
            try Updates.verify(app: app, satisfies: requirement(#"identifier "com.example.sempre-test""#), notarized: false)
        }
    }

    @Test func rejectsATamperedApp() throws {
        let app = try makeApp(in: tempDir())
        let plist = app.appendingPathComponent("Contents/Info.plist")
        try (try String(contentsOf: plist, encoding: .utf8) + "\n").write(to: plist, atomically: true, encoding: .utf8)
        #expect(throws: Updates.UpdateError.self) {
            try Updates.verify(app: app, satisfies: requirement(#"identifier "com.example.sempre-test""#), notarized: false)
        }
    }

    @Test func rejectsAnUnsignedApp() throws {
        let app = try makeApp(in: tempDir(), identifier: nil)
        #expect(throws: Updates.UpdateError.self) {
            try Updates.verify(app: app, satisfies: requirement(#"identifier "com.example.unsigned""#), notarized: false)
        }
    }

    @Test func requiresNotarizationWhenAsked() throws {
        let app = try makeApp(in: tempDir())
        #expect(throws: Updates.UpdateError.self) {
            try Updates.verify(app: app, satisfies: requirement(#"identifier "com.example.sempre-test""#), notarized: true)
        }
    }

    @Test func adHocBuildsCantVouchForUpdates() throws {
        // Development builds are ad-hoc signed: no team, so no requirement, so they never install anything.
        #expect(Updates.requirement(of: try makeApp(in: tempDir())) == nil)
        #expect(Updates.requirement(of: try makeApp(in: tempDir(), identifier: nil)) == nil)
    }

    @Test func unpacksTheReleaseZip() throws {
        let dir = tempDir()
        let source = dir.appendingPathComponent("source")
        let app = try makeApp(in: source)
        let zip = dir.appendingPathComponent("Sempre-v1.2.zip")
        try run("/usr/bin/ditto", "-c", "-k", "--keepParent", app.path, zip.path)
        let out = dir.appendingPathComponent("out")
        let unpacked = try Updates.unpack(zip: zip, into: out)
        #expect(unpacked == out.appendingPathComponent("Sempre.app"))
        try Updates.verify(app: unpacked, satisfies: requirement(#"identifier "com.example.sempre-test""#), notarized: false)
    }

    @Test func zipWithoutTheAppIsRejected() throws {
        let dir = tempDir()
        let other = dir.appendingPathComponent("Other.txt")
        try Data("hi".utf8).write(to: other)
        let zip = dir.appendingPathComponent("bad.zip")
        try run("/usr/bin/ditto", "-c", "-k", "--keepParent", other.path, zip.path)
        #expect(throws: Updates.UpdateError.self) { try Updates.unpack(zip: zip, into: dir.appendingPathComponent("out")) }
    }

    @Test func swapsTheNewVersionIntoPlace() throws {
        let dir = tempDir()
        let current = try makeApp(in: dir.appendingPathComponent("Applications"), version: "1.1")
        let new = try makeApp(in: dir.appendingPathComponent("download"), version: "1.2")
        let old = try Updates.replace(current, with: new)
        #expect(Updates.version(of: current) == "1.2")
        #expect(Updates.version(of: old) == "1.1")
        #expect(old.deletingLastPathComponent() == current.deletingLastPathComponent())
        #expect(!FileManager.default.fileExists(atPath: new.path))
    }

    @Test func swappingNeverOverwritesAnotherFile() throws {
        let dir = tempDir()
        let current = try makeApp(in: dir.appendingPathComponent("Applications"), version: "1.1")
        let keep = dir.appendingPathComponent("Applications/Sempre (previous).app")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        let first = try Updates.replace(current, with: try makeApp(in: dir.appendingPathComponent("a"), version: "1.2"))
        let second = try Updates.replace(current, with: try makeApp(in: dir.appendingPathComponent("b"), version: "1.3"))
        #expect(first != second)
        #expect(Updates.version(of: first) == "1.1")
        #expect(Updates.version(of: second) == "1.2")
        #expect(Updates.version(of: current) == "1.3")
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }
}
