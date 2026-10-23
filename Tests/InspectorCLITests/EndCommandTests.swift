import Foundation
import Testing

@testable import InspectorKit
@testable import inspector

@Suite("end")
struct EndCommandTests {
  @Test("end stops the session config.json names and leaves config.json alone")
  func endsSession() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      let config = #"{"session":"inspector-app-20261023-101500","udid":"UDID-1"}"#
      try sandbox.write("app/.inspector/config.json", config)
      let xcode = FakeXcode { _ in .text("Session stopped") }

      let outcome = await InspectorCLI.outcome(of: ["end"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(outcome == .stdout(#"{"message":"Session stopped","session":"inspector-app-20261023-101500"}"#))
      #expect(
        xcode.calls == [
          FakeXcode.Call(
            tool: "DeviceInteractionEndSession", arguments: ["interactionSessionKey": "inspector-app-20261023-101500"])
        ])
      #expect(sandbox.read("app/.inspector/config.json") == config)
    }
  }

  @Test("end on a session that already ended relays Xcode's error and starts no new one")
  func expiredSession() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", #"{"session":"old","udid":"UDID-1","workspace":"w1"}"#)
      let xcode = FakeXcode { _ in .error("Session doesn't exist anymore") }

      let outcome = await InspectorCLI.outcome(of: ["end"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(
        outcome
          == .stderr(
            #"{"code":"XCODE_ERROR","detail":"Session doesn't exist anymore","message":"`DeviceInteractionEndSession` failed: Session doesn't exist anymore"}"#
          ))
      #expect(xcode.calls.map(\.tool) == ["DeviceInteractionEndSession"])
    }
  }

  @Test("end without .inspector/ fails with NO_CONFIG and never starts a bridge")
  func noFolder() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      let xcode = FakeXcode { _ in .text("Session stopped") }

      let outcome = await InspectorCLI.outcome(of: ["end"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(
        outcome
          == .stderr(
            #"{"code":"NO_CONFIG","detail":"\#(sandbox.url("app/.inspector").path)","message":"no `.inspector/` folder; run `inspector init`"}"#
          ))
      #expect(xcode.launched.isEmpty)
    }
  }

  @Test("end with a config.json without a session fails with NO_SESSION")
  func noSessionInConfig() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", #"{"instance":"RoommateAlbert @ iPhone 17"}"#)
      let xcode = FakeXcode { _ in .text("Session stopped") }

      let outcome = await InspectorCLI.outcome(of: ["end"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(
        outcome
          == .stderr(
            #"{"code":"NO_SESSION","detail":"\#(sandbox.url("app/.inspector/config.json").path)","message":"no session in `config.json`; run `inspector init`"}"#
          ))
      #expect(xcode.launched.isEmpty)
    }
  }

  @Test("end's help says the app ends with the session")
  func help() async throws {
    let outcome = await InspectorCLI.outcome(of: ["end", "--help"], in: FakeXcode { _ in .silence }.environment())

    #expect(outcome.exitCode == 0)
    #expect(outcome.stdout.contains("The app the session started ends with it."))
  }
}
