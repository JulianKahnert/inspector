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
      try sandbox.write(
        "app/.inspector/run.json",
        #"{"lastHierarchy":"/tmp/old-hierarchy.txt","lastScreenshotFull":"/tmp/old-screenshot.png","note":"kept"}"#)
      let xcode = FakeXcode { _ in .text(Self.artifacts) }

      _ = await InspectorCLI.outcome(of: ["tap", "1", "2"], in: sandbox.environment(xcode.environment(), in: "app"))

      let run = try sandbox.json("app/.inspector/run.json")
      #expect(run["lastHierarchy"] == "/tmp/g-hierarchy.txt")
      #expect(run["lastScreenshot"] == "/tmp/g-screenshot.png")
      #expect(run["lastScreenshotFull"] == nil)
      #expect(run["lastStep"]?["arguments"] == .array(["tap", "1", "2"]))
      #expect(run["note"] == "kept")
    }
  }

  @Test("a gesture records the small copy of a large screenshot as lastScreenshot, the original as lastScreenshotFull")
  func smallCopy() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let screenshot = sandbox.url("g-screenshot.png").path
      try TestImage.writePNG(width: 2622, height: 1206, to: URL(filePath: screenshot))
      let escaped = screenshot.replacing("/", with: #"\/"#)
      let xcode = FakeXcode { _ in .text(#"{"applicationState":"Running","screenshotPath":"\#(escaped)"}"#) }

      _ = await InspectorCLI.outcome(of: ["tap", "1", "2"], in: sandbox.environment(xcode.environment(), in: "app"))

      let small = sandbox.url("g-screenshot-small.png").path
      let run = try sandbox.json("app/.inspector/run.json")
      #expect(run["lastScreenshot"] == .string(small))
      #expect(run["lastScreenshotFull"] == .string(screenshot))
      #expect(TestImage.size(at: small)?.max() == 1000)
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

  @Test(
    "swipe drags from the first point to the second, over the duration when one is given",
    arguments: [
      (["swipe", "201", "110", "201", "820", "0.3"], "t 201 110 f 201 820 0.3"),
      (["swipe", "201.5", "700", "201.5", "250"], "t 201.5 700 f 201.5 250"),
    ])
  func swipe(arguments: [String], command: String) async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let xcode = FakeXcode { _ in .text(Self.artifacts) }

      let outcome = await InspectorCLI.outcome(of: arguments, in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(outcome == .stdout(#"{"gesture":"\#(command)"}"#))
      #expect(xcode.calls.map { $0.arguments["interactionCommand"] } == [.string(command)])
    }
  }

  @Test("swipe with --until answers like send")
  func swipeUntil() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let (app, _) = try await Self.screen()

      let outcome = await InspectorCLI.outcome(
        of: ["swipe", "201", "110", "201", "820", "--until", #"{"taps":1}"#, "--timeout", "1"],
        in: sandbox.environment(app, in: "app"))

      #expect(outcome == .stdout(#"{"diff":[{"new":1,"old":0,"path":"taps"}],"settled":true,"state":{"taps":1}}"#))
    }
  }

  @Test(
    "swipe takes two points and an optional positive duration, else it is a usage error",
    arguments: [
      ["swipe", "1", "2", "3"], ["swipe", "1", "2", "3", "4", "0"], ["swipe", "1", "2", "3", "4", "-1"],
      ["swipe", "1", "2", "3", "4", "0.3", "5"],
    ])
  func swipeUsage(arguments: [String]) async throws {
    let outcome = await InspectorCLI.outcome(of: arguments, in: FakeXcode { _ in .silence }.environment())

    #expect(outcome.exitCode == 64)
    #expect(outcome.stderr.contains("Usage: inspector swipe"))
  }

  @Test(
    "type types the text into the focused field, also text that starts with a dash",
    arguments: [
      (["type", "2100000"], "sender keyboard kbd 2100000"),
      (["type", "-5"], "sender keyboard kbd -5"),
      (["type", "team was here"], "sender keyboard kbd team was here"),
    ])
  func type(arguments: [String], command: String) async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let xcode = FakeXcode { _ in .text(Self.artifacts) }

      let outcome = await InspectorCLI.outcome(of: arguments, in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(outcome == .stdout(#"{"gesture":"\#(command)"}"#))
      #expect(xcode.calls.map { $0.arguments["interactionCommand"] } == [.string(command)])
    }
  }

  @Test("type fills ${NAME} from .env for Xcode and masks the value in its answer and in run.json")
  func typeSecret() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      try sandbox.write("app/.inspector/.env", "SECRET=s3cr3t-value\n")
      let xcode = FakeXcode { _ in .text(Self.artifacts) }

      let outcome = await InspectorCLI.outcome(
        of: ["type", "${SECRET}"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(outcome == .stdout(#"{"gesture":"sender keyboard kbd ${SECRET}"}"#))
      #expect(xcode.calls.map { $0.arguments["interactionCommand"] } == ["sender keyboard kbd s3cr3t-value"])
      #expect(sandbox.read("app/.inspector/run.json")?.contains("s3cr3t-value") == false)
    }
  }

  @Test("type with a placeholder .env lacks fails with ENV_MISSING before Xcode is reached")
  func typeMissingValue() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let xcode = FakeXcode { _ in .text(Self.artifacts) }

      let outcome = await InspectorCLI.outcome(
        of: ["type", "${SECRET}"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(outcome.stderr.contains(#""code":"ENV_MISSING""#))
      #expect(xcode.launched.isEmpty)
    }
  }

  @Test("type with --until answers like send")
  func typeUntil() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let (app, _) = try await Self.screen()

      let outcome = await InspectorCLI.outcome(
        of: ["type", "42", "--until", #"{"taps":1}"#], in: sandbox.environment(app, in: "app"))

      #expect(outcome == .stdout(#"{"diff":[{"new":1,"old":0,"path":"taps"}],"settled":true,"state":{"taps":1}}"#))
    }
  }

  @Test("type takes exactly one text, else it is a usage error", arguments: [["type"], ["type", "a", "b"]])
  func typeUsage(arguments: [String]) async throws {
    let outcome = await InspectorCLI.outcome(of: arguments, in: FakeXcode { _ in .silence }.environment())

    #expect(outcome.exitCode == 64)
    #expect(outcome.stderr.contains("Usage: inspector type"))
  }

  @Test(
    "a gesture without .inspector/ fails with NO_CONFIG and starts no bridge",
    arguments: [["tap", "1", "2"], ["tap", "--target", "Sichern"], ["swipe", "1", "2", "3", "4"], ["type", "x"]])
  func noFolder(arguments: [String]) async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      let (app, xcode) = try await Self.screen()

      let outcome = await InspectorCLI.outcome(
        of: arguments + ["--until", #"{"taps":1}"#], in: sandbox.environment(app, in: "app"))

      #expect(outcome.stderr.contains(#""code":"NO_CONFIG""#))
      #expect(xcode.launched.isEmpty)
    }
  }

  @Test("a gesture whose session ended with its app fails with NO_SESSION and taps nothing")
  func deadSession() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let notFound = #"{"data":"Session not found. It may have already been closed, or the identifier is wrong","type":"error"}"#
      let xcode = FakeXcode { _ in .error(notFound) }

      let outcome = await InspectorCLI.outcome(
        of: ["tap", "1", "2"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(outcome.stderr.contains(#""code":"NO_SESSION""#))
      #expect(xcode.calls.map(\.tool) == ["DeviceInteractionSynthesize"])
    }
  }

  @Test(
    "a gesture with --until whose app died fails with NO_SESSION and taps nothing",
    arguments: [ErrorCode.appNotFound, .timeout])
  func deadAppUntil(code: ErrorCode) async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let xcode = FakeXcode { _ in .text(Self.artifacts) }
      var environment = xcode.environment()
      // A terminated app leaves a Bonjour record behind for a while, which answers TIMEOUT.
      environment.transport = { _ in FailingApp(error: InspectorError(code: code, message: "gone")) }

      let outcome = await InspectorCLI.outcome(
        of: ["tap", "1", "2", "--until", #"{"taps":1}"#], in: sandbox.environment(environment, in: "app"))

      #expect(
        outcome
          == .stderr(
            #"{"code":"NO_SESSION","detail":"gone","message":"the app of the session `inspector-app-1` does not answer; run `inspector init`"}"#
          ))
      #expect(xcode.calls.isEmpty)
    }
  }

  @Test("--targets adds the targets of the hierarchy Xcode captured after the gesture", arguments: [
    ["tap", "1", "2", "--targets"], ["swipe", "1", "2", "3", "4", "--targets"], ["type", "42", "--targets"],
  ])
  func targetsAfterGesture(arguments: [String]) async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let xcode = try Self.afterGesture("meter-detail", in: sandbox)
      let targets = Target.list(inHierarchy: try Self.fixture("meter-detail-hierarchy"))

      let outcome = await InspectorCLI.outcome(of: arguments, in: sandbox.environment(xcode.environment(), in: "app"))

      let answer = try JSONDecoder().decode(JSONValue.self, from: Data(outcome.stdout.utf8))
      #expect(answer["gesture"] != nil)
      #expect(WireJSON.line(try #require(answer["targets"])) == WireJSON.line(targets))
      #expect(!targets.isEmpty)
    }
  }

  @Test("--targets with --until is the wait's answer with targets beside its fields")
  func targetsUntil() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let (app, _) = try await Self.screen(hierarchy: try Self.hierarchyFile("enter-reading", in: sandbox))
      let targets = Target.list(inHierarchy: try Self.fixture("enter-reading-hierarchy"))

      let outcome = await InspectorCLI.outcome(
        of: ["tap", "1", "2", "--targets", "--until", #"{"taps":1}"#], in: sandbox.environment(app, in: "app"))

      #expect(
        outcome
          == .stdout(
            #"{"diff":[{"new":1,"old":0,"path":"taps"}],"settled":true,"state":{"taps":1},"targets":\#(WireJSON.line(targets))}"#
          ))
    }
  }

  @Test("an answer with targets encodes them as one more field of the answer's object")
  func withTargetsEncoding() {
    let target = Target(type: "Button", label: "Sichern", hitPoint: Point(x: 1, y: 2))

    #expect(
      WireJSON.line(Gesture.WithTargets(answer: Gesture.Performed(gesture: "t 1 2"), targets: [target]))
        == #"{"gesture":"t 1 2","targets":[{"hitPoint":[1,2],"label":"Sichern","type":"Button"}]}"#)
    #expect(
      WireJSON.line(Gesture.WithTargets(answer: Gesture.Performed(gesture: "t 1 2"), targets: nil))
        == #"{"gesture":"t 1 2"}"#)
  }

  @Test("tap --target --find captures again until the target appears, then taps it")
  func findTarget() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let before = try Self.hierarchyFile("meter-detail", in: sandbox)
      let after = try Self.hierarchyFile("enter-reading", in: sandbox)
      let captures = Mutex(0)
      let xcode = FakeXcode { call in
        guard call.arguments["interactionCommand"] == nil else { return .text(Self.artifacts) }
        let count = captures.withLock {
          $0 += 1
          return $0
        }
        return .text(Self.capture(hierarchy: count < 3 ? before : after))
      }

      let outcome = await InspectorCLI.outcome(
        of: ["tap", "--target", "Sichern", "--find", "5"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(outcome.stdout.hasPrefix(#"{"gesture":"t 339.5 100","target":"#))
      #expect(captures.withLock { $0 } == 3)
      #expect(xcode.calls.last?.arguments["interactionCommand"] == "t 339.5 100")
    }
  }

  @Test("tap --target --find fails with TARGET_NOT_FOUND once the seconds are over, having tapped nothing")
  func findTargetTimesOut() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let xcode = try Self.screenOf("meter-detail", in: sandbox)

      let outcome = await InspectorCLI.outcome(
        of: ["tap", "--target", "Sichern", "--find", "0.4"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(outcome.stderr.contains(#""code":"TARGET_NOT_FOUND""#))
      #expect(xcode.calls.count >= 2)
      #expect(xcode.calls.allSatisfy { $0.arguments["interactionCommand"] == nil })
    }
  }

  @Test(
    "--find needs --target and a positive number of seconds, else it is a usage error",
    arguments: [
      ["tap", "1", "2", "--find", "1"], ["tap", "--target", "Sichern", "--find", "0"],
      ["tap", "--target", "Sichern", "--find", "-1"], ["tap", "--target", "Sichern", "--find", "nan"],
    ])
  func findUsage(arguments: [String]) async throws {
    let outcome = await InspectorCLI.outcome(of: arguments, in: FakeXcode { _ in .silence }.environment())

    #expect(outcome.exitCode == 64)
  }

  @Test("with the early answer, a gesture answers once the condition held, without waiting for Xcode")
  func earlyAnswer() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      // Xcode takes the touch but never answers, as if it were still capturing.
      let (app, xcode) = try await Self.screen(answer: .silence)
      var environment = sandbox.environment(app, in: "app")
      environment.earlyAnswer = EarlyAnswer(minimum: .milliseconds(20))
      let clock = ContinuousClock()
      let start = clock.now

      let outcome = await InspectorCLI.outcome(
        of: ["tap", "1", "2", "--targets", "--until", #"{"taps":1}"#], in: environment)

      #expect(outcome == .stdout(#"{"diff":[{"new":1,"old":0,"path":"taps"}],"settled":true,"state":{"taps":1}}"#))
      #expect(clock.now - start < .seconds(5))
      #expect(xcode.calls.count == 1)
      #expect(try sandbox.json("app/.inspector/run.json")["lastHierarchy"] == nil)
    }
  }

  @Test("with the early answer, Xcode's error still wins when it comes first")
  func earlyAnswerXcodeFails() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let (app, _) = try await Self.screen(answer: .error("synthesis failed"))
      var environment = sandbox.environment(app, in: "app")
      environment.earlyAnswer = EarlyAnswer(minimum: .zero)

      let outcome = await InspectorCLI.outcome(
        of: ["tap", "1", "2", "--until", #"{"taps":5}"#, "--timeout", "2"], in: environment)

      #expect(outcome.stderr.contains(#""code":"XCODE_ERROR""#))
    }
  }

  @Test("with the early answer, Xcode answering first gives today's answer, targets included")
  func earlyAnswerXcodeFirst() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let (app, _) = try await Self.screen(hierarchy: try Self.hierarchyFile("enter-reading", in: sandbox))
      var environment = sandbox.environment(app, in: "app")
      environment.earlyAnswer = EarlyAnswer(minimum: .seconds(2))

      let outcome = await InspectorCLI.outcome(
        of: ["tap", "1", "2", "--targets", "--until", #"{"taps":1}"#], in: environment)

      #expect(outcome.stdout.hasPrefix(#"{"diff":[{"new":1,"old":0,"path":"taps"}],"settled":true,"state":{"taps":1},"targets":["#))
      #expect(try sandbox.json("app/.inspector/run.json")["lastHierarchy"] != nil)
    }
  }

  @Test(
    "INSPECTOR_EARLY=1 turns the early answer on, INSPECTOR_EARLY_MIN_MS sets its minimum, 350 ms by default",
    arguments: [
      ([:], nil),
      (["INSPECTOR_EARLY": "0"], nil),
      (["INSPECTOR_EARLY_MIN_MS": "10"], nil),
      (["INSPECTOR_EARLY": "1"], EarlyAnswer(minimum: .milliseconds(350))),
      (["INSPECTOR_EARLY": "1", "INSPECTOR_EARLY_MIN_MS": "120"], EarlyAnswer(minimum: .milliseconds(120))),
      (["INSPECTOR_EARLY": "1", "INSPECTOR_EARLY_MIN_MS": "0"], EarlyAnswer(minimum: .zero)),
      (["INSPECTOR_EARLY": "1", "INSPECTOR_EARLY_MIN_MS": "-5"], EarlyAnswer(minimum: .milliseconds(350))),
      (["INSPECTOR_EARLY": "1", "INSPECTOR_EARLY_MIN_MS": "soon"], EarlyAnswer(minimum: .milliseconds(350))),
    ] as [([String: String], EarlyAnswer?)])
  func earlyAnswerVariables(variables: [String: String], expected: EarlyAnswer?) {
    #expect(EarlyAnswer(variables: variables) == expected)
  }

  /// The fixture `hierarchy`, written into the sandbox; its path.
  private static func hierarchyFile(_ hierarchy: String, in sandbox: Sandbox) throws -> String {
    try sandbox.write("artifacts/\(hierarchy)-hierarchy.txt", try fixture("\(hierarchy)-hierarchy"))
    return sandbox.url("artifacts/\(hierarchy)-hierarchy.txt").path
  }

  /// What a capture answers with the hierarchy file at `path`.
  private static func capture(hierarchy path: String) -> String {
    let escaped = path.replacing("/", with: #"\/"#)
    return #"{"applicationState":"Running","hierarchyPath":"\#(escaped)","screenshotPath":"\/tmp\/c.png"}"#
  }

  /// Xcode whose every call answers with the fixture `hierarchy` as the screen afterwards.
  private static func afterGesture(_ hierarchy: String, in sandbox: Sandbox) throws -> FakeXcode {
    let answer = capture(hierarchy: try hierarchyFile(hierarchy, in: sandbox))
    return FakeXcode { _ in .text(answer) }
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

  /// An app whose state counts the gestures Xcode synthesized, and that Xcode, which answers a
  /// gesture with `answer`, by default the artifacts with the hierarchy file at `hierarchy`.
  private static func screen(
    hierarchy: String? = nil, answer: FakeXcode.Reply? = nil
  ) async throws -> (Environment, FakeXcode) {
    let taps = Mutex(0)
    let reply = answer ?? .text(hierarchy.map { capture(hierarchy: $0) } ?? Self.artifacts)
    let xcode = FakeXcode { call in
      if call.arguments["interactionCommand"] != nil { taps.withLock { $0 += 1 } }
      return reply
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

/// An app that fails every request with `error`.
private struct FailingApp: InspectorTransport {
  let error: InspectorError

  func serve(_ handle: @escaping @Sendable (Request) async -> Response) async throws {}

  func send(_ request: Request) async throws -> Response {
    throw error
  }
}
