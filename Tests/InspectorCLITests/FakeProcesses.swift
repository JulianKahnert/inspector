import Foundation
import Synchronization
import Testing

@testable import InspectorKit
@testable import inspector

/// The programs a call runs (`xed`, `simctl`, `git`), in-process: each run is recorded and answered
/// by `reply`.
final class FakeProcesses: Sendable {
  private let reply: @Sendable ([String]) -> ProcessOutput
  private let runs = Mutex<[[String]]>([])

  init(reply: @escaping @Sendable ([String]) -> ProcessOutput) {
    self.reply = reply
  }

  /// Every command line run so far, in order.
  var commands: [[String]] {
    runs.withLock { $0 }
  }

  /// `environment` with its programs run here.
  func environment(_ environment: Environment) -> Environment {
    var environment = environment
    environment.runProcess = { command in
      self.runs.withLock { $0.append(command) }
      return self.reply(command)
    }
    return environment
  }
}

/// A transport that stamps every `hello` with `instance`, as Bonjour does with the name it
/// connected to.
struct NamedTransport: InspectorTransport {
  let base: any InspectorTransport
  let instance: String

  func serve(_ handle: @escaping @Sendable (Request) async -> Response) async throws {
    try await base.serve(handle)
  }

  func send(_ request: Request) async throws -> Response {
    let response = try await base.send(request)
    guard case .hello(var hello) = response else { return response }
    hello.instance = instance
    return .hello(hello)
  }
}

extension Environment {
  /// This environment, its app reached under the full instance name `instance`.
  func named(_ instance: String) -> Environment {
    var environment = self
    let transport = self.transport
    environment.transport = { NamedTransport(base: transport($0), instance: instance) }
    return environment
  }
}
