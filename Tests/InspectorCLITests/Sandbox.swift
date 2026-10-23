import Foundation
import Synchronization
import Testing

@testable import InspectorKit
@testable import inspector

extension Environment {
  /// An environment outside any `.inspector/` folder, stamped with ``Sandbox/now``.
  init(
    transport: @escaping @Sendable (_ app: String?) -> any InspectorTransport,
    instanceNames: @escaping @Sendable (_ browsingFor: Duration) async throws -> [String]
  ) {
    self.init(
      transport: transport,
      instanceNames: instanceNames,
      workingDirectory: URL(filePath: "/nonexistent-inspector-test-directory", directoryHint: .isDirectory),
      inspectorDirectory: nil,
      now: { Sandbox.now })
  }

  /// This environment, with every app name the transport is asked for recorded in `selections`.
  func recording(_ selections: Selections) -> Environment {
    var environment = self
    let transport = self.transport
    environment.transport = { app in
      selections.names.withLock { $0.append(app) }
      return transport(app)
    }
    return environment
  }
}

/// The app names a transport was asked for, in order.
final class Selections: Sendable {
  let names = Mutex<[String?]>([])

  var all: [String?] { names.withLock { $0 } }
}

/// A temporary directory a test lays out files in; removed when the test ends.
struct Sandbox {
  /// The time every sandboxed call stamps its files with.
  static let now = Date(timeIntervalSince1970: 1_792_400_000.25)

  /// The sandbox's top directory.
  let root: URL

  /// Runs `body` in a fresh, empty sandbox and removes it afterwards.
  static func run(_ body: (Sandbox) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "inspector-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(Sandbox(root: root.resolvingSymlinksInPath()))
  }

  /// The URL of `path` inside the sandbox.
  func url(_ path: String) -> URL {
    root.appending(path: path)
  }

  /// Writes `text` to `path`, creating the directories on the way.
  func write(_ path: String, _ text: String) throws {
    let file = url(path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
  }

  /// Creates the directory `path` and the ones on the way.
  func makeDirectory(_ path: String) throws {
    try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
  }

  /// The text at `path`, or `nil` when there is no such file.
  func read(_ path: String) -> String? {
    guard let data = try? Data(contentsOf: url(path)) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  /// The JSON document at `path`.
  func json(_ path: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url(path)))
  }

  /// `environment`, running in the sandbox directory `path`.
  func environment(_ environment: Environment, in path: String = "") -> Environment {
    var environment = environment
    environment.workingDirectory = path.isEmpty ? root : url(path)
    return environment
  }
}
