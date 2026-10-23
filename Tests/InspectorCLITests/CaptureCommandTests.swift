import Foundation
import Testing

@testable import InspectorKit
@testable import inspector

@Suite("capture")
struct CaptureCommandTests {
  private static let config = #"{"session":"inspector-app-1","udid":"UDID-1","workspace":"workspace-1"}"#

  @Test("capture prints the artifacts' paths and the targets, and remembers the paths in run.json")
  func capture() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      try sandbox.write("artifacts/s-hierarchy.txt", try Self.fixture("enter-reading-hierarchy"))
      let hierarchy = sandbox.url("artifacts/s-hierarchy.txt").path
      let screenshot = sandbox.url("artifacts/s-screenshot.png").path
      let xcode = FakeXcode { _ in .text(Self.artifacts(hierarchy: hierarchy, screenshot: screenshot)) }

      let outcome = await InspectorCLI.outcome(of: ["capture"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(
        outcome
          == .stdout(
            #"{"hierarchy":"\#(hierarchy)","screenshot":"\#(screenshot)","targets":[{"hitPoint":[73.8,100],"label":"Abbrechen","type":"Button"},{"hitPoint":[339.5,100],"label":"Sichern","type":"Button"},{"hitPoint":[206.2,193],"placeholder":"0","type":"TextField","value":"2100000"},{"hitPoint":[278.3,252],"label":"Datums- und Uhrzeitauswahl","type":"Button","value":"21:59, 22.10.2026"},{"hitPoint":[241.3,252],"label":"22.10.2026","type":"Button"},{"hitPoint":[335,252],"label":"21:59","type":"Button"}]}"#
          ))
      #expect(
        xcode.calls == [
          FakeXcode.Call(tool: "DeviceInteractionSynthesize", arguments: ["interactSessionKey": "inspector-app-1"])
        ])
      let run = try sandbox.json("app/.inspector/run.json")
      #expect(run["lastHierarchy"] == .string(hierarchy))
      #expect(run["lastScreenshot"] == .string(screenshot))
      #expect(run["lastStep"]?["command"] == "capture")
    }
  }

  @Test(
    "a capture without a readable hierarchy fails with NO_HIERARCHY and Xcode's answer in detail",
    arguments: [
      #"{"applicationState":"Running","screenshotPath":"\/tmp\/s-screenshot.png"}"#,
      #"{"applicationState":"Running","hierarchyPath":""}"#,
      #"{"applicationState":"Running","hierarchyPath":"\/nonexistent-inspector-test\/s-hierarchy.txt"}"#,
    ])
  func noHierarchy(answer: String) async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let xcode = FakeXcode { _ in .text(answer) }

      let outcome = await InspectorCLI.outcome(of: ["capture"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(
        outcome
          == .stderr(
            WireJSON.line(
              InspectorError(
                code: .noHierarchy, message: "the capture has no hierarchy; capture again, else read the screenshot",
                detail: answer))))
      #expect(try sandbox.json("app/.inspector/run.json")["lastHierarchy"] == nil)
    }
  }

  @Test("an empty hierarchy file is no hierarchy")
  func emptyHierarchy() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      try sandbox.write("artifacts/s-hierarchy.txt", "")
      let answer = Self.artifacts(hierarchy: sandbox.url("artifacts/s-hierarchy.txt").path, screenshot: "/tmp/s.png")
      let xcode = FakeXcode { _ in .text(answer) }

      let outcome = await InspectorCLI.outcome(of: ["capture"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(outcome.stderr.contains(#""code":"NO_HIERARCHY""#))
    }
  }

  @Test("a session that ended with its app fails with NO_SESSION and starts no new one")
  func deadSession() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let notFound = #"{"data":"Session not found. It may have already been closed, or the identifier is wrong","type":"error"}"#
      let xcode = FakeXcode { _ in .error(notFound) }

      let outcome = await InspectorCLI.outcome(of: ["capture"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(
        outcome
          == .stderr(
            WireJSON.line(
              InspectorError(
                code: .noSession,
                message: "the session `inspector-app-1` has ended and the app with it; run `inspector init`",
                detail: notFound))))
      #expect(xcode.calls.map(\.tool) == ["DeviceInteractionSynthesize"])
    }
  }

  @Test("a binary Xcode has not approved fails with NOT_APPROVED")
  func notApproved() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let xcode = FakeXcode { _ in .error("This agent isn't approved to use Xcode's tools yet.") }

      let outcome = await InspectorCLI.outcome(of: ["capture"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(outcome.stderr.contains(#""code":"NOT_APPROVED""#))
      #expect(outcome.exitCode == 1)
    }
  }

  @Test("capture without .inspector/ fails with NO_CONFIG and never starts a bridge")
  func noFolder() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      let xcode = FakeXcode { _ in .silence }

      let outcome = await InspectorCLI.outcome(of: ["capture"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(outcome.stderr.contains(#""code":"NO_CONFIG""#))
      #expect(xcode.launched.isEmpty)
    }
  }

  /// What `DeviceInteractionSynthesize` answers, with its slashes escaped as Xcode writes them.
  private static func artifacts(hierarchy: String, screenshot: String) -> String {
    let hierarchy = hierarchy.replacing("/", with: #"\/"#)
    let screenshot = screenshot.replacing("/", with: #"\/"#)
    return """
      {"applicationState":"Running","hierarchyPath":"\(hierarchy)","logsPath":"\\/tmp\\/s-logs.txt",\
      "screenshotPath":"\(screenshot)","thumbnailScreenshotPath":"\\/tmp\\/s-thumbnailScreenshot.png"}
      """
  }

  private static func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
  }
}
