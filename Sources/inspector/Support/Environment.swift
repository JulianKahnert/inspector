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

  /// The apps on the network, found through Bonjour, from the process's working directory.
  static var live: Environment {
    Environment(
      transport: { BonjourTransport(name: $0) },
      instanceNames: { try await BonjourTransport.instanceNames(browsingFor: $0) },
      workingDirectory: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
      inspectorDirectory: ProcessInfo.processInfo.environment["INSPECTOR_DIR"],
      now: { Date() })
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
    switch response {
    case .hello(let hello): return hello
    case .catalog(let catalog): return catalog
    case .state(let state): return state
    case .sendResult(let result): return result
    case .error(let error): throw error
    }
  }
}
