import Foundation
import InspectorKit

/// Everything a command reaches outside the process; a test swaps it for an in-memory app and a
/// temporary directory.
struct Environment: Sendable {
  /// The transport to the app `app` selects, or to the only serving app when `nil`.
  var transport: @Sendable (_ app: String?) -> any InspectorTransport
  /// The instance names of every serving app found while browsing for the given time.
  var instanceNames: @Sendable (_ browsingFor: Duration) async throws -> [String]
  /// The directory the call runs in; `.inspector/` is looked for from here upwards.
  var workingDirectory: URL
  /// `INSPECTOR_DIR`: the `.inspector/` folder to use instead of looking for one.
  var inspectorDirectory: String?
  /// The clock that stamps `run.json` and `config.json`.
  var now: @Sendable () -> Date
  /// The `.env` values this call filled in; ``InspectorCLI/outcome(of:in:)`` starts each call
  /// with none.
  var substitutions = Substitutions()
  /// Starts a bridge to Xcode's tools; see ``XcodeBridge``.
  var launchBridge: @Sendable () throws(InspectorError) -> any BridgeProcess = {
    throw InspectorError(code: .xcodeError, message: "this environment has no Xcode")
  }
  /// Runs a program such as `xed`, `simctl` or `git` to its end; `command[0]` is its absolute
  /// path.
  var runProcess: @Sendable (_ command: [String]) async throws(InspectorError) -> ProcessOutput = {
    _ throws(InspectorError) in
    throw InspectorError(code: .badRequest, message: "this environment runs no programs")
  }

  /// The apps on the network, found through Bonjour, and Xcode through `xcrun mcpbridge`, from the
  /// process's working directory.
  static var live: Environment {
    Environment(
      transport: { BonjourTransport(name: $0) },
      instanceNames: { try await BonjourTransport.instanceNames(browsingFor: $0) },
      workingDirectory: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
      inspectorDirectory: ProcessInfo.processInfo.environment["INSPECTOR_DIR"],
      now: { Date() },
      launchBridge: { () throws(InspectorError) in try BridgeSubprocess() },
      runProcess: { command throws(InspectorError) in try await ProcessOutput.run(command) })
  }

  /// Runs `body` with a fresh connection to Xcode's tools, closed when `body` returns.
  func withXcode<T>(_ body: (XcodeBridge) async throws(InspectorError) -> T) async throws(InspectorError) -> T {
    try await XcodeBridge.connect(launch: launchBridge, body)
  }

  /// The value in `.inspector/.env` of every `${NAME}` in `text`, by name; empty when `text` has
  /// no placeholder.
  ///
  /// The values are masked in everything this call prints and writes from now on.
  ///
  /// - Throws: ``ErrorCode/noConfig`` without a folder, ``ErrorCode/envMissing`` naming every
  ///   placeholder without a value.
  func placeholderValues(in text: String) throws(InspectorError) -> [String: String] {
    let names = Placeholders.names(in: text)
    guard !names.isEmpty else { return [:] }
    let file = try requiredFolder().url.appending(path: ".env")
    let available = DotEnv.parse((try? String(contentsOf: file, encoding: .utf8)) ?? "")
    let missing = names.filter { available[$0] == nil }
    guard missing.isEmpty else {
      throw InspectorError(
        code: .envMissing,
        message: "no value for \(missing.map { "`${\($0)}`" }.joined(separator: ", ")) in `\(file.path)`",
        detail: missing.joined(separator: " "))
    }
    let values = available.filter { names.contains($0.key) }
    substitutions.record(values)
    return values
  }

  /// The `.inspector/` folder this call works with, or `nil` when there is none.
  ///
  /// - Throws: ``ErrorCode/noConfig`` when `INSPECTOR_DIR` names a folder that does not exist.
  func folder() throws(InspectorError) -> InspectorFolder? {
    switch FolderLookup.locate(from: workingDirectory, override: inspectorDirectory) {
    case .found(let folder):
      return folder
    case .missing(let expected):
      guard inspectorDirectory?.isEmpty ?? true else { throw Self.noConfig(expected) }
      return nil
    }
  }

  /// The `.inspector/` folder, for a call that cannot work without it.
  ///
  /// - Throws: ``ErrorCode/noConfig`` with the path where the folder was expected.
  func requiredFolder() throws(InspectorError) -> InspectorFolder {
    switch FolderLookup.locate(from: workingDirectory, override: inspectorDirectory) {
    case .found(let folder): return folder
    case .missing(let expected): throw Self.noConfig(expected)
    }
  }

  private static func noConfig(_ expected: URL) -> InspectorError {
    InspectorError(
      code: .noConfig, message: "no `.inspector/` folder; run `inspector init`", detail: expected.path)
  }

  /// Sends `request` to the app `app` selects and returns the payload of its response.
  ///
  /// Without `app`, it goes to the `instance` in `.inspector/config.json`, and without that to the
  /// only serving app.
  ///
  /// - Throws: the app's rejection, a discovery or timeout error from the transport, and
  ///   ``ErrorCode/badRequest`` for anything else that keeps the request from the app.
  func answer(to request: Request, from app: String?) async throws(InspectorError) -> any Encodable {
    switch try await response(to: request, from: app) {
    case .hello(let hello): return hello
    case .catalog(let catalog): return catalog
    case .state(let state): return state
    case .sendResult(let result): return result
    case .error(let error): throw error
    }
  }

  /// Sends `request` to the app `app` selects and returns its response, for a command that
  /// prints only part of it.
  ///
  /// - Throws: the same errors as ``answer(to:from:)``; an `.error` response is thrown, never
  ///   returned.
  func response(to request: Request, from app: String?) async throws(InspectorError) -> Response {
    var selector = app
    if selector == nil { selector = try folder()?.config()?.selector }
    let response: Response
    do {
      response = try await transport(selector).send(request)
    } catch let error as InspectorError {
      throw error
    } catch {
      throw InspectorError(code: .badRequest, message: "could not reach the app", detail: "\(error)")
    }
    if case .error(let error) = response { throw error }
    return response
  }
}
