import Foundation
import Synchronization
import Testing

@testable import InspectorKit
@testable import inspector

@Suite("Commands")
struct CommandTests {
  @Test("hello prints the app, its pid and the provider as one JSON line")
  func hello() async throws {
    let outcome = await InspectorCLI.outcome(of: ["hello"], in: try await demoApp())
    let pid = ProcessInfo.processInfo.processIdentifier
    #expect(
      outcome
        == Outcome(stdout: "{\"app\":\"DemoHost\",\"pid\":\(pid),\"provider\":\"Inspector\"}\n", stderr: "", exitCode: 0))
  }

  @Test("catalog lists every action with its payload schema")
  func catalog() async throws {
    let outcome = await InspectorCLI.outcome(of: ["catalog"], in: try await demoApp())
    #expect(
      outcome
        == .stdout(#"{"actions":[{"path":"counter.increment"},{"path":"counter.set","payload":{"kind":"int"}}]}"#))
  }

  @Test(
    "state prints the whole state or the subtree at a path",
    arguments: [
      (["state"], Outcome.stdout(#"{"counter":0,"device":{"name":"Mac","pid":"1"}}"#)),
      (["state", "counter"], .stdout("0")),
      (["state", "device.name"], .stdout(#""Mac""#)),
    ])
  func state(arguments: [String], expected: Outcome) async throws {
    #expect(await InspectorCLI.outcome(of: arguments, in: try await demoApp()) == expected)
  }

  @Test("state at a path that selects nothing fails with UNKNOWN_STATE_PATH on stderr")
  func unknownStatePath() async throws {
    let outcome = await InspectorCLI.outcome(of: ["state", "nope"], in: try await demoApp())
    #expect(outcome == .stderr(#"{"code":"UNKNOWN_STATE_PATH","message":"no state at `nope`"}"#))
  }

  @Test(
    "send prints settled, the new state and the diff",
    arguments: [
      (
        ["send", "counter.set", "42"],
        Outcome.stdout(
          #"{"diff":[{"new":42,"old":0,"path":"counter"}],"settled":true,"state":{"counter":42,"device":{"name":"Mac","pid":"1"}}}"#)
      ),
      (
        ["send", "counter.set", "-5"],
        .stdout(
          #"{"diff":[{"new":-5,"old":0,"path":"counter"}],"settled":true,"state":{"counter":-5,"device":{"name":"Mac","pid":"1"}}}"#)
      ),
      (
        ["send", "counter.increment"],
        .stdout(
          #"{"diff":[{"new":1,"old":0,"path":"counter"}],"settled":true,"state":{"counter":1,"device":{"name":"Mac","pid":"1"}}}"#)
      ),
    ])
  func send(arguments: [String], expected: Outcome) async throws {
    #expect(await InspectorCLI.outcome(of: arguments, in: try await demoApp()) == expected)
  }

  @Test(
    "send relays the app's rejection as one JSON line on stderr",
    arguments: [
      (
        ["send", "counter.set", "abc"],
        Outcome.stderr(#"{"code":"PAYLOAD_TYPE_MISMATCH","message":"expected integer, got string"}"#)
      ),
      (
        ["send", "counter.sett"],
        .stderr(
          #"{"code":"UNKNOWN_ACTION_PATH","didYouMean":["counter.increment","counter.set"],"message":"no action at `counter.sett`"}"#)
      ),
    ])
  func sendRejected(arguments: [String], expected: Outcome) async throws {
    #expect(await InspectorCLI.outcome(of: arguments, in: try await demoApp()) == expected)
  }

  @Test(
    "--app selects the app wherever it stands",
    arguments: [
      ["--app", "DemoHost", "hello"],
      ["hello", "--app", "DemoHost"],
      ["--app", "DemoHost", "catalog"],
      ["state", "--app", "DemoHost", "counter"],
      ["state", "counter", "--app", "DemoHost"],
      ["send", "--app", "DemoHost", "counter.set", "1"],
      ["send", "counter.set", "1", "--app", "DemoHost"],
      ["send", "counter.set", "--app", "DemoHost", "-1"],
    ])
  func appOption(arguments: [String]) async throws {
    let selected = Mutex<[String?]>([])
    var environment = try await demoApp()
    let transport = environment.transport
    environment.transport = { app in
      selected.withLock { $0.append(app) }
      return transport(app)
    }

    let outcome = await InspectorCLI.outcome(of: arguments, in: environment)

    #expect(outcome.exitCode == 0)
    #expect(selected.withLock { $0 } == ["DemoHost"])
  }

  @Test("without --app the transport looks for the only serving app")
  func noAppOption() async throws {
    let selected = Mutex<[String?]>([])
    var environment = try await demoApp()
    let transport = environment.transport
    environment.transport = { app in
      selected.withLock { $0.append(app) }
      return transport(app)
    }

    _ = await InspectorCLI.outcome(of: ["hello"], in: environment)

    #expect(selected.withLock { $0 } == [nil])
  }

  @Test("a discovery error from the transport is printed as it is")
  func discoveryError() async {
    let notFound = InspectorError(code: .appNotFound, message: "no serving app matches `Nope`")
    let environment = Environment(transport: { _ in FailingTransport(error: notFound) }, instanceNames: { _ in [] })

    let outcome = await InspectorCLI.outcome(of: ["--app", "Nope", "state"], in: environment)

    #expect(outcome == .stderr(#"{"code":"APP_NOT_FOUND","message":"no serving app matches `Nope`"}"#))
  }

  @Test("any other transport error ends in BAD_REQUEST with the error as detail")
  func unreachableApp() async {
    let environment = Environment(
      transport: { _ in FailingTransport(error: ConnectionRefused()) }, instanceNames: { _ in [] })

    let outcome = await InspectorCLI.outcome(of: ["catalog"], in: environment)

    #expect(
      outcome
        == .stderr(#"{"code":"BAD_REQUEST","detail":"connection refused","message":"could not reach the app"}"#))
  }

  @Test("apps lists every serving app by name, each checked with hello")
  func apps() async throws {
    var environment = try await demoApp()
    let demoHost = environment.transport
    environment.instanceNames = { _ in ["Gone @ Mac", "DemoHost @ Mac"] }
    environment.transport = { app in
      app == "DemoHost @ Mac" ? demoHost(app) : FailingTransport(error: ConnectionRefused())
    }

    let outcome = await InspectorCLI.outcome(of: ["apps"], in: environment)

    let pid = ProcessInfo.processInfo.processIdentifier
    #expect(
      outcome
        == .stdout(
          #"[{"app":"DemoHost","live":true,"name":"DemoHost @ Mac","pid":\#(pid),"provider":"Inspector"},{"live":false,"name":"Gone @ Mac"}]"#
        ))
  }

  @Test("apps fails with BAD_REQUEST when browsing fails")
  func appsBrowseFailure() async {
    let environment = Environment(
      transport: { _ in FailingTransport(error: ConnectionRefused()) },
      instanceNames: { _ in throw ConnectionRefused() })

    let outcome = await InspectorCLI.outcome(of: ["apps"], in: environment)

    #expect(
      outcome
        == .stderr(#"{"code":"BAD_REQUEST","detail":"connection refused","message":"could not browse for apps"}"#))
  }

  @Test(
    "a usage error prints ArgumentParser's error and usage to stderr and exits with 64",
    arguments: [
      [],
      ["nope"],
      ["--app"],
      ["hello", "--app"],
      ["state", "a", "b"],
      ["send"],
      ["send", "counter.set", "1", "2"],
    ])
  func usageError(arguments: [String]) async throws {
    let outcome = await InspectorCLI.outcome(of: arguments, in: try await demoApp())

    #expect(outcome.exitCode == 64)
    #expect(outcome.stdout == "")
    #expect(outcome.stderr.hasPrefix("Error: "))
    #expect(outcome.stderr.contains("Usage: inspector"))
  }

  @Test("--help prints the help to stdout and exits with 0", arguments: [["--help"], ["help"], ["send", "--help"]])
  func help(arguments: [String]) async throws {
    let outcome = await InspectorCLI.outcome(of: arguments, in: try await demoApp())

    #expect(outcome.exitCode == 0)
    #expect(outcome.stdout.contains("USAGE: inspector"))
    #expect(outcome.stderr == "")
  }
}

private struct ConnectionRefused: Error, CustomStringConvertible {
  var description: String { "connection refused" }
}

/// A transport whose every send fails with `error`.
private struct FailingTransport: InspectorTransport {
  var error: any Error

  func serve(_ handle: @escaping @Sendable (Request) async -> Response) async throws {}

  func send(_ request: Request) async throws -> Response {
    throw error
  }
}

extension Outcome {
  /// A successful call that printed `line` and a newline.
  static func stdout(_ line: String) -> Outcome {
    Outcome(stdout: line + "\n", stderr: "", exitCode: 0)
  }

  /// A failed call that printed the error `line` and a newline to stderr and exited with 1.
  static func stderr(_ line: String) -> Outcome {
    Outcome(stdout: "", stderr: line + "\n", exitCode: 1)
  }
}

/// demo-host's registrations, served in-process: a counter that `counter.set` and
/// `counter.increment` change.
private func demoApp() async throws -> Environment {
  let counter = Mutex(0)
  let inspector = Inspector()
  inspector.state("counter") { counter.withLock { $0 } }
  inspector.state("device") { ["name": "Mac", "pid": "1"] }
  inspector.action("counter.increment") { counter.withLock { $0 += 1 } }
  inspector.action("counter.set") { (value: Int) in counter.withLock { $0 = value } }
  let core = InspectorCore(provider: inspector, app: "DemoHost")
  let transport = InMemoryTransport()
  try await transport.serve { await core.handle($0) }
  return Environment(transport: { _ in transport }, instanceNames: { _ in ["DemoHost @ Mac"] })
}
