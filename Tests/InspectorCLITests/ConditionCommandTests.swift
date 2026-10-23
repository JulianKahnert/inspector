import Foundation
import Synchronization
import Testing

@testable import InspectorKit
@testable import inspector

@Suite("Conditions on the command line")
struct ConditionCommandTests {
  @Test(
    "send with --until answers like send once the condition holds, wherever the options stand",
    arguments: [
      ["send", "counter.set", "42", "--until", #"{"counter":42}"#],
      ["send", "--until", #"{"counter":42}"#, "counter.set", "42"],
      ["send", "counter.set", "42", "--until", #"{"counter":42}"#, "--timeout", "2"],
      ["send", "counter.set", "--timeout", "0.5", "42", "--until", #"{"counter":{}}"#],
    ])
  func sendUntil(arguments: [String]) async throws {
    #expect(
      await InspectorCLI.outcome(of: arguments, in: try await conditionApp())
        == .stdout(
          #"{"diff":[{"new":42,"old":0,"path":"counter"}],"settled":true,"state":{"counter":42,"device":{"name":"Mac","pid":"1"}}}"#
        ))
  }

  @Test("send with --until takes a payload that starts with a dash")
  func sendUntilNegativePayload() async throws {
    let outcome = await InspectorCLI.outcome(
      of: ["send", "counter.set", "-5", "--until", #"{"counter":-5}"#], in: try await conditionApp())
    #expect(
      outcome
        == .stdout(
          #"{"diff":[{"new":-5,"old":0,"path":"counter"}],"settled":true,"state":{"counter":-5,"device":{"name":"Mac","pid":"1"}}}"#
        ))
  }

  @Test("send with --until that does not hold in time fails with EXPECTATION_FAILED and the last state")
  func sendUntilFails() async throws {
    let outcome = await InspectorCLI.outcome(
      of: ["send", "counter.set", "7", "--until", #"{"counter":8}"#, "--timeout", "0.05"], in: try await conditionApp())
    #expect(
      outcome
        == .stderr(
          #"{"code":"EXPECTATION_FAILED","detail":"{\"counter\":7,\"device\":{\"name\":\"Mac\",\"pid\":\"1\"}}","message":"`{\"counter\":8}` did not hold within 50 ms"}"#
        ))
  }

  @Test("send with --until asks the app to wait 3 seconds unless --timeout says otherwise")
  func sendUntilRequest() async throws {
    let log = RequestLog()
    let environment = try await conditionApp(recording: log)

    _ = await InspectorCLI.outcome(of: ["send", "counter.set", "1", "--until", #"{"counter":1}"#], in: environment)
    _ = await InspectorCLI.outcome(
      of: ["send", "counter.set", "1", "--until", #"{"counter":1}"#, "--timeout", "1.5"], in: environment)
    _ = await InspectorCLI.outcome(of: ["send", "counter.set", "1"], in: environment)

    #expect(
      log.requests.withLock { $0 } == [
        .send(SendRequest(path: "counter.set", payload: 1, until: .object(["counter": 1]))),
        .send(SendRequest(path: "counter.set", payload: 1, until: .object(["counter": 1]), untilTimeoutMs: 1_500)),
        .send(SendRequest(path: "counter.set", payload: 1)),
      ])
  }

  @Test("wait prints the state once the condition holds")
  func waitHolds() async throws {
    let outcome = await InspectorCLI.outcome(
      of: ["wait", #"{"counter":0}"#, "--app", "DemoHost"], in: try await conditionApp())
    #expect(outcome == .stdout(#"{"counter":0,"device":{"name":"Mac","pid":"1"}}"#))
  }

  @Test("wait that does not hold in time fails with EXPECTATION_FAILED and the last state")
  func waitFails() async throws {
    let outcome = await InspectorCLI.outcome(
      of: ["wait", #"{"counter":99}"#, "--timeout", "0.05"], in: try await conditionApp())
    #expect(
      outcome
        == .stderr(
          #"{"code":"EXPECTATION_FAILED","detail":"{\"counter\":0,\"device\":{\"name\":\"Mac\",\"pid\":\"1\"}}","message":"`{\"counter\":99}` did not hold within 50 ms"}"#
        ))
  }

  @Test("wait sends the match and the timeout in milliseconds")
  func waitRequest() async throws {
    let log = RequestLog()
    let environment = try await conditionApp(recording: log)

    _ = await InspectorCLI.outcome(of: ["wait", #"{"counter":0}"#], in: environment)
    _ = await InspectorCLI.outcome(of: ["wait", #"{"counter":0}"#, "--timeout", "10"], in: environment)

    #expect(
      log.requests.withLock { $0 } == [
        .wait(WaitRequest(until: .object(["counter": 0]))),
        .wait(WaitRequest(until: .object(["counter": 0]), timeoutMs: 10_000)),
      ])
  }

  @Test(
    "a malformed condition is a usage error with exit code 64",
    arguments: [
      ["wait"],
      ["wait", "counter"],
      ["wait", "42"],
      ["wait", "[1]"],
      ["wait", #"{"counter":0}"#, "--timeout", "0"],
      ["wait", #"{"counter":0}"#, "--timeout", "-1"],
      ["wait", #"{"counter":0}"#, "--timeout", "soon"],
      ["send", "counter.set", "1", "--until"],
      ["send", "counter.set", "1", "--until", "counter"],
      ["send", "counter.set", "1", "--timeout", "2"],
    ])
  func usageError(arguments: [String]) async throws {
    let outcome = await InspectorCLI.outcome(of: arguments, in: try await conditionApp())

    #expect(outcome.exitCode == 64)
    #expect(outcome.stdout == "")
    #expect(outcome.stderr.contains("Usage: inspector"))
  }
}

/// demo-host's registrations, served in-process, with every request the CLI sends appended to
/// `log`.
private func conditionApp(recording log: RequestLog? = nil) async throws -> Environment {
  let counter = Mutex(0)
  let inspector = Inspector()
  inspector.state("counter") { counter.withLock { $0 } }
  inspector.state("device") { ["name": "Mac", "pid": "1"] }
  inspector.action("counter.increment") { counter.withLock { $0 += 1 } }
  inspector.action("counter.set") { (value: Int) in counter.withLock { $0 = value } }
  let core = InspectorCore(provider: inspector, app: "DemoHost")
  let transport = InMemoryTransport()
  try await transport.serve { request in
    log?.requests.withLock { $0.append(request) }
    return await core.handle(request)
  }
  return Environment(transport: { _ in transport }, instanceNames: { _ in ["DemoHost @ Mac"] })
}

/// Every request an in-process app received, in order.
private final class RequestLog: Sendable {
  let requests = Mutex<[Request]>([])
}
