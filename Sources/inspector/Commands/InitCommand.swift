import ArgumentParser
import Foundation
import InspectorKit

/// `inspector init`: binds this repository to a running debug build of its app, in one call.
struct InitCommand: InspectorCommand {
  static let configuration = CommandConfiguration(
    commandName: "init",
    abstract: "Builds, installs and starts the app through Xcode and writes `.inspector/config.json`.",
    discussion: """
      Cold (the default): starts Xcode when it is not running, opens the repository's workspace, \
      ends the old device interaction session, starts a new one, builds, installs and starts the \
      app with the active scheme, then reads `hello` and `state`. With `--warm` it only reads \
      `hello` and `state` of the app that already serves, for when no code changed since the \
      last run. The answer is `{"config","hello","state"}`. The app keeps its data unless \
      `--reset` uninstalls it first. `--app` names the app when several serve, and the scheme \
      to build when the workspace has one of that name.
      """)

  static let createsFolder = true

  @OptionGroup var options: AppOptions

  @Flag(help: "Only read `hello` and `state` of the serving app: no build, no new session.")
  var warm = false

  @Flag(help: "Uninstall the app from the simulator before installing it, which deletes its data.")
  var reset = false

  @Option(
    help: ArgumentHelp(
      "The `.xcworkspace` or `.xcodeproj` to build, when the repository has several.", valueName: "path"))
  var workspace: String?

  func validate() throws {
    if warm, reset { throw ValidationError("`--reset` needs a build; it cannot go with `--warm`.") }
    if warm, workspace != nil { throw ValidationError("`--workspace` needs a build; it cannot go with `--warm`.") }
  }

  func answer(in environment: Environment) async throws(InspectorError) -> any Encodable {
    let folder = Self.folder(in: environment)
    let previous = try folder.config()
    if warm { return try await warmStart(folder: folder, previous: previous, in: environment) }
    return try await coldStart(folder: folder, previous: previous, in: environment)
  }

  // MARK: - Warm

  /// The app already serves: read it and bind to it, without touching Xcode.
  private func warmStart(
    folder: InspectorFolder, previous: InspectorConfig?, in environment: Environment
  ) async throws(InspectorError) -> Initialized {
    var config = previous ?? InspectorConfig()
    if let app = options.app { config.app = app }
    let hello: Hello
    let state: JSONValue
    do throws(InspectorError) {
      (hello, state) = try await Self.observe(config.selector, in: environment)
    } catch where [.appNotFound, .timeout].contains(error.code) {
      throw InspectorError(
        code: error.code, message: "the app does not serve; run `inspector init` without `--warm`",
        detail: error.message)
    }
    config.instance = hello.instance ?? config.instance
    return try await Self.finish(config, hello: hello, state: state, in: folder, environment)
  }

  // MARK: - Cold

  /// Builds, installs and starts the app in a new device interaction session, then reads it.
  private func coldStart(
    folder: InspectorFolder, previous: InspectorConfig?, in environment: Environment
  ) async throws(InspectorError) -> Initialized {
    let root = FolderLookup.repositoryRoot(from: environment.workingDirectory)
    let location: URL
    if let workspace {
      location = URL(filePath: workspace, relativeTo: environment.workingDirectory)
    } else {
      location = try WorkspaceFinder.find(in: root)
    }
    // Xcode names a workspace by its path without the trailing slash of a directory URL.
    var path = location.standardizedFileURL.path(percentEncoded: false)
    if path.hasSuffix("/") { path.removeLast() }
    let initializeTimeout = try await Self.startXcode(opening: path, in: environment)
    var config = try await XcodeBridge.connect(launch: environment.launchBridge, initializeTimeout: initializeTimeout) {
      xcode throws(InspectorError) in
      try await launch(path, repository: root.lastPathComponent, previous: previous, in: folder, environment, on: xcode)
    }
    let hello: Hello
    let state: JSONValue
    do throws(InspectorError) {
      (hello, state) = try await Self.observeLaunched(config.selector, in: environment)
    } catch where [.appNotFound, .timeout].contains(error.code) {
      throw InspectorError(
        code: error.code,
        message: """
          the app does not serve after its launch; check that its debug build calls `serve()`, or pass \
          `--app` with the name `inspector apps` lists
          """,
        detail: error.message)
    }
    config.instance = hello.instance
    return try await Self.finish(config, hello: hello, state: state, in: folder, environment)
  }

  /// Everything in Xcode: the workspace, scheme and app target, a new session, the build. Writes
  /// `config.json` once the session runs, so `inspector end` reaches it even when the build fails.
  private func launch(
    _ path: String, repository: String, previous: InspectorConfig?, in folder: InspectorFolder,
    _ environment: Environment, on xcode: XcodeBridge
  ) async throws(InspectorError) -> InspectorConfig {
    let opened = try await Self.openWorkspace(path, on: xcode)
    let workspace = opened.workspace
    let scheme = try await selectScheme(active: opened.scheme, in: workspace, on: xcode)
    let target = try await Self.appTarget(of: scheme, in: workspace, on: xcode)
    let settings = try await xcode.call(
      "GetTargetBuildSettings", ["workspaceIdentifier": .string(workspace), "targetName": .string(target)])
    let bundleID = Self.buildSetting("PRODUCT_BUNDLE_IDENTIFIER", in: settings.json)
    let executable =
      Self.buildSetting("EXECUTABLE_NAME", in: settings.json) ?? Self.buildSetting("PRODUCT_NAME", in: settings.json)
    if let old = previous?.session {
      // Its app ends with it; Xcode answers a session it no longer knows without an error.
      _ = try await xcode.call(
        SessionTool.endSession.rawValue, [SessionTool.endSession.sessionParameter: .string(old)])
    }
    let session = DeviceSession.newName(repository: repository, at: environment.now())
    let udid = try await DeviceSession.start(session, workspace: workspace, device: previous?.udid, on: xcode)
    let config = InspectorConfig(
      app: options.app ?? executable, bundleId: bundleID, udid: udid, session: session, workspace: workspace,
      scheme: scheme, logSubsystem: bundleID.map(Self.logSubsystem(forBundleID:)))
    _ = try Self.write(config, to: folder, in: environment)
    if reset {
      guard let udid, let bundleID else {
        throw InspectorError(
          code: .badRequest, message: "`--reset` needs the simulator and the bundle ID; Xcode named not both",
          detail: "udid: \(udid ?? "none"), bundleId: \(bundleID ?? "none")")
      }
      try Self.check(await environment.runProcess(["/usr/bin/xcrun", "simctl", "uninstall", udid, bundleID]))
    }
    // A cold build of a large app takes minutes; Xcode's build error comes back as XCODE_ERROR.
    _ = try await xcode.call(
      SessionTool.installAndRun.rawValue,
      [SessionTool.installAndRun.sessionParameter: .string(session), "workspaceIdentifier": .string(workspace)],
      timeout: .seconds(1200))
    return config
  }

  /// Starts Xcode with the workspace when it is not running and returns how long to wait for its
  /// bridge: a starting Xcode needs up to 30 s.
  private static func startXcode(
    opening path: String, in environment: Environment
  ) async throws(InspectorError) -> Duration {
    guard try await environment.runProcess(["/usr/bin/pgrep", "-x", "Xcode"]).status != 0 else { return .seconds(10) }
    try check(await environment.runProcess(["/usr/bin/xed", "-b", path]))
    return .seconds(30)
  }

  /// Opens the workspace and returns its identifier and active scheme.
  ///
  /// It is also the call that makes Xcode ask a human to approve this binary; Xcode answers it only
  /// after the human confirmed. Only Xcode's refusal means the binary is not approved: no answer
  /// in time may be an Xcode still starting (once 62.9 s), so the agent runs `init` again, which
  /// an unapproved binary then ends in the refusal.
  static func openWorkspace(
    _ path: String, on xcode: XcodeBridge, timeout: Duration = .seconds(90)
  ) async throws(InspectorError) -> (workspace: String, scheme: String?) {
    let opened: JSONValue
    do throws(InspectorError) {
      opened = try await xcode.call("XcodeOpenWorkspace", ["path": .string(path)], timeout: timeout).json
    } catch where error.code == .notApproved {
      throw InspectorError(
        code: .notApproved,
        message: """
          Xcode has not approved this inspector binary; a human confirms Xcode's dialog that asks to allow \
          `\(XcodeBridge.signingIdentifier)`, then `inspector init` runs again
          """,
        detail: error.detail ?? error.message)
    } catch where error.code == .timeout {
      throw InspectorError(
        code: .timeout,
        message: """
          Xcode did not open the workspace within \(timeout.inSeconds) s; a starting Xcode can take a minute, \
          run `inspector init` again
          """,
        detail: error.message)
    }
    guard let workspace = opened.objectValue?["workspaceIdentifier"]?.stringValue else {
      throw InspectorError(
        code: .xcodeError, message: "`XcodeOpenWorkspace` named no workspace identifier", detail: WireJSON.line(opened))
    }
    return (workspace, opened.objectValue?["activeScheme"]?.stringValue)
  }

  /// The scheme to build: the one `--app` names when the workspace has it, else the active one.
  private func selectScheme(
    active: String?, in workspace: String, on xcode: XcodeBridge
  ) async throws(InspectorError) -> String? {
    guard let app = options.app.map(Self.appName), app != active else { return active }
    let schemes = try await xcode.call("XcodeListSchemes", ["workspaceIdentifier": .string(workspace)]).json
    let names = (schemes.objectValue?["schemes"]?.arrayValue ?? []).compactMap {
      $0.objectValue?["name"]?.stringValue
    }
    guard names.contains(app) else { return active }
    _ = try await xcode.call(
      "XcodeSwitchScheme", ["workspaceIdentifier": .string(workspace), "schemeName": .string(app)])
    return app
  }

  /// The app target the scheme builds: the only one, or the one named like the scheme.
  private static func appTarget(
    of scheme: String?, in workspace: String, on xcode: XcodeBridge
  ) async throws(InspectorError) -> String {
    let targets = try await xcode.call(
      "XcodeListTargets", ["workspaceIdentifier": .string(workspace), "productTypeFilter": .array(["application"])]
    ).json
    let names = (targets.objectValue?["targets"]?.arrayValue ?? []).compactMap {
      $0.objectValue?["name"]?.stringValue
    }
    if names.count == 1, let only = names.first { return only }
    if let scheme, names.contains(scheme) { return scheme }
    throw InspectorError(
      code: .badRequest,
      message: "cannot tell which app target the scheme `\(scheme ?? "")` builds; pass `--app` with a target's name",
      detail: names.joined(separator: "\n"))
  }

  /// The evaluated value of the build setting `name`.
  private static func buildSetting(_ name: String, in settings: JSONValue) -> String? {
    let entry = settings.objectValue?["buildSettings"]?.arrayValue?.first {
      $0.objectValue?["macroName"]?.stringValue == name
    }
    return entry?.objectValue?["evaluatedValue"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// The subsystem prefix `logs.sh` reads: `de.juliankahnert.` for `de.juliankahnert.RoommateAlbert`,
  /// so the app's packages logging under their own subsystems are covered; a bundle ID with fewer
  /// than three components stays whole.
  static func logSubsystem(forBundleID bundleID: String) -> String {
    let components = bundleID.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count >= 3 else { return bundleID }
    return components.prefix(2).joined(separator: ".") + "."
  }

  /// `RoommateAlbert` for `RoommateAlbert @ iPhone 17`.
  private static func appName(_ selector: String) -> String {
    selector.components(separatedBy: " @ ")[0]
  }

  // MARK: - Shared

  /// The first observation: who answers and its whole state.
  private static func observe(
    _ selector: String?, in environment: Environment
  ) async throws(InspectorError) -> (Hello, JSONValue) {
    guard case .hello(let hello) = try await environment.response(to: .hello, from: selector),
      case .state(let state) = try await environment.response(to: .state(path: nil), from: hello.instance ?? selector)
    else { throw InspectorError(code: .badRequest, message: "the app answered with an unexpected response") }
    return (hello, state)
  }

  /// ``observe(_:in:)`` for an app that has just started and may not serve yet: each try waits
  /// out the discovery bound once more.
  private static func observeLaunched(
    _ selector: String?, in environment: Environment
  ) async throws(InspectorError) -> (Hello, JSONValue) {
    var attempt = 1
    while true {
      do throws(InspectorError) {
        return try await observe(selector, in: environment)
      } catch where attempt < 3 && [.appNotFound, .timeout].contains(error.code) {
        attempt += 1
      }
    }
  }

  /// Writes the final `config.json`, keeps `.inspector/` out of git, and answers.
  private static func finish(
    _ config: InspectorConfig, hello: Hello, state: JSONValue, in folder: InspectorFolder,
    _ environment: Environment
  ) async throws(InspectorError) -> Initialized {
    let written = try write(config, to: folder, in: environment)
    try await excludeFromGit(folder, in: environment)
    return Initialized(config: written, hello: hello, state: state)
  }

  /// Adds `.inspector/` to `.git/info/exclude` when the folder sits in a repository root that
  /// ignores it nowhere; a repository keeping it in `.gitignore` stays untouched.
  private static func excludeFromGit(
    _ folder: InspectorFolder, in environment: Environment
  ) async throws(InspectorError) {
    let root = folder.url.deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: root.appending(path: ".git").path) else { return }
    let git = ["/usr/bin/git", "-C", root.path(percentEncoded: false)]
    // `check-ignore` exits 0 for an ignored path and 1 for one that is not.
    guard try await environment.runProcess(git + ["check-ignore", "-q", ".inspector/"]).status == 1 else { return }
    let located = try await environment.runProcess(git + ["rev-parse", "--git-path", "info/exclude"])
    try check(located)
    // Relative to `root`, or absolute in a worktree, whose excludes live in the main repository.
    let exclude = URL(
      filePath: located.stdout.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: root
    ).standardizedFileURL
    do {
      var text = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
      if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
      try FileManager.default.createDirectory(
        at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data((text + "/.inspector/\n").utf8).write(to: exclude, options: .atomic)
    } catch {
      throw InspectorError(
        code: .badRequest, message: "could not add `.inspector/` to `\(exclude.path)`", detail: "\(error)")
    }
  }

  /// `.inspector/` where calls from here look for it, created when there is none yet.
  private static func folder(in environment: Environment) -> InspectorFolder {
    switch FolderLookup.locate(from: environment.workingDirectory, override: environment.inspectorDirectory) {
    case .found(let folder): return folder
    case .missing(let expected): return InspectorFolder(url: expected)
    }
  }

  /// Writes `config` and returns `config.json` as written.
  private static func write(
    _ config: InspectorConfig, to folder: InspectorFolder, in environment: Environment
  ) throws(InspectorError) -> JSONValue {
    let file = folder.url.appending(path: "config.json")
    do {
      try folder.writeConfig(config, at: environment.now())
      return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
    } catch {
      throw InspectorError(code: .badRequest, message: "could not write `\(file.path)`", detail: "\(error)")
    }
  }

  /// A program that failed, as an error that quotes what it printed.
  private static func check(_ output: ProcessOutput) throws(InspectorError) {
    guard output.status != 0 else { return }
    let text = (output.stderr.isEmpty ? output.stdout : output.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
    throw InspectorError(code: .badRequest, message: "a program `init` runs failed: \(text)", detail: text)
  }

  /// What `init` answers: the binding it wrote and the first observation.
  struct Initialized: Encodable {
    var config: JSONValue
    var hello: Hello
    var state: JSONValue
  }
}
