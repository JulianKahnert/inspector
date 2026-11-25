import Foundation
import Synchronization
import Testing

@testable import InspectorKit
@testable import inspector

@Suite("session")
struct SessionCommandTests {
  private static let config = #"{"instance":"DemoHost @ Mac","session":"old","udid":"UDID-1"}"#

  @Test("session starts a device session on the udid without asking the app and writes it to config.json")
  func startsSession() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let lockDuringStart = Mutex<String?>(nil)
      let xcode = FakeXcode { _ in
        lockDuringStart.withLock { $0 = sandbox.read("app/.inspector/session.lock") }
        return .text(#"{"userMessage":"Session started"}"#)
      }
      // No app serves: the command must not need one.
      let outcome = await InspectorCLI.outcome(of: ["session"], in: sandbox.environment(xcode.environment(), in: "app"))

      let answer = try JSONDecoder().decode(JSONValue.self, from: Data(outcome.stdout.utf8))
      #expect(outcome.exitCode == 0)
      #expect(answer["session"] == "inspector-app-20261019-085320-250")
      #expect(answer["startedMs"]?.intValue != nil)
      #expect(
        xcode.calls == [
          FakeXcode.Call(
            tool: "DeviceInteractionStartSession",
            arguments: ["deviceIdentifier": "UDID-1", "sessionIdentifier": "inspector-app-20261019-085320-250"])
        ])
      #expect(lockDuringStart.withLock { $0 } == "\(ProcessInfo.processInfo.processIdentifier)\n")
      #expect(sandbox.read("app/.inspector/session.lock") == nil)
      let written = try sandbox.json("app/.inspector/config.json")
      #expect(written["session"] == "inspector-app-20261019-085320-250")
      #expect(written["instance"] == "DemoHost @ Mac")
    }
  }

  @Test("session releases the lock when Xcode refuses the start, and leaves config.json alone")
  func failedStart() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let xcode = FakeXcode { _ in .error("Device is in use by another session") }

      let outcome = await InspectorCLI.outcome(of: ["session"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(outcome.stderr.contains(#""code":"XCODE_ERROR""#))
      #expect(sandbox.read("app/.inspector/session.lock") == nil)
      #expect(sandbox.read("app/.inspector/config.json") == Self.config)
    }
  }

  @Test("session without a udid in config.json fails with NO_CONFIG and starts no bridge")
  func noDevice() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", #"{"session":"old"}"#)
      let xcode = FakeXcode { _ in .text("ok") }

      let outcome = await InspectorCLI.outcome(of: ["session"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(outcome.stderr.contains(#""code":"NO_CONFIG""#))
      #expect(xcode.launched.isEmpty)
    }
  }

  @Test("session that waited for another live start answers with the session that one wrote")
  func adoptsConcurrentStart() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      try sandbox.write("app/.inspector/session.lock", "4242\n")
      let xcode = FakeXcode { _ in .text("ok") }
      var environment = sandbox.environment(xcode.environment(), in: "app")
      environment.processIsAlive = { _ in true }
      Task {
        try? await Task.sleep(for: .milliseconds(100))
        try? sandbox.write("app/.inspector/config.json", Self.config.replacing(#""old""#, with: #""other""#))
        try? FileManager.default.removeItem(at: sandbox.url("app/.inspector/session.lock"))
      }

      let outcome = await InspectorCLI.outcome(of: ["session"], in: environment)

      #expect(outcome.stdout.contains(#""session":"other""#))
      #expect(xcode.launched.isEmpty)
    }
  }
}
