import Foundation
import Security
import Testing
@testable import SempreCore

/// GitHub's `releases/latest` answer, trimmed to the fields Sempre reads.
private func latestJSON(tag: String = "v1.2", draft: Bool = false, assets: String? = nil) -> Data {
    let assets = assets ?? """
        [{"name": "Sempre-\(tag).zip", "browser_download_url": "https://github.com/fheinfling/sempre/releases/download/\(tag)/Sempre-\(tag).zip", "size": 2063619,
          "digest": "sha256:645EC31BA6476614B560C41757C9D76B4A28205C58C9AD577BDAB549740A3AE8"},
         {"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt", "size": 10}]
        """
    return Data("""
        {"tag_name": "\(tag)", "body": "## What's Changed\\n* CSV import", "html_url": "https://github.com/fheinfling/sempre/releases/tag/\(tag)",
         "draft": \(draft), "prerelease": false, "assets": \(assets)}
        """.utf8)
}

/// A minimal app bundle, ad-hoc signed by `codesign` under `identifier`, or left unsigned.
private func makeApp(in dir: URL, identifier: String? = "com.example.sempre-test", version: String = "1.2",
                     minimumOS: String = "14.0") throws -> URL {
    let app = dir.appendingPathComponent("Sempre.app")
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Sempre"))
    let plist: [String: Any] = ["CFBundleExecutable": "Sempre", "CFBundleIdentifier": identifier ?? "com.example.unsigned",
                                "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL",
                                "LSMinimumSystemVersion": minimumOS]
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
        #expect(r.sha256 == "645ec31ba6476614b560c41757c9d76b4a28205c58c9ad577bdab549740a3ae8")
    }

    @Test func onlyASHA256DigestCounts() throws {
        for digest in ["\"sha512:\(String(repeating: "a", count: 64))\"", "\"sha256:xyz\"", "null"] {
            let r = try Updates.parseLatest(latestJSON(assets: #"[{"name": "Sempre-v1.2.zip", "browser_download_url": "https://example.com/Sempre-v1.2.zip", "size": 1, "digest": "# + digest + "}]"))
            #expect(r.sha256 == nil, "\(digest)")
        }
    }

    @Test func hashesFiles() throws {
        let file = tempDir().appendingPathComponent("abc")
        try Data("abc".utf8).write(to: file)
        #expect(try Updates.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
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

    @Test func symlinkedAppIsRejected() throws {
        // A genuine app tucked away in the archive, with Sempre.app only a link to it.
        let dir = tempDir()
        let staging = dir.appendingPathComponent("staging")
        _ = try makeApp(in: staging.appendingPathComponent("payload"))
        try FileManager.default.createSymbolicLink(atPath: staging.appendingPathComponent("Sempre.app").path,
                                                   withDestinationPath: "payload/Sempre.app")
        let zip = dir.appendingPathComponent("evil.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = staging
        p.arguments = ["-q", "-r", "-y", zip.path, "Sempre.app", "payload"]
        try p.run()
        p.waitUntilExit()
        #expect(throws: Updates.UpdateError.self) { try Updates.unpack(zip: zip, into: dir.appendingPathComponent("out")) }
    }

    @Test func oversizedZipIsRejectedBeforeUnpacking() throws {
        let dir = tempDir()
        let app = try makeApp(in: dir.appendingPathComponent("source"))
        let zip = dir.appendingPathComponent("Sempre-v1.2.zip")
        try run("/usr/bin/ditto", "-c", "-k", "--keepParent", app.path, zip.path)
        let out = dir.appendingPathComponent("out")
        #expect(throws: Updates.UpdateError.self) { try Updates.unpack(zip: zip, into: out, maxBytes: 1000) }
        #expect(throws: Updates.UpdateError.self) { try Updates.unpack(zip: zip, into: out, maxEntries: 2) }
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("Sempre.app").path))
    }

    @Test func refusesVersionsThatCantRunHere() throws {
        let app = try makeApp(in: tempDir(), minimumOS: "14.0")
        try Updates.checkRunsHere(app, os: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0))
        #expect(throws: Updates.UpdateError.self) {
            try Updates.checkRunsHere(app, os: .init(majorVersion: 13, minorVersion: 6, patchVersion: 0))
        }
        let future = try makeApp(in: tempDir(), minimumOS: "99.0")
        #expect(throws: Updates.UpdateError.self) { try Updates.checkRunsHere(future) }
    }

    @Test func perArchitectureMinimumWins() throws {
        let app = try makeApp(in: tempDir(), minimumOS: "14.0")
        let plist = app.appendingPathComponent("Contents/Info.plist")
        var info = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
        info["LSMinimumSystemVersionByArchitecture"] = ["arm64": "99.0", "x86_64": "99.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        #expect(throws: Updates.UpdateError.self) {
            try Updates.checkRunsHere(app, os: .init(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        }
    }

    @Test func appThatLostItsExecuteBitIsRefused() throws {
        let app = try makeApp(in: tempDir())
        try Updates.checkRunsHere(app)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: app.appendingPathComponent("Contents/MacOS/Sempre").path)
        #expect(throws: Updates.UpdateError.self) { try Updates.checkRunsHere(app) }
    }

    @Test func zipWithoutTheAppIsRejected() throws {
        let dir = tempDir()
        let other = dir.appendingPathComponent("Other.txt")
        try Data("hi".utf8).write(to: other)
        let zip = dir.appendingPathComponent("bad.zip")
        try run("/usr/bin/ditto", "-c", "-k", "--keepParent", other.path, zip.path)
        #expect(throws: Updates.UpdateError.self) { try Updates.unpack(zip: zip, into: dir.appendingPathComponent("out")) }
    }

    // MARK: Install helper

    /// An installed 1.1 and a downloaded update, as the app hands them to the helper.
    struct Install {
        let dir = tempDir("install")
        var target: URL { dir.appendingPathComponent("Applications/Sempre.app") }
        var staged: URL { dir.appendingPathComponent("Updates/stage/Sempre.app") }
        var ack: URL { dir.appendingPathComponent("Updates/update-ack") }
        var folder: URL { target.deletingLastPathComponent() }

        /// A process that has already exited, standing in for the app that quit.
        let pid: Int32 = {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try! p.run()
            p.waitUntilExit()
            return p.processIdentifier
        }()

        init(installed: String = "1.1", update: String = "1.2", signer: String = "com.example.sempre-test") throws {
            _ = try makeApp(in: target.deletingLastPathComponent(), version: installed)
            _ = try makeApp(in: staged.deletingLastPathComponent(), identifier: signer, version: update)
        }

        /// An `open` stand-in: the "new app" either acknowledges itself, or never starts.
        func opener(acknowledging version: String?) throws -> String {
            let script = dir.appendingPathComponent("open.sh")
            let body = version.map { "printf '%s\\n' '\($0)' > '\(ack.path)'" } ?? ":"
            try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            return script.path
        }

        /// Runs the helper to the end and returns its exit status.
        func run(expected: String = "1.1", opener: String) throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = try Updates.installCommand(staged: staged, target: target, pid: pid, ack: ack, expected: expected,
                                                     requirement: #"identifier "com.example.sempre-test""#, opener: opener,
                                                     pkill: "/usr/bin/true", pgrep: "/usr/bin/false", quitWait: 2, ackWait: 1)
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }

        /// Whatever the helper leaves next to the app besides it: a backup or a half-copied candidate.
        var leftovers: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != "Sempre.app" }) ?? ["?"]
        }
    }

    @Test func helperSwapsInTheNewVersionOnceItStarts() throws {
        let i = try Install()
        #expect(try i.run(opener: i.opener(acknowledging: "1.2")) == 0)
        #expect(Updates.version(of: i.target) == "1.2")
        #expect(i.leftovers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: i.staged.deletingLastPathComponent().path))
    }

    @Test func helperPutsTheOldVersionBackIfTheNewOneDoesntStart() throws {
        let i = try Install()
        #expect(try i.run(opener: i.opener(acknowledging: nil)) == 4)
        #expect(Updates.version(of: i.target) == "1.1")
        #expect(i.leftovers.isEmpty)
        // Acknowledged by the wrong version (the old one, reopened elsewhere) is no acknowledgement either.
        let j = try Install()
        #expect(try j.run(opener: j.opener(acknowledging: "1.1")) == 4)
        #expect(Updates.version(of: j.target) == "1.1")
    }

    @Test func helperLeavesAnAppThatChangedMeanwhileAlone() throws {
        let i = try Install(installed: "1.1.5")
        #expect(try i.run(opener: i.opener(acknowledging: "1.2")) == 3)
        #expect(Updates.version(of: i.target) == "1.1.5")
        #expect(i.leftovers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: i.staged.path))
    }

    @Test func helperChecksTheCopysSignature() throws {
        let i = try Install(signer: "com.example.someone-else")
        #expect(try i.run(opener: i.opener(acknowledging: "1.2")) == 1)
        #expect(Updates.version(of: i.target) == "1.1")
        #expect(i.leftovers.isEmpty)
    }

    @Test func installIsRefusedWhenItCantWork() throws {
        let i = try Install()
        func command(staged: URL? = nil, target: URL? = nil, expected: String = "1.1") throws -> [String] {
            try Updates.installCommand(staged: staged ?? i.staged, target: target ?? i.target, pid: i.pid, ack: i.ack,
                                       expected: expected, requirement: "identifier x")
        }
        #expect(try command().count > 10)
        // Not newer than what's installed.
        #expect(throws: Updates.UpdateError.self) { try command(expected: "1.2") }
        // A backup from an earlier attempt in the way.
        let backup = i.folder.appendingPathComponent(".Sempre.previous-\(i.pid).app")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        #expect(throws: Updates.UpdateError.self) { try command() }
        try FileManager.default.removeItem(at: backup)
        // Running from a translocated copy, or not from an app at all.
        #expect(throws: Updates.UpdateError.self) { try command(target: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/y/d/Sempre.app")) }
        #expect(throws: Updates.UpdateError.self) { try command(target: i.dir) }
    }
}
