import Foundation
import Synchronization
import Testing

@testable import InspectorKit
@testable import inspector

@Suite("Device session")
struct DeviceSessionTests {
  // What `DeviceInteractionSynthesize` answers, with `isError`, for a session Xcode does not know.
  private static let notFound =
    #"{"data":"Session not found. It may have already been closed, or the identifier is wrong","type":"error"}"#
  private static let config = """
    {"instance":"DemoHost @ Mac","session":"inspector-app-1","udid":"UDID-1","workspace":"workspace-1"}
    """

  @Test(
    "each tool gets the session's name under the parameter it spells",
    arguments: [
      (SessionTool.synthesize, "interactSessionKey"),
      (.installAndRun, "interactionSessionKey"),
      (.endSession, "interactionSessionKey"),
    ])
  func sessionParameter(tool: SessionTool, parameter: String) async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let xcode = FakeXcode { _ in .text("ok") }
      let environment = sandbox.environment(xcode.environment(), in: "app")

      var session = try DeviceSession(in: environment)
      _ = try await environment.withXcode { xcode throws(InspectorError) in
        try await session.call(tool, ["interactionCommand": "t 1 2"], on: xcode, in: environment)
      }

      #expect(
        xcode.calls == [
          FakeXcode.Call(
            tool: tool.rawValue, arguments: [parameter: "inspector-app-1", "interactionCommand": "t 1 2"])
        ])
    }
  }

  @Test("a session Xcode no longer knows, with the app still serving, is replaced and the call runs once more")
  func restart() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let synthesizeCalls = Mutex(0)
      let xcode = FakeXcode { call in
        guard call.tool == "DeviceInteractionSynthesize" else { return .text("Session started") }
        let first = synthesizeCalls.withLock {
          $0 += 1
          return $0 == 1
        }
        return first ? .error(Self.notFound) : .text("captured")
      }
      let environment = sandbox.environment(xcode.environment(serving: try await demoApp()), in: "app")

      var session = try DeviceSession(in: environment)
      let result = try await environment.withXcode { xcode throws(InspectorError) in
        try await session.call(.synthesize, on: xcode, in: environment)
      }

      #expect(result.text == "captured")
      #expect(
        xcode.calls == [
          FakeXcode.Call(tool: "DeviceInteractionSynthesize", arguments: ["interactSessionKey": "inspector-app-1"]),
          FakeXcode.Call(
            tool: "DeviceInteractionStartWorkspaceSession",
            arguments: [
              "sessionIdentifier": "inspector-app-20261019-085320", "workspaceIdentifier": "workspace-1",
              "deviceIdentifier": "UDID-1",
            ]),
          FakeXcode.Call(
            tool: "DeviceInteractionSynthesize", arguments: ["interactSessionKey": "inspector-app-20261019-085320"]),
        ])
      #expect(
        try sandbox.json("app/.inspector/config.json")
          == .object([
            "instance": "DemoHost @ Mac", "session": "inspector-app-20261019-085320", "udid": "UDID-1",
            "workspace": "workspace-1", "writtenAt": "2026-10-19T08:53:20Z",
          ]))
    }
  }

  @Test("a session that ended with its app fails with NO_SESSION; no new session, config.json untouched")
  func deadApp() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let xcode = FakeXcode { _ in .error(Self.notFound) }
      let environment = sandbox.environment(xcode.environment(), in: "app")

      var session = try DeviceSession(in: environment)
      let error = await #expect(throws: InspectorError.self) {
        try await environment.withXcode { xcode throws(InspectorError) in
          try await session.call(.synthesize, on: xcode, in: environment)
        }
      }

      #expect(
        error
          == InspectorError(
            code: .noSession, message: "the session `inspector-app-1` has ended and the app with it; run `inspector init`",
            detail: Self.notFound))
      #expect(xcode.calls.map(\.tool) == ["DeviceInteractionSynthesize"])
      #expect(sandbox.read("app/.inspector/config.json") == Self.config)
    }
  }

  @Test("the call runs at most once more: a new session Xcode does not know either ends in NO_SESSION")
  func oneRetry() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let xcode = FakeXcode { call in
        call.tool == "DeviceInteractionSynthesize" ? .error(Self.notFound) : .text("Session started")
      }
      let environment = sandbox.environment(xcode.environment(serving: try await demoApp()), in: "app")

      var session = try DeviceSession(in: environment)
      let error = await #expect(throws: InspectorError.self) {
        try await environment.withXcode { xcode throws(InspectorError) in
          try await session.call(.synthesize, on: xcode, in: environment)
        }
      }

      #expect(error?.code == .noSession)
      #expect(
        xcode.calls.map(\.tool)
          == ["DeviceInteractionSynthesize", "DeviceInteractionStartWorkspaceSession", "DeviceInteractionSynthesize"])
    }
  }

  @Test("a config.json without workspace or device cannot start a session: NO_SESSION, even with the app serving")
  func restartWithoutWorkspace() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", #"{"instance":"DemoHost @ Mac","session":"inspector-app-1"}"#)
      let xcode = FakeXcode { _ in .error(Self.notFound) }
      let environment = sandbox.environment(xcode.environment(serving: try await demoApp()), in: "app")

      var session = try DeviceSession(in: environment)
      let error = await #expect(throws: InspectorError.self) {
        try await environment.withXcode { xcode throws(InspectorError) in
          try await session.call(.synthesize, on: xcode, in: environment)
        }
      }

      #expect(error?.code == .noSession)
      #expect(xcode.calls.map(\.tool) == ["DeviceInteractionSynthesize"])
    }
  }

  @Test("NOT_APPROVED is never answered with a new session")
  func notApprovedIsNoSessionLoss() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let xcode = FakeXcode { _ in .error("This agent isn't approved to use Xcode's tools yet.") }
      let environment = sandbox.environment(xcode.environment(serving: try await demoApp()), in: "app")

      var session = try DeviceSession(in: environment)
      let error = await #expect(throws: InspectorError.self) {
        try await environment.withXcode { xcode throws(InspectorError) in
          try await session.call(.synthesize, on: xcode, in: environment)
        }
      }

      #expect(error?.code == .notApproved)
      #expect(xcode.calls.count == 1)
    }
  }
}
