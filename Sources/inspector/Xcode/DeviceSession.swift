import Foundation
import InspectorKit

/// The Xcode device interaction session `.inspector/config.json` binds this repository to.
///
/// The session lives in Xcode, not in a process of the CLI: it outlives every bridge connection,
/// and each call into it pushes back its expiry of about two minutes.
struct DeviceSession {
  /// The folder holding `config.json`.
  let folder: InspectorFolder
  /// The binding the session is part of.
  private(set) var config: InspectorConfig
  /// The session's name, which every session tool takes as its key.
  private(set) var name: String

  /// The session `config.json` names.
  ///
  /// - Throws: ``ErrorCode/noConfig`` without `.inspector/`, ``ErrorCode/noSession`` when
  ///   `config.json` names no session.
  init(in environment: Environment) throws(InspectorError) {
    folder = try environment.requiredFolder()
    guard let config = try folder.config(), let name = config.session else {
      throw InspectorError(
        code: .noSession, message: "no session in `config.json`; run `inspector init`",
        detail: folder.url.appending(path: "config.json").path)
    }
    self.config = config
    self.name = name
  }

  /// Ends the session; the app it started ends with it.
  ///
  /// - Throws: Xcode's error as it is. A session that already ended is no error to Xcode.
  func end(on xcode: XcodeBridge) async throws(InspectorError) -> ToolResult {
    try await xcode.call(.endSession, [SessionTool.endSession.sessionParameter: .string(name)])
  }

  /// Calls `tool` in the session.
  ///
  /// When Xcode no longer knows the session and the app still answers `hello`, a new session
  /// replaces it in `config.json` and `tool` runs once more.
  ///
  /// - Throws: ``ErrorCode/noSession`` when the session ended and the app with it, and every
  ///   error of ``XcodeBridge/call(_:_:timeout:)``.
  mutating func call(
    _ tool: SessionTool, _ arguments: [String: JSONValue] = [:], timeout: Duration = .seconds(30),
    on xcode: XcodeBridge, in environment: Environment
  ) async throws(InspectorError) -> ToolResult {
    do throws(InspectorError) {
      return try await xcode.call(tool.tool, inSession(arguments, for: tool), timeout: timeout)
    } catch where Self.isSessionNotFound(error) {
      try await restart(after: error, on: xcode, in: environment)
    }
    do throws(InspectorError) {
      return try await xcode.call(tool.tool, inSession(arguments, for: tool), timeout: timeout)
    } catch where Self.isSessionNotFound(error) {
      throw noSession(error)
    }
  }

  /// A fresh session name for `repository`: Xcode rejects a name that was just in use, so each
  /// carries the time it was made.
  static func newName(repository: String, at time: Date) -> String {
    "inspector-\(repository)-\(time.formatted(stamp))"
  }

  /// Starts the session `name` in `workspace` and returns the UDID of the device Xcode chose;
  /// `device` asks for one, otherwise Xcode takes the scheme's run destination and boots it if
  /// needed.
  ///
  /// - Throws: every error of ``XcodeBridge/call(_:_:timeout:)``, Xcode's rejection of a name in
  ///   use or of a device in another session as ``ErrorCode/xcodeError``.
  static func start(
    _ name: String, workspace: String, device: String?, on xcode: XcodeBridge
  ) async throws(InspectorError) -> String? {
    var arguments: [String: JSONValue] = ["sessionIdentifier": .string(name), "workspaceIdentifier": .string(workspace)]
    if let device { arguments["deviceIdentifier"] = .string(device) }
    // Booting a simulator for the session can take a while.
    let started = try await xcode.call(.startSession, arguments, timeout: .seconds(120))
    return started.json.objectValue?["deviceUUID"]?.stringValue ?? device
  }

  private static let stamp = Date.VerbatimFormatStyle(
    format: """
      \(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\
      \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)
      """,
    timeZone: .gmt, calendar: Calendar(identifier: .gregorian))

  private func inSession(_ arguments: [String: JSONValue], for tool: SessionTool) -> [String: JSONValue] {
    arguments.merging([tool.sessionParameter: .string(name)]) { _, session in session }
  }

  private static func isSessionNotFound(_ error: InspectorError) -> Bool {
    error.code == .xcodeError && (error.detail ?? "").contains("Session not found")
  }

  /// Starts a new session on the device the old one had and writes its name to `config.json`.
  private mutating func restart(
    after error: InspectorError, on xcode: XcodeBridge, in environment: Environment
  ) async throws(InspectorError) {
    guard let workspace = config.workspace, let udid = config.udid, let app = config.selector,
      await Self.answersHello(app, in: environment)
    else { throw noSession(error) }
    let newName = Self.newName(repository: folder.url.deletingLastPathComponent().lastPathComponent, at: environment.now())
    _ = try await Self.start(newName, workspace: workspace, device: udid, on: xcode)
    // Read again right before writing, so a field another call changed in the meantime survives.
    var latest = (try folder.config()) ?? config
    latest.session = newName
    do {
      try folder.writeConfig(latest, at: environment.now())
    } catch {
      throw InspectorError(
        code: .badRequest, message: "could not write the new session `\(newName)` to `config.json`",
        detail: "\(error)")
    }
    config = latest
    name = newName
  }

  /// Whether `app` still serves; a session's app that died with it does not.
  private static func answersHello(_ app: String, in environment: Environment) async -> Bool {
    do {
      _ = try await environment.answer(to: .hello, from: app)
      return true
    } catch {
      return false
    }
  }

  private func noSession(_ error: InspectorError) -> InspectorError {
    InspectorError(
      code: .noSession, message: "the session `\(name)` has ended and the app with it; run `inspector init`",
      detail: error.detail)
  }
}

/// Xcode's device interaction tools that act in a session.
enum SessionTool: Sendable {
  case synthesize
  case installAndRun
  case endSession

  /// The tool as the bridge calls it.
  var tool: XcodeTool {
    switch self {
    case .synthesize: .synthesize
    case .installAndRun: .installAndRun
    case .endSession: .endSession
    }
  }

  /// The parameter that takes the session's name; `Synthesize` spells it differently.
  var sessionParameter: String {
    self == .synthesize ? "interactSessionKey" : "interactionSessionKey"
  }
}
