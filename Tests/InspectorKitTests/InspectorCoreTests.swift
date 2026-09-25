import Foundation
import Synchronization
import Testing

@testable import InspectorKit

/// A minimal ``Inspectable`` whose state is one counter, so tests can assert on the exact
/// diff and settled value a `send` produces.
private final class FakeInspectable: Inspectable {
  let name = "Fake"
  private let counter = Mutex(0)

  func catalog() async -> Catalog {
    Catalog(actions: [ActionNode(path: "counter.set", payload: .int)])
  }

  func state() async throws -> JSONValue {
    .object(["counter": .int(counter.withLock { $0 })])
  }

  func perform(path: String, payload: JSONValue?, timeout: Duration) async throws -> Bool {
    guard path == "counter.set", let value = payload?.intValue else {
      throw InspectorError(code: .unknownActionPath, message: "no action at `\(path)`")
    }
    counter.withLock { $0 = value }
    return true
  }
}

@Suite("InspectorCore")
struct InspectorCoreTests {
  @Test("send diffs state before and after, and returns the new state")
  func sendReturnsDiffAndState() async throws {
    let core = InspectorCore(provider: FakeInspectable(), app: "Fake")
    let result = try await core.send(SendRequest(path: "counter.set", payload: 42))
    #expect(result.settled)
    #expect(result.state == .object(["counter": 42]))
    #expect(result.diff == [JSONDiffEntry(path: "counter", old: 0, new: 42)])
  }

  @Test("state(path:) selects an object member by dotted segment")
  func statePathSelectsObjectMember() async throws {
    let core = InspectorCore(provider: FakeInspectable(), app: "Fake")
    let value = try await core.state(path: "counter")
    #expect(value == .int(0))
  }

  @Test("state(path:) on an unknown path reports unknownStatePath")
  func statePathUnknown() async {
    let core = InspectorCore(provider: FakeInspectable(), app: "Fake")
    do {
      _ = try await core.state(path: "nope")
      Issue.record("expected an unknownStatePath error")
    } catch let error as InspectorError {
      #expect(error.code == .unknownStatePath)
    } catch {
      Issue.record("expected an InspectorError, got \(error)")
    }
  }

  @Test("handle answers hello with the app name, pid and provider name")
  func handleHello() async {
    let core = InspectorCore(provider: FakeInspectable(), app: "Fake")
    guard case .hello(let hello) = await core.handle(.hello) else {
      Issue.record("expected a hello response")
      return
    }
    #expect(hello.app == "Fake")
    #expect(hello.provider == "Fake")
  }

  @Test("handle maps a thrown InspectorError to .error")
  func handleMapsInspectorErrorToErrorResponse() async {
    let core = InspectorCore(provider: FakeInspectable(), app: "Fake")
    let response = await core.handle(.send(SendRequest(path: "nope")))
    guard case .error(let error) = response else {
      Issue.record("expected an error response")
      return
    }
    #expect(error.code == .unknownActionPath)
  }
}
