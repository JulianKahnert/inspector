import Testing

@testable import InspectorKit

@Suite("withDeadline")
struct DeadlineTests {
  private let late = InspectorError(code: .timeout, message: "too late")

  @Test("an operation that ends in time gives its value")
  func valueInTime() async throws {
    #expect(try await withDeadline(.seconds(60), orThrow: late) { 42 } == 42)
  }

  @Test("an operation's own error comes through as it is")
  func operationError() async throws {
    let failure = InspectorError(code: .badRequest, message: "broken")
    await #expect(throws: failure) {
      try await withDeadline(.seconds(60), orThrow: late) { () async throws -> Int in throw failure }
    }
  }

  @Test("the bound holds while the operation ignores cancellation, as Network's browser and connection can")
  func boundHoldsAgainstAnOperationThatIgnoresCancellation() async throws {
    let gate = Gate()
    // Opens the gate in any case, so a broken bound shows as a failure instead of a hang.
    let rescue = Task {
      try? await Task.sleep(for: .seconds(2))
      await gate.open()
    }

    await #expect(throws: late) {
      try await withDeadline(.milliseconds(10), orThrow: late) { () async throws -> Int in
        await gate.wait()
        return 1
      }
    }

    #expect(await !gate.isOpen, "the call waited for the operation instead of leaving it behind")
    rescue.cancel()
    await gate.open()
  }
}

/// A wait that only `open()` ends; cancelling the waiting task does nothing.
private actor Gate {
  private(set) var isOpen = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiting.append($0) }
  }

  func open() {
    isOpen = true
    waiting.forEach { $0.resume() }
    waiting.removeAll()
  }
}
