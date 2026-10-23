import Foundation
import InspectorKit

/// `.inspector/` in the app's repository root: what binds separate CLI calls to one app and device.
///
/// Holds `config.json` (written only by `init` and a session restart, through
/// ``writeConfig(_:at:)``), `run.json` (what the last calls did) and `.env` (values a payload
/// names as `${NAME}`).
struct InspectorFolder: Equatable, Sendable {
  /// The folder's name in the repository root.
  static let name = ".inspector"

  /// The folder itself.
  let url: URL

  /// The binding `init` wrote, or `nil` while there is no `config.json`.
  ///
  /// - Throws: ``ErrorCode/badRequest`` when the file exists but is not a config.
  func config() throws(InspectorError) -> InspectorConfig? {
    guard let data = try? Data(contentsOf: url.appending(path: "config.json")) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(InspectorConfig.self, from: data)
    } catch {
      throw InspectorError(
        code: .badRequest, message: "could not read `\(url.appending(path: "config.json").path)`",
        detail: "\(error)")
    }
  }
}

/// `config.json`: which app and device the calls in this repository talk to.
///
/// Every field is optional, so a hand-written file with just `instance` works.
struct InspectorConfig: Codable, Equatable, Sendable {
  /// The `--app` selector `init` was given.
  var app: String?
  /// The full instance name `<app> @ <device>`; the default for `--app`.
  var instance: String?
  /// The app's bundle identifier.
  var bundleId: String?
  /// The simulator the app runs on.
  var udid: String?
  /// The Xcode device interaction session the gestures run in.
  var session: String?
  /// The Xcode workspace identifier the session belongs to.
  var workspace: String?
  /// The scheme `init` built.
  var scheme: String?
  /// The subsystem the app logs under.
  var logSubsystem: String?
  /// When the file was written.
  var writtenAt: Date?

  /// What a call without `--app` selects the app by: the full instance name, else the selector.
  var selector: String? { instance ?? app }
}

/// Where a call finds `.inspector/`.
enum FolderLookup: Equatable, Sendable {
  /// The folder exists.
  case found(InspectorFolder)
  /// There is none; `expected` is where `init` puts it.
  case missing(expected: URL)

  /// `INSPECTOR_DIR` when it is set, otherwise the first `.inspector/` from `workingDirectory`
  /// upwards, up to and including the repository root (the first directory with a `.git`).
  static func locate(from workingDirectory: URL, override: String?) -> FolderLookup {
    if let override, !override.isEmpty {
      let url = URL(filePath: override, directoryHint: .isDirectory, relativeTo: workingDirectory).standardizedFileURL
      return isDirectory(url) ? .found(InspectorFolder(url: url)) : .missing(expected: url)
    }
    var directory = workingDirectory.standardizedFileURL
    while true {
      let candidate = directory.appending(path: InspectorFolder.name, directoryHint: .isDirectory)
      if isDirectory(candidate) { return .found(InspectorFolder(url: candidate)) }
      if FileManager.default.fileExists(atPath: directory.appending(path: ".git").path) {
        return .missing(expected: candidate)
      }
      let parent = directory.deletingLastPathComponent()
      if parent.path == directory.path {
        return .missing(
          expected: workingDirectory.standardizedFileURL.appending(path: InspectorFolder.name, directoryHint: .isDirectory))
      }
      directory = parent
    }
  }

  private static func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
  }
}
