import Foundation
import InspectorKit

/// The Xcode device interaction session `.inspector/config.json` binds this repository to.
///
/// The session lives in Xcode, not in a process of the CLI: it outlives every bridge connection,
/// and each call into it pushes back its expiry of about two minutes. While another process holds
/// `.inspector/session.lock`, it is starting the next session; the first call waits for it and
/// takes that session from `config.json`.
struct DeviceSession {
  /// The folder holding `config.json`.
  let folder: InspectorFolder
  /// The binding the session is part of.
  private(set) var config: InspectorConfig
  /// The session's name, which every session tool takes as its key.
  private(set) var name: String
  /// Whether this value has already waited for a session another process was starting.
  private var awaitedLock = false

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
  mutating func end(on xcode: XcodeBridge, in environment: Environment) async throws(InspectorError) -> ToolResult {
    try await awaitStartingSession(in: environment)
    return try await xcode.call(.endSession, [SessionTool.endSession.sessionParameter: .string(name)])
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
    try await awaitStartingSession(in: environment)
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
  /// carries the time it was made, to the millisecond, so two starts in one second differ.
  static func newName(repository: String, at time: Date) -> String {
    "inspector-\(repository)-\(time.formatted(stamp))"
  }

  /// Starts a new session on the device `udid`, without a workspace, and writes its name to
  /// `config.json`; the caller holds ``SessionLock``.
  ///
  /// Unlike a workspace session, it needs neither the app nor Xcode's workspace, so it can start
  /// while the app is still launching.
  ///
  /// - Returns: `config.json` as written.
  /// - Throws: every error of ``XcodeBridge/call(_:_:timeout:)``, and ``ErrorCode/badRequest``
  ///   when `config.json` cannot be written.
  static func startOnDevice(
    _ udid: String, in folder: InspectorFolder, fallback: InspectorConfig, on xcode: XcodeBridge,
    in environment: Environment
  ) async throws(InspectorError) -> InspectorConfig {
    let newName = newName(repository: folder.url.deletingLastPathComponent().lastPathComponent, at: environment.now())
    var name = newName
    func arguments() -> [String: JSONValue] { ["deviceIdentifier": .string(udid), "sessionIdentifier": .string(name)] }
    // Booting a simulator for the session can take a while.
    do throws(InspectorError) {
      _ = try await xcode.call(.startDeviceSession, arguments(), timeout: .seconds(120))
    } catch {
      // An earlier session of this CLI that `config.json` no longer names still holds the device
      // (a start that lost a race): end it and start once more. A foreign session stays untouched.
      guard let orphan = orphanedSession(in: error) else { throw error }
      _ = try await xcode.call(.endSession, [SessionTool.endSession.sessionParameter: .string(orphan)])
      // Xcode rejects a name a failed start already used.
      name = newName + "-r"
      _ = try await xcode.call(.startDeviceSession, arguments(), timeout: .seconds(120))
    }
    // Read again right before writing, so a field another call changed in the meantime survives.
    var latest = (try folder.config()) ?? fallback
    latest.session = name
    do {
      try folder.writeConfig(latest, at: environment.now())
    } catch {
      throw InspectorError(
        code: .badRequest, message: "could not write the new session `\(name)` to `config.json`",
        detail: "\(error)")
    }
    return latest
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
      \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)-\
      \(secondFraction: .fractional(3))
      """,
    timeZone: .gmt, calendar: Calendar(identifier: .gregorian))

  private func inSession(_ arguments: [String: JSONValue], for tool: SessionTool) -> [String: JSONValue] {
    arguments.merging([tool.sessionParameter: .string(name)]) { _, session in session }
  }

  /// The key of an `inspector-` session that holds the device, from Xcode's "already in use by a
  /// different session with key '…'" rejection; `nil` for any other error or a foreign session.
  static func orphanedSession(in error: InspectorError) -> String? {
    guard error.code == .xcodeError, let detail = error.detail,
      let match = detail.firstMatch(of: /different session with key '(inspector-[^']+)'/)
    else { return nil }
    return String(match.1)
  }

  private static func isSessionNotFound(_ error: InspectorError) -> Bool {
    error.code == .xcodeError && (error.detail ?? "").contains("Session not found")
  }

  /// Waits once for a session another process is starting, then takes its name from
  /// `config.json`.
  private mutating func awaitStartingSession(in environment: Environment) async throws(InspectorError) {
    guard !awaitedLock else { return }
    awaitedLock = true
    if await environment.sessionLock(in: folder).waitWhileHeld() { try adoptLatest() }
  }

  /// Takes the session `config.json` names now, when it names one.
  private mutating func adoptLatest() throws(InspectorError) {
    guard let latest = try folder.config(), let session = latest.session else { return }
    config = latest
    name = session
  }

  /// Starts a new session on the device the old one had and writes its name to `config.json`,
  /// holding ``SessionLock`` meanwhile; a session another process started while this one waited
  /// for the lock is taken instead.
  private mutating func restart(
    after error: InspectorError, on xcode: XcodeBridge, in environment: Environment
  ) async throws(InspectorError) {
    guard let udid = config.udid, let app = config.selector, await Self.answersHello(app, in: environment)
    else { throw noSession(error) }
    let lock = environment.sessionLock(in: folder)
    try await lock.acquire()
    defer { lock.release() }
    let failed = name
    try adoptLatest()
    guard name == failed else { return }
    config = try await Self.startOnDevice(udid, in: folder, fallback: config, on: xcode, in: environment)
    name = config.session ?? name
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
