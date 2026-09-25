import Synchronization

/// Runs the app and the CLI in the same process, for tests: `serve` registers the handler and
/// returns immediately, since there is no real listener to keep alive.
final class InMemoryTransport: InspectorTransport {
  private let handler = Mutex<(@Sendable (Request) async -> Response)?>(nil)

  init() {}

  func serve(_ handle: @escaping @Sendable (Request) async -> Response) async throws {
    handler.withLock { $0 = handle }
  }

  func send(_ request: Request) async throws -> Response {
    guard let handle = handler.withLock({ $0 }) else {
      throw InspectorError(code: .badRequest, message: "no server registered")
    }
    return await handle(request)
  }
}
