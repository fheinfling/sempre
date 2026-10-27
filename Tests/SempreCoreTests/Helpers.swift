import Foundation

/// A fresh, empty directory under the system temp folder.
func tempDir(_ name: String = #function) -> URL {
    let safe = name.filter { $0.isLetter || $0.isNumber }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sempre-tests/\(safe)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A data file path that doesn't exist yet.
func tempDataFile(_ name: String = #function) -> URL {
    tempDir(name).appendingPathComponent("sempre.json")
}
