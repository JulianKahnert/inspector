import Foundation
import Synchronization
import Testing

@testable import InspectorKit

/// An ``Inspectable`` whose state counts its own reads, so a condition on it holds only after a
/// known number of checks.
private final class ReadCounter: Inspectable {
  let name = "ReadCounter"
  private let reads = Mutex(0)

  func catalog() async -> Catalog { Catalog(actions: []) }

  func state() async throws -> JSONValue {
    .object(["reads": .int(reads.withLock { $0 += 1; return $0 })])
  }

  func perform(path: String, payload: JSONValue?, timeout: Duration) async throws -> Bool { true }
}

/// Resumes the first caller of ``wait()`` once ``signal()`` has run, whichever comes first.
private final class Gate: Sendable {
  private let state = Mutex<(signalled: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

  func signal() {
    let waiter = state.withLock { state in
      state.signalled = true
      defer { state.waiter = nil }
      return state.waiter
    }
    waiter?.resume()
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      let resumeNow = state.withLock { state in
        if state.signalled { return true }
        state.waiter = continuation
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }
}

@Suite("Conditions", .timeLimit(.minutes(1)))
struct ConditionTests {
  @Test("wait answers at once with the state when the match already holds")
  func waitHoldsAtOnce() async {
    let inspector = Inspector()
    inspector.state("counter") { 0 }
    let core = InspectorCore(provider: inspector, app: "Test", tick: .seconds(3600))

    let response = await core.handle(.wait(WaitRequest(until: .object(["counter": 0]))))

    #expect(response == .sendResult(SendResult(settled: true, state: .object(["counter": 0]), diff: [])))
  }

  @Test("wait that does not hold within its timeout fails with EXPECTATION_FAILED and the last state")
  func waitTimesOut() async {
    let inspector = Inspector()
    inspector.state("counter") { 0 }
    let core = InspectorCore(provider: inspector, app: "Test", tick: .milliseconds(5))

    let response = await core.handle(.wait(WaitRequest(until: .object(["counter": 99]), timeoutMs: 50)))

    #expect(
      response
        == .error(
          InspectorError(
            code: .expectationFailed,
            message: #"`{"counter":99}` did not hold within 50 ms"#,
            detail: #"{"counter":0}"#)))
  }

  @Test("wait checks again on every tick, and diffs against the state it started from")
  func waitPollsOnTick() async {
    let core = InspectorCore(provider: ReadCounter(), app: "Test", tick: .milliseconds(1))

    let response = await core.handle(.wait(WaitRequest(until: .object(["reads": 3]))))

    #expect(
      response
        == .sendResult(
          SendResult(settled: true, state: .object(["reads": 3]), diff: [JSONDiffEntry(path: "reads", old: 1, new: 3)])))
  }

  @Test("wait with a baseline diffs against it, so a caller can report what its own step changed")
  func waitDiffsAgainstBaseline() async {
    let inspector = Inspector()
    inspector.state("counter") { 42 }
    let core = InspectorCore(provider: inspector, app: "Test", tick: .seconds(3600))

    let response = await core.handle(
      .wait(WaitRequest(until: .object(["counter": 42]), baseline: .object(["counter": 0]))))

    #expect(
      response
        == .sendResult(
          SendResult(
            settled: true, state: .object(["counter": 42]), diff: [JSONDiffEntry(path: "counter", old: 0, new: 42)])))
  }

  @Test("A key registered while wait runs is seen at once, without waiting for the tick")
  func waitWakesOnRegistration() async {
    let inspector = Inspector()
    let firstCheck = Gate()
    inspector.state("probe") {
      firstCheck.signal()
      return true
    }
    // A tick far beyond the timeout: only the registration itself can end this wait in time.
    let core = InspectorCore(provider: inspector, app: "Test", tick: .seconds(3600))

    let clock = ContinuousClock()
    let start = clock.now
    async let response = core.handle(.wait(WaitRequest(until: .object(["detail": .object([:])]), timeoutMs: 10_000)))
    await firstCheck.wait()
    inspector.state("detail") { "open" }
    let answer = await response

    // The final check at the deadline would find the key too; only the time tells the two apart.
    #expect(clock.now - start < .seconds(5))
    #expect(
      answer
        == .sendResult(
          SendResult(
            settled: true, state: .object(["detail": "open", "probe": true]),
            diff: [JSONDiffEntry(path: "detail", old: nil, new: "open")])))
  }

  @Test("send with until answers once the screen its action opens has registered, diffed against before the action")
  func sendUntilWaitsForLateRegistration() async {
    let inspector = Inspector()
    let reads = Mutex(0)
    let firstCheckAfterAction = Gate()
    inspector.state("list") {
      // The first read is the state before the action, the second the condition's first check.
      if reads.withLock({ $0 += 1; return $0 }) == 2 { firstCheckAfterAction.signal() }
      return "shown"
    }
    inspector.action("detail.open") {
      // The screen registers after the action returned, as a view model created by navigation does.
      Task {
        await firstCheckAfterAction.wait()
        inspector.state("detail") { "open" }
      }
    }
    let core = InspectorCore(provider: inspector, app: "Test", tick: .seconds(3600))
    let clock = ContinuousClock()
    let start = clock.now

    let response = await core.handle(
      .send(SendRequest(path: "detail.open", until: .object(["detail": "open"]), untilTimeoutMs: 10_000)))

    #expect(clock.now - start < .seconds(5))
    #expect(
      response
        == .sendResult(
          SendResult(
            settled: true, state: .object(["detail": "open", "list": "shown"]),
            diff: [JSONDiffEntry(path: "detail", old: nil, new: "open")])))
  }

  @Test("send with until that does not hold fails with EXPECTATION_FAILED and the state after the action")
  func sendUntilTimesOut() async {
    let inspector = Inspector()
    let counter = Mutex(0)
    inspector.state("counter") { counter.withLock { $0 } }
    inspector.action("counter.set") { (value: Int) in counter.withLock { $0 = value } }
    let core = InspectorCore(provider: inspector, app: "Test", tick: .milliseconds(5))

    let response = await core.handle(
      .send(SendRequest(path: "counter.set", payload: 7, until: .object(["counter": 8]), untilTimeoutMs: 30)))

    #expect(
      response
        == .error(
          InspectorError(
            code: .expectationFailed,
            message: #"`{"counter":8}` did not hold within 30 ms"#,
            detail: #"{"counter":7}"#)))
  }
}
