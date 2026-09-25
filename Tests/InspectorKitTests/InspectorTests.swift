import Foundation
import Synchronization
import Testing

@testable import InspectorKit

private struct Filter: Codable, Sendable, Equatable {
  var query: String
}

@Suite("Inspector")
struct InspectorTests {
  @Test("An Int payload derives an .int schema")
  func intSchema() async {
    let inspector = Inspector()
    inspector.action("counter.set") { (_: Int) in }
    let nodes = await inspector.catalog().actions
    #expect(nodes == [ActionNode(path: "counter.set", payload: .int)])
  }

  @Test("An action with no payload has no schema")
  func noPayloadSchema() async {
    let inspector = Inspector()
    inspector.action("counter.increment") {}
    let nodes = await inspector.catalog().actions
    #expect(nodes == [ActionNode(path: "counter.increment", payload: nil)])
  }

  @Test("An Optional payload derives an .optional schema from its wrapped type")
  func optionalSchema() async {
    let inspector = Inspector()
    inspector.action("counter.set") { (_: Int?) in }
    let nodes = await inspector.catalog().actions
    #expect(nodes == [ActionNode(path: "counter.set", payload: .optional(of: .int))])
  }

  @Test("An Array payload derives an .array schema from its element type")
  func arraySchema() async {
    let inspector = Inspector()
    inspector.action("tags.set") { (_: [String]) in }
    let nodes = await inspector.catalog().actions
    #expect(nodes == [ActionNode(path: "tags.set", payload: .array(of: .string))])
  }

  @Test("A type with no SchemaDescribable conformance falls back to .decodable")
  func decodableFallbackSchema() async {
    let inspector = Inspector()
    inspector.action("search.filter") { (_: Filter) in }
    let nodes = await inspector.catalog().actions
    #expect(nodes == [ActionNode(path: "search.filter", payload: .decodable(type: "Filter"))])
  }

  @Test("An explicit schema argument wins over the derived one")
  func explicitSchemaWins() async {
    let inspector = Inspector()
    inspector.action("plan.set", schema: .enumeration(values: ["free", "pro"])) { (_: String) in }
    let nodes = await inspector.catalog().actions
    #expect(nodes == [ActionNode(path: "plan.set", payload: .enumeration(values: ["free", "pro"]))])
  }

  @Test("State composes every registered key into one object")
  func stateComposition() async throws {
    let inspector = Inspector()
    inspector.state("counter") { 0 }
    inspector.state("device") { ["name": "Mac"] }
    let state = try await inspector.state()
    #expect(state == .object(["counter": 0, "device": .object(["name": "Mac"])]))
  }

  @Test("perform decodes the payload and runs the registered closure")
  func performDecodesPayload() async throws {
    let inspector = Inspector()
    let received = Mutex<Int?>(nil)
    inspector.action("counter.set") { (value: Int) in received.withLock { $0 = value } }
    let settled = try await inspector.perform(path: "counter.set", payload: 42, timeout: .seconds(1))
    #expect(settled)
    #expect(received.withLock { $0 } == 42)
  }

  @Test("perform on an action with no payload ignores an absent payload")
  func performWithNoPayload() async throws {
    let inspector = Inspector()
    let called = Mutex(false)
    inspector.action("counter.increment") { called.withLock { $0 = true } }
    _ = try await inspector.perform(path: "counter.increment", payload: nil, timeout: .seconds(1))
    #expect(called.withLock { $0 })
  }

  @Test("perform with a payload of the wrong type reports a mismatch")
  func performPayloadMismatch() async {
    let inspector = Inspector()
    inspector.action("counter.set") { (_: Int) in }
    await #expect(throws: InspectorError.self) {
      _ = try await inspector.perform(path: "counter.set", payload: .string("abc"), timeout: .seconds(1))
    }
  }

  @Test("perform with a missing payload for an action that needs one reports a mismatch")
  func performMissingPayload() async {
    let inspector = Inspector()
    inspector.action("counter.set") { (_: Int) in }
    do {
      _ = try await inspector.perform(path: "counter.set", payload: nil, timeout: .seconds(1))
      Issue.record("expected a payloadTypeMismatch error")
    } catch let error as InspectorError {
      #expect(error.code == .payloadTypeMismatch)
    } catch {
      Issue.record("expected an InspectorError, got \(error)")
    }
  }

  @Test("perform on an unknown path suggests a sibling sharing the same prefix")
  func performUnknownPathSuggestsSibling() async {
    let inspector = Inspector()
    inspector.action("counter.set") { (_: Int) in }
    inspector.action("counter.increment") {}
    do {
      _ = try await inspector.perform(path: "counter.sett", payload: 1, timeout: .seconds(1))
      Issue.record("expected an unknownActionPath error")
    } catch let error as InspectorError {
      #expect(error.code == .unknownActionPath)
      #expect(error.didYouMean.contains("counter.set"))
    } catch {
      Issue.record("expected an InspectorError, got \(error)")
    }
  }

  // MARK: - Registrations

  @Test("Registering an action path again replaces the previous handler")
  func reRegisteringActionReplacesHandler() async throws {
    let inspector = Inspector()
    let received = Mutex<[String]>([])
    inspector.action("counter.reset") { received.withLock { $0.append("first") } }
    inspector.action("counter.reset") { received.withLock { $0.append("second") } }

    _ = try await inspector.perform(path: "counter.reset", payload: nil, timeout: .seconds(1))
    #expect(received.withLock { $0 } == ["second"])
    #expect(await inspector.catalog().actions == [ActionNode(path: "counter.reset")])
  }

  @Test("Registering a state key again replaces the previous reader")
  func reRegisteringStateReplacesReader() async throws {
    let inspector = Inspector()
    inspector.state("counter") { 1 }
    inspector.state("counter") { 2 }
    #expect(try await inspector.state() == .object(["counter": 2]))
  }

  @Test("cancel() removes exactly its own registration")
  func cancelRemovesOnlyItsRegistration() async throws {
    let inspector = Inspector()
    let increment = inspector.action("counter.increment") {}
    inspector.action("counter.reset") {}
    let device = inspector.state("device") { "Mac" }
    inspector.state("counter") { 0 }

    increment.cancel()
    device.cancel()

    #expect(await inspector.catalog().actions == [ActionNode(path: "counter.reset")])
    #expect(try await inspector.state() == .object(["counter": 0]))
  }

  @Test("A stale token's cancel() leaves a newer registration on the same path in place")
  func staleCancelKeepsNewerRegistration() async throws {
    let inspector = Inspector()
    let received = Mutex<[String]>([])
    let stale = inspector.action("counter.reset") { received.withLock { $0.append("first") } }
    inspector.action("counter.reset") { received.withLock { $0.append("second") } }
    let staleState = inspector.state("counter") { 1 }
    inspector.state("counter") { 2 }

    stale.cancel()
    staleState.cancel()

    _ = try await inspector.perform(path: "counter.reset", payload: nil, timeout: .seconds(1))
    #expect(received.withLock { $0 } == ["second"])
    #expect(try await inspector.state() == .object(["counter": 2]))
  }

  @Test("A @MainActor view model registers from its init, without a Task, and is read and steered")
  @MainActor
  func registersFromMainActorInit() async throws {
    let inspector = Inspector()
    let viewModel = CounterViewModel(inspector: inspector)

    _ = try await inspector.perform(path: "counter.set", payload: 7, timeout: .seconds(1))
    #expect(viewModel.count == 7)
    #expect(try await inspector.state() == .object(["counter": 7]))
  }

  // MARK: - serve

  @Test("A second serve returns at once while the first one still runs")
  func secondServeReturnsImmediately() async throws {
    let inspector = Inspector()
    let transport = BlockingTransport()
    var started = transport.started.makeAsyncIterator()

    let first = Task { try await inspector.serve(app: "Test", over: transport) }
    _ = await started.next()
    try await inspector.serve(app: "Test", over: transport)
    #expect(transport.serveCalls.withLock { $0 } == 1)

    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
  }

  @Test("serve can start again once the running one was cancelled")
  func serveRestartsAfterCancellation() async throws {
    let inspector = Inspector()
    let transport = BlockingTransport()
    var started = transport.started.makeAsyncIterator()

    let first = Task { try await inspector.serve(app: "Test", over: transport) }
    _ = await started.next()
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }

    let second = Task { try await inspector.serve(app: "Test", over: transport) }
    _ = await started.next()
    #expect(transport.serveCalls.withLock { $0 } == 2)
    second.cancel()
    await #expect(throws: CancellationError.self) { try await second.value }
  }
}

/// A transport whose `serve` blocks until its task is cancelled, and announces each entry on
/// `started`, so a test can tell a real second server apart from a call that returned early.
private final class BlockingTransport: InspectorTransport {
  let serveCalls = Mutex(0)
  let started: AsyncStream<Void>
  private let startedContinuation: AsyncStream<Void>.Continuation

  init() {
    (started, startedContinuation) = AsyncStream.makeStream()
  }

  func serve(_ handle: @escaping @Sendable (Request) async -> Response) async throws {
    serveCalls.withLock { $0 += 1 }
    startedContinuation.yield()
    // Throws `CancellationError` as soon as the task is cancelled; the duration is never reached.
    try await Task.sleep(for: .seconds(3600))
  }

  func send(_ request: Request) async throws -> Response {
    throw InspectorError(code: .badRequest, message: "BlockingTransport only serves")
  }
}

@MainActor
private final class CounterViewModel {
  var count = 0
  private var registrations: [Registration] = []

  init(inspector: Inspector) {
    registrations.append(inspector.state("counter") { @MainActor [weak self] in self?.count ?? 0 })
    registrations.append(
      inspector.action("counter.set") { @MainActor [weak self] (value: Int) in self?.count = value })
  }
}
