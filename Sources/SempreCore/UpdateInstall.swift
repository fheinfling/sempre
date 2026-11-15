import Foundation

/// Installing a verified update: a helper that outlives the app swaps the new version in once the app has quit,
/// keeps the old one until the new one reports that it started, and puts the old one back if it doesn't.
extension Updates {
    /// Written by the app as it starts (its version and a newline), for a waiting helper.
    public static func acknowledge(_ ack: URL, version: String) {
        try? FileManager.default.createDirectory(at: ack.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("\(version)\n".utf8).write(to: ack, options: .atomic)
    }

    /// Runs detached with `/bin/sh` after the app quits. Every value arrives as a positional argument, never as
    /// script text. Exit codes: 0 installed and acknowledged; 1 nothing changed (the old app reopened); 2 the old
    /// app never quit; 3 the installed version changed meanwhile; 4 rolled back after the new app never
    /// acknowledged; 70 a restore failed, and the installed app may be missing (the log names the backup).
    static let installScript = #"""
    staged=$1; target=$2; pid=$3; backup=$4; candidate=$5; ack=$6; expected=$7; new=$8
    requirement=$9; shift 9
    opener=$1; codesign=$2; pkill=$3; pgrep=$4; quit_ticks=$5; ack_ticks=$6; pattern=$7
    log() { printf '%s sempre-update: %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
    version_of() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null; }
    reopen() { "$opener" "$target" || log "couldn't reopen $target"; }
    cleanup() { /bin/rm -rf -- "$staged"; /bin/rmdir -- "${staged%/*}" 2>/dev/null; }
    give_up() { /bin/rm -rf -- "$candidate"; cleanup; reopen; exit "${1:-1}"; }

    log "installing $new over $expected at $target"
    /bin/rm -f -- "$ack"
    i=0
    while /bin/kill -0 "$pid" 2>/dev/null; do
      i=$((i + 1))
      if [ "$i" -ge "$quit_ticks" ]; then log "the app didn't quit; nothing changed"; exit 2; fi
      /bin/sleep 0.5
    done

    installed=$(version_of "$target")
    if [ "$installed" != "$expected" ]; then
      log "installed version is '$installed', expected '$expected'; nothing changed"
      cleanup; reopen; exit 3
    fi

    /bin/rm -rf -- "$candidate"
    if ! /usr/bin/ditto "$staged" "$candidate"; then log "copy failed"; give_up 1; fi
    if ! "$codesign" --verify --deep --strict -R "=$requirement" "$candidate"; then
      log "the copied app failed signature verification"; give_up 1
    fi
    if [ "$(version_of "$candidate")" != "$new" ]; then log "the copied app has the wrong version"; give_up 1; fi

    if ! /bin/mv -- "$target" "$backup"; then log "couldn't move the installed app aside"; give_up 1; fi
    # Checked again on what was actually moved aside: an upgrade that landed during the copy must stay.
    moved=$(version_of "$backup")
    if [ "$moved" != "$expected" ]; then
      if ! /bin/mv -- "$backup" "$target"; then
        log "RESTORE FAILED: the previous app is at $backup"; exit 70
      fi
      log "installed version became '$moved' during the copy; nothing changed"
      /bin/rm -rf -- "$candidate"; cleanup; reopen; exit 3
    fi
    if ! /bin/mv -- "$candidate" "$target"; then
      if ! /bin/mv -- "$backup" "$target"; then
        log "RESTORE FAILED: the previous app is at $backup"; exit 70
      fi
      log "couldn't move the new app into place; restored"; give_up 1
    fi

    if "$opener" "$target"; then
      i=0
      while [ "$i" -lt "$ack_ticks" ]; do
        if [ "$(/bin/cat -- "$ack" 2>/dev/null)" = "$new" ]; then
          /bin/rm -rf -- "$backup"; cleanup; log "installed $new"; exit 0
        fi
        i=$((i + 1))
        /bin/sleep 0.5
      done
      log "the new app didn't confirm it started; rolling back"
    else
      log "couldn't open the new app; rolling back"
    fi

    "$pkill" -f "$pattern"
    i=0
    while "$pgrep" -f "$pattern" >/dev/null 2>&1; do
      i=$((i + 1))
      if [ "$i" -ge 20 ]; then "$pkill" -9 -f "$pattern"; break; fi
      /bin/sleep 0.5
    done
    /bin/sleep 0.5
    if ! /bin/mv -- "$target" "$candidate"; then
      log "RESTORE FAILED: couldn't move the new app aside; the previous app is at $backup"; exit 70
    fi
    if ! /bin/mv -- "$backup" "$target"; then
      log "RESTORE FAILED: the previous app is at $backup"; exit 70
    fi
    /bin/rm -rf -- "$candidate"
    cleanup
    reopen
    log "rolled back to $expected"
    exit 4
    """#

    /// Arguments for `/bin/sh` that swap `target` for `staged` once process `pid` has exited.
    ///
    /// Transactional: the helper copies `staged` to a hidden candidate next to `target`, checks the copy (its
    /// signature against `requirement`, and its version), and only then renames target → backup and
    /// candidate → target. It won't touch `target` unless that is still version `expected`. After opening the new
    /// app it waits for `ack` (see `acknowledge`) to name the new version; only then is the backup deleted.
    /// Otherwise it stops the new app, puts the backup back and reopens the old one. The tools and waits are
    /// arguments for the tests.
    public static func installCommand(staged: URL, target: URL, pid: Int32, ack: URL, expected: String, requirement: String,
                                      opener: String = "/usr/bin/open", codesign: String = "/usr/bin/codesign",
                                      pkill: String = "/usr/bin/pkill", pgrep: String = "/usr/bin/pgrep",
                                      quitWait: TimeInterval = 60, ackWait: TimeInterval = 120) throws -> [String] {
        func refuse(_ why: String) -> UpdateError { UpdateError(message: "Sempre can't update in place: \(why).") }
        let fm = FileManager.default
        let folder = target.deletingLastPathComponent()
        guard [staged, target, ack].allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }) else { throw refuse("paths must be absolute") }
        guard target.pathExtension == "app" else { throw refuse("it isn't an app bundle") }
        guard !target.path.contains("/AppTranslocation/"), !target.resolvingSymlinksInPath().path.contains("/AppTranslocation/") else {
            throw refuse("macOS is running it from a temporary location; move it to Applications first")
        }
        let kind = try? target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard kind?.isDirectory == true, kind?.isSymbolicLink == false else { throw refuse("the installed app wasn't found") }
        guard fm.isWritableFile(atPath: folder.path) else { throw refuse("it has no permission to replace the app in \(folder.path)") }
        guard staged.pathExtension == "app", fm.fileExists(atPath: staged.path) else { throw refuse("the downloaded update is missing") }
        let backup = folder.appendingPathComponent(".\(target.deletingPathExtension().lastPathComponent).previous-\(pid).app")
        let candidate = folder.appendingPathComponent(".\(target.lastPathComponent).new-\(pid)")
        guard !fm.fileExists(atPath: backup.path) else { throw refuse("a previous update's backup is in the way") }
        guard !fm.fileExists(atPath: candidate.path) else { throw refuse("a previous update's copy is in the way") }
        guard pid > 0 else { throw refuse("its process is unknown") }
        guard !requirement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw refuse("its signature requirement is missing") }
        guard let new = version(of: staged), isNewer(new, than: expected) else {
            throw refuse("the download isn't newer than the installed app")
        }
        // pkill/pgrep take an extended regular expression: only this app's executables match.
        let escaped = "\(target.path)/Contents/MacOS/".map { ".[]{}()\\*+?^$|".contains($0) ? "\\\($0)" : String($0) }.joined()
        return ["-c", installScript, "sempre-update",
                staged.path, target.path, String(pid), backup.path, candidate.path, ack.path, expected, new, requirement,
                opener, codesign, pkill, pgrep,
                String(max(1, Int((quitWait * 2).rounded()))), String(max(1, Int((ackWait * 2).rounded()))), "^" + escaped]
    }
}
