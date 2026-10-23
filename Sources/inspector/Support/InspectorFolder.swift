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

  /// Records a call as `lastStep` in `run.json`: its command, its arguments and when it started.
  ///
  /// `logs.sh` reads the app's log from `at` on, so a failed step's log is in the window.
  func recordStep(command: String, arguments: [String], at start: Date) throws {
    let step: JSONValue = .object([
      "command": .string(command),
      "arguments": .array(arguments.map(JSONValue.string)),
      "at": .string(start.formatted(Self.timestamp)),
    ])
    try updateRun { $0["lastStep"] = step }
  }

  /// Changes `run.json` and keeps every field the change leaves alone, so each command owns only
  /// its own fields.
  func updateRun(_ change: (inout [String: JSONValue]) -> Void) throws {
    let file = url.appending(path: "run.json")
    var run = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }?
      .objectValue ?? [:]
    change(&run)
    try Self.write(run, to: file)
  }

  /// Writes `config.json`, stamped with `writtenAt`; the one way the file is written, used by
  /// `init` and by a session restart.
  func writeConfig(_ config: InspectorConfig, at time: Date) throws {
    var config = config
    config.writtenAt = time
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Self.write(config, to: url.appending(path: "config.json"))
  }

  /// Milliseconds in UTC, so two quick steps stay in order.
  private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  /// Pretty-printed with sorted keys, for a human who opens the file; written atomically, so a
  /// concurrent reader never sees half a file.
  private static func write(_ value: some Encodable, to file: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(value)
    data.append(contentsOf: Array("\n".utf8))
    try data.write(to: file, options: .atomic)
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

  /// The repository `workingDirectory` lies in: the first directory upwards with a `.git`, or
  /// `workingDirectory` itself outside a repository.
  static func repositoryRoot(from workingDirectory: URL) -> URL {
    var directory = workingDirectory.standardizedFileURL
    while !FileManager.default.fileExists(atPath: directory.appending(path: ".git").path) {
      let parent = directory.deletingLastPathComponent()
      if parent.path == directory.path { return workingDirectory.standardizedFileURL }
      directory = parent
    }
    return directory
  }

  private static func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
  }
}
