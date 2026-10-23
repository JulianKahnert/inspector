import Foundation
import Synchronization
import Testing

@testable import InspectorKit
@testable import inspector

@Suite("Gestures")
struct GestureCommandTests {
  private static let config = #"{"session":"inspector-app-1","udid":"UDID-1","workspace":"workspace-1"}"#

  @Test("tap without --until taps the point and prints the gesture")
  func tap() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let xcode = FakeXcode { _ in .text(Self.artifacts) }

      let outcome = await InspectorCLI.outcome(
        of: ["tap", "201", "700.5"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(outcome == .stdout(#"{"gesture":"t 201 700.5"}"#))
      #expect(
        xcode.calls == [
          FakeXcode.Call(
            tool: "DeviceInteractionSynthesize",
            arguments: ["interactSessionKey": "inspector-app-1", "interactionCommand": "t 201 700.5"])
        ])
    }
  }

  @Test("a gesture records itself and the artifacts Xcode wrote after it in run.json")
  func runFile() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      try sandbox.write("app/.inspector/run.json", #"{"lastHierarchy":"/tmp/old-hierarchy.txt","note":"kept"}"#)
      let xcode = FakeXcode { _ in .text(Self.artifacts) }

      _ = await InspectorCLI.outcome(of: ["tap", "1", "2"], in: sandbox.environment(xcode.environment(), in: "app"))

      let run = try sandbox.json("app/.inspector/run.json")
      #expect(run["lastHierarchy"] == "/tmp/g-hierarchy.txt")
      #expect(run["lastScreenshot"] == "/tmp/g-screenshot.png")
      #expect(run["lastStep"]?["arguments"] == .array(["tap", "1", "2"]))
      #expect(run["note"] == "kept")
    }
  }

  @Test("tap with --until answers like send: the state once the condition held, diffed against before the tap")
  func tapUntil() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let (app, xcode) = try await Self.screen()

      let outcome = await InspectorCLI.outcome(
        of: ["tap", "1", "2", "--until", #"{"taps":1}"#], in: sandbox.environment(app, in: "app"))

      #expect(outcome == .stdout(#"{"diff":[{"new":1,"old":0,"path":"taps"}],"settled":true,"state":{"taps":1}}"#))
      #expect(xcode.calls.count == 1)
    }
  }

  @Test("tap with --until that does not hold in time fails with EXPECTATION_FAILED and the last state")
  func tapUntilFails() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let (app, _) = try await Self.screen()

      let outcome = await InspectorCLI.outcome(
        of: ["tap", "1", "2", "--until", #"{"taps":2}"#, "--timeout", "0.05"], in: sandbox.environment(app, in: "app"))

      #expect(
        outcome
          == .stderr(
            #"{"code":"EXPECTATION_FAILED","detail":"{\"taps\":1}","message":"`{\"taps\":2}` did not hold within 50 ms"}"#
          ))
    }
  }

  @Test("tap --target captures, resolves the one target and taps its hit point in the same bridge")
  func tapTarget() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let xcode = try Self.screenOf("meter-detail", in: sandbox)

      let outcome = await InspectorCLI.outcome(
        of: ["tap", "--target", "Stand eintragen"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(
        outcome
          == .stdout(
            #"{"gesture":"t 363.3 84","target":{"hitPoint":[363.3,84],"label":"Stand eintragen","type":"Button"}}"#))
      #expect(
        xcode.calls == [
          FakeXcode.Call(tool: "DeviceInteractionSynthesize", arguments: ["interactSessionKey": "inspector-app-1"]),
          FakeXcode.Call(
            tool: "DeviceInteractionSynthesize",
            arguments: ["interactSessionKey": "inspector-app-1", "interactionCommand": "t 363.3 84"]),
        ])
      #expect(xcode.launched.count == 1)
      #expect(try sandbox.json("app/.inspector/run.json")["lastHierarchy"] == "/tmp/g-hierarchy.txt")
    }
  }

  @Test("tap --target finds a text field by its identifier")
  func tapTargetByIdentifier() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let xcode = try Self.screenOf("meter-detail", in: sandbox)

      let outcome = await InspectorCLI.outcome(
        of: ["tap", "--target", "BackButton"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(outcome.stdout.hasPrefix(#"{"gesture":"t 38 84","target":{"hitPoint":[38,84],"identifier":"BackButton""#))
    }
  }

  @Test(
    "tap --target that resolves to no single target fails with the targets in detail and taps nothing",
    arguments: [("Zähler", "TARGET_AMBIGUOUS"), ("Speichern", "TARGET_NOT_FOUND")])
  func tapTargetUnresolved(name: String, code: String) async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let xcode = try Self.screenOf("meter-detail", in: sandbox)
      let targets = Target.list(inHierarchy: try Self.fixture("meter-detail-hierarchy"))

      let outcome = await InspectorCLI.outcome(
        of: ["tap", "--target", name, "--until", #"{"taps":1}"#], in: sandbox.environment(xcode.environment(), in: "app"))

      var expected: InspectorError?
      do throws(InspectorError) {
        _ = try Target.resolve(name, in: targets)
      } catch {
        expected = error
      }
      #expect(outcome == .stderr(WireJSON.line(try #require(expected))))
      #expect(outcome.stderr.contains(#""code":"\#(code)""#))
      #expect(xcode.calls.count == 1)
    }
  }

  @Test(
    "tap takes either a point or a target, else it is a usage error",
    arguments: [["tap"], ["tap", "1"], ["tap", "1", "2", "--target", "Sichern"], ["tap", "--target"]])
  func tapUsage(arguments: [String]) async throws {
    let outcome = await InspectorCLI.outcome(of: arguments, in: FakeXcode { _ in .silence }.environment())

    #expect(outcome.exitCode == 64)
    #expect(outcome.stderr.contains("Usage: inspector tap"))
  }

  /// Xcode with the screen from the fixture `hierarchy` on it: a capture answers with that
  /// hierarchy, a gesture with ``artifacts``.
  private static func screenOf(_ hierarchy: String, in sandbox: Sandbox) throws -> FakeXcode {
    try sandbox.write("artifacts/c-hierarchy.txt", try fixture("\(hierarchy)-hierarchy"))
    let path = sandbox.url("artifacts/c-hierarchy.txt").path.replacing("/", with: #"\/"#)
    return FakeXcode { call in
      guard call.arguments["interactionCommand"] == nil else { return .text(Self.artifacts) }
      return .text(#"{"applicationState":"Running","hierarchyPath":"\#(path)","screenshotPath":"\/tmp\/c.png"}"#)
    }
  }

  private static func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// An app whose state counts the gestures Xcode synthesized, and that Xcode.
  private static func screen() async throws -> (Environment, FakeXcode) {
    let taps = Mutex(0)
    let xcode = FakeXcode { call in
      if call.arguments["interactionCommand"] != nil { taps.withLock { $0 += 1 } }
      return .text(Self.artifacts)
    }
    let inspector = Inspector()
    inspector.state("taps") { taps.withLock { $0 } }
    let core = InspectorCore(provider: inspector, app: "Screen")
    let transport = InMemoryTransport()
    try await transport.serve { await core.handle($0) }
    return (xcode.environment(serving: Environment(transport: { _ in transport }, instanceNames: { _ in [] })), xcode)
  }

  /// What `DeviceInteractionSynthesize` answers after a gesture.
  private static let artifacts = #"""
    {"applicationState":"Running","hierarchyPath":"\/tmp\/g-hierarchy.txt","logsPath":"\/tmp\/g-logs.txt",\#
    "screenshotPath":"\/tmp\/g-screenshot.png","thumbnailScreenshotPath":"\/tmp\/g-thumbnailScreenshot.png"}
    """#
}
