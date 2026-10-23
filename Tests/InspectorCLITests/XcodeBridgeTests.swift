import Foundation
import Testing

@testable import InspectorKit
@testable import inspector

@Suite("Xcode bridge")
struct XcodeBridgeTests {
  @Test("a tool call is one exchange: initialize, initialized, the call, then stdin closes")
  func oneExchange() async throws {
    let xcode = FakeXcode { _ in .text("Session stopped") }

    let result = try await XcodeBridge.connect(launch: xcode.launch) { bridge throws(InspectorError) in
      try await bridge.call(.endSession, ["interactionSessionKey": "s1"])
    }

    #expect(result == ToolResult(text: "Session stopped"))
    let bridge = try #require(xcode.launched.first)
    #expect(bridge.received.map { $0["method"] } == ["initialize", "notifications/initialized", "tools/call"])
    #expect(bridge.calls == [FakeXcode.Call(tool: "DeviceInteractionEndSession", arguments: ["interactionSessionKey": "s1"])])
    #expect(bridge.wasFinished)
    #expect(!bridge.wasTerminated)
  }

  @Test("Xcode's refusal of an unapproved binary ends in NOT_APPROVED after one call, never a retry")
  func notApproved() async throws {
    let refusal = """
      This agent isn't approved to use Xcode's tools yet. Call XcodeOpenWorkspace or XcodeNewProject first: \
      opening or creating a project is what asks the user to approve this agent, together with access to that \
      project's folder.
      """
    let xcode = FakeXcode { _ in .error(refusal) }

    let error = await #expect(throws: InspectorError.self) {
      try await XcodeBridge.connect(launch: xcode.launch) { bridge throws(InspectorError) in
        try await bridge.call(.endSession, [:])
      }
    }

    #expect(
      error
        == InspectorError(
          code: .notApproved,
          message:
            "Xcode has not approved this inspector binary; a human confirms Xcode's dialog that asks to allow `de.juliankahnert.inspector`",
          detail: refusal))
    #expect(xcode.calls.count == 1)
    #expect(xcode.launched.allSatisfy { $0.wasFinished })
  }

  @Test("any other failure of a tool ends in XCODE_ERROR quoting Xcode's text")
  func toolFailure() async throws {
    let xcode = FakeXcode { _ in .error("Session doesn't exist anymore") }

    let error = await #expect(throws: InspectorError.self) {
      try await XcodeBridge.connect(launch: xcode.launch) { bridge throws(InspectorError) in
        try await bridge.call(.endSession, [:])
      }
    }

    #expect(
      error
        == InspectorError(
          code: .xcodeError, message: "`DeviceInteractionEndSession` failed: Session doesn't exist anymore",
          detail: "Session doesn't exist anymore"))
  }

  @Test("a tool that does not answer in time ends in TIMEOUT and the bridge is killed")
  func toolTimeout() async throws {
    let xcode = FakeXcode { _ in .silence }

    let error = await #expect(throws: InspectorError.self) {
      try await XcodeBridge.connect(launch: xcode.launch) { bridge throws(InspectorError) in
        try await bridge.call(.synthesize, [:], timeout: .milliseconds(20))
      }
    }

    #expect(error?.code == .timeout)
    #expect(error?.message == "Xcode did not answer `DeviceInteractionSynthesize` within 0.02 s")
    #expect(xcode.launched.first?.wasTerminated == true)
  }

  @Test("a bridge that never answers initialize ends in TIMEOUT before any tool call")
  func initializeTimeout() async throws {
    let bridge = FakeBridge { _ in nil }

    let error = await #expect(throws: InspectorError.self) {
      try await XcodeBridge.connect(launch: { bridge }, initializeTimeout: .milliseconds(20)) {
        bridge throws(InspectorError) in try await bridge.call(.listTargets, [:])
      }
    }

    #expect(error?.code == .timeout)
    #expect(bridge.calls.isEmpty)
  }

  @Test(
    "a bridge that exits before it answers: XCODE_TOO_OLD for a missing mcpbridge, else XCODE_ERROR with its stderr",
    arguments: [
      ("xcrun: error: unable to find utility \"mcpbridge\", not a developer tool or in PATH\n", ErrorCode.xcodeTooOld),
      ("mcpbridge: Xcode is not running\n", .xcodeError),
    ])
  func exitedEarly(stderr: String, code: ErrorCode) async throws {
    let error = await #expect(throws: InspectorError.self) {
      try await XcodeBridge.connect(launch: { FakeBridge.exited(stderr: stderr) }) { bridge throws(InspectorError) in
        try await bridge.call(.listTargets, [:])
      }
    }

    #expect(error?.code == code)
    #expect(error?.detail == stderr.trimmingCharacters(in: .newlines))
  }
}
