import Foundation
import Synchronization
import Testing

@testable import InspectorKit

@Suite("InMemoryTransport")
struct InMemoryTransportTests {
  @Test("a request travels Inspector -> InspectorCore -> transport -> client and back")
  func endToEnd() async throws {
    let counter = Mutex(0)
    let inspector = Inspector()
    inspector.state("counter") { counter.withLock { $0 } }
    inspector.action("counter.set") { (value: Int) in counter.withLock { $0 = value } }

    let core = InspectorCore(provider: inspector, app: "Test")
    let transport = InMemoryTransport()
    try await transport.serve { await core.handle($0) }

    guard case .hello(let hello) = try await transport.send(.hello) else {
      Issue.record("expected a hello response")
      return
    }
    #expect(hello.app == "Test")
    #expect(hello.provider == "Inspector")

    guard case .catalog(let catalog) = try await transport.send(.catalog) else {
      Issue.record("expected a catalog response")
      return
    }
    #expect(catalog.actions == [ActionNode(path: "counter.set", payload: .int)])

    let sendResponse = try await transport.send(.send(SendRequest(path: "counter.set", payload: 42)))
    guard case .sendResult(let result) = sendResponse else {
      Issue.record("expected a sendResult response")
      return
    }
    #expect(result.state == .object(["counter": 42]))

    guard case .state(let state) = try await transport.send(.state(path: "counter")) else {
      Issue.record("expected a state response")
      return
    }
    #expect(state == .int(42))
  }

  @Test("sending before a server is registered fails with a bad request, not a crash")
  func sendWithoutServer() async {
    let transport = InMemoryTransport()
    await #expect(throws: InspectorError.self) {
      _ = try await transport.send(.hello)
    }
  }
}
