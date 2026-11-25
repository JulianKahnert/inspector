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
            tool: tool.tool.rawValue, arguments: [parameter: "inspector-app-1", "interactionCommand": "t 1 2"])
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
            tool: "DeviceInteractionStartSession",
            arguments: ["sessionIdentifier": "inspector-app-20261019-085320-250", "deviceIdentifier": "UDID-1"]),
          FakeXcode.Call(
            tool: "DeviceInteractionSynthesize", arguments: ["interactSessionKey": "inspector-app-20261019-085320-250"]),
        ])
      #expect(
        try sandbox.json("app/.inspector/config.json")
          == .object([
            "instance": "DemoHost @ Mac", "session": "inspector-app-20261019-085320-250", "udid": "UDID-1",
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
          == ["DeviceInteractionSynthesize", "DeviceInteractionStartSession", "DeviceInteractionSynthesize"])
    }
  }

  @Test("a config.json without a device cannot start a session: NO_SESSION, even with the app serving")
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

  @Test("session names differ within one second: they carry milliseconds")
  func uniqueNames() {
    let first = DeviceSession.newName(repository: "app", at: Sandbox.now)
    let second = DeviceSession.newName(repository: "app", at: Sandbox.now.addingTimeInterval(0.001))

    #expect(first == "inspector-app-20261019-085320-250")
    #expect(second == "inspector-app-20261019-085320-251")
  }

  @Test("a restart waits for a session another live process is starting and takes it instead of starting one")
  func restartWaitsForLock() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      let xcode = FakeXcode { call in
        guard call.arguments["interactSessionKey"] == "inspector-app-1" else { return .text("captured") }
        // While the session is lost, process 4242 starts the next one under the lock.
        try? sandbox.write("app/.inspector/session.lock", "4242\n")
        Task {
          try? await Task.sleep(for: .milliseconds(120))
          try? sandbox.write(
            "app/.inspector/config.json", Self.config.replacing("inspector-app-1", with: "inspector-app-other"))
          try? FileManager.default.removeItem(at: sandbox.url("app/.inspector/session.lock"))
        }
        return .error(Self.notFound)
      }
      var environment = sandbox.environment(xcode.environment(serving: try await demoApp()), in: "app")
      environment.processIsAlive = { _ in true }
      environment.processID = 1

      var session = try DeviceSession(in: environment)
      let result = try await environment.withXcode { xcode throws(InspectorError) in
        try await session.call(.synthesize, on: xcode, in: environment)
      }

      #expect(result.text == "captured")
      #expect(session.name == "inspector-app-other")
      #expect(xcode.calls.map(\.tool) == ["DeviceInteractionSynthesize", "DeviceInteractionSynthesize"])
      #expect(sandbox.read("app/.inspector/session.lock") == nil)
    }
  }

  @Test("the first call waits while a live process holds session.lock, then uses the session it wrote")
  func firstCallWaitsForLock() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      try sandbox.write("app/.inspector/session.lock", "4242\n")
      let xcode = FakeXcode { _ in .text("captured") }
      var environment = sandbox.environment(xcode.environment(), in: "app")
      environment.processIsAlive = { $0 == 4242 }

      var session = try DeviceSession(in: environment)
      Task {
        try? await Task.sleep(for: .milliseconds(120))
        try? sandbox.write(
          "app/.inspector/config.json", Self.config.replacing("inspector-app-1", with: "inspector-app-new"))
        try? FileManager.default.removeItem(at: sandbox.url("app/.inspector/session.lock"))
      }
      _ = try await environment.withXcode { xcode throws(InspectorError) in
        try await session.call(.synthesize, on: xcode, in: environment)
      }

      #expect(
        xcode.calls == [
          FakeXcode.Call(tool: "DeviceInteractionSynthesize", arguments: ["interactSessionKey": "inspector-app-new"])
        ])
    }
  }

  @Test("a stale session.lock, whose process is gone, is removed and not waited for")
  func staleLock() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write("app/.inspector/config.json", Self.config)
      try sandbox.write("app/.inspector/session.lock", "4242\n")
      let xcode = FakeXcode { _ in .text("captured") }
      var environment = sandbox.environment(xcode.environment(), in: "app")
      environment.processIsAlive = { _ in false }

      var session = try DeviceSession(in: environment)
      _ = try await environment.withXcode { xcode throws(InspectorError) in
        try await session.call(.synthesize, on: xcode, in: environment)
      }

      #expect(xcode.calls.map { $0.arguments["interactSessionKey"] } == ["inspector-app-1"])
      #expect(sandbox.read("app/.inspector/session.lock") == nil)
    }
  }
}

@Suite("Session lock")
struct SessionLockTests {
  /// The lock of a sandboxed `.inspector/`, taken by process 7, polling every 10 ms.
  private static func lock(
    in sandbox: Sandbox, maximumWait: Duration = .seconds(10), alive: @escaping @Sendable (Int32) -> Bool
  ) throws -> SessionLock {
    try sandbox.makeDirectory(".inspector")
    var lock = SessionLock(in: InspectorFolder(url: sandbox.url(".inspector")), processID: 7, isAlive: alive)
    lock.pollInterval = .milliseconds(10)
    lock.maximumWait = maximumWait
    return lock
  }

  @Test("acquire writes this process's ID into a new lock file; release removes it")
  func acquireAndRelease() async throws {
    try await Sandbox.run { sandbox in
      let lock = try Self.lock(in: sandbox) { _ in true }

      let waited = try await lock.acquire()

      #expect(!waited)
      #expect(sandbox.read(".inspector/session.lock") == "7\n")
      #expect(lock.holder == .live(7))
      lock.release()
      #expect(lock.holder == SessionLock.Holder.none)
    }
  }

  @Test(
    "a lock whose process is dead, or that names none, is stale and taken over",
    arguments: ["4242\n", "", "not a pid"])
  func staleTakenOver(content: String) async throws {
    try await Sandbox.run { sandbox in
      let lock = try Self.lock(in: sandbox) { $0 == 7 }
      try sandbox.write(".inspector/session.lock", content)

      #expect(lock.holder == .stale)
      let waited = try await lock.acquire()

      #expect(!waited)
      #expect(sandbox.read(".inspector/session.lock") == "7\n")
    }
  }

  @Test("acquire waits for a live holder to release the lock")
  func waitsForLiveHolder() async throws {
    try await Sandbox.run { sandbox in
      let lock = try Self.lock(in: sandbox) { _ in true }
      try sandbox.write(".inspector/session.lock", "4242\n")
      Task {
        try? await Task.sleep(for: .milliseconds(50))
        try? FileManager.default.removeItem(at: sandbox.url(".inspector/session.lock"))
      }

      let waited = try await lock.acquire()

      #expect(waited)
      #expect(sandbox.read(".inspector/session.lock") == "7\n")
    }
  }

  @Test("a live holder that keeps the lock past the maximum wait ends acquire in TIMEOUT")
  func liveHolderTimesOut() async throws {
    try await Sandbox.run { sandbox in
      let lock = try Self.lock(in: sandbox, maximumWait: .milliseconds(200)) { _ in true }
      try sandbox.write(".inspector/session.lock", "4242\n")

      let error = await #expect(throws: InspectorError.self) { try await lock.acquire() }

      #expect(error?.code == .timeout)
      #expect(sandbox.read(".inspector/session.lock") == "4242\n")
    }
  }

  @Test("waitWhileHeld returns at once without a lock, removes a stale one and waits out a live one")
  func waitWhileHeld() async throws {
    try await Sandbox.run { sandbox in
      let lock = try Self.lock(in: sandbox) { $0 == 4242 }
      #expect(await lock.waitWhileHeld() == false)

      try sandbox.write(".inspector/session.lock", "99\n")
      #expect(await lock.waitWhileHeld() == false)
      #expect(sandbox.read(".inspector/session.lock") == nil)

      try sandbox.write(".inspector/session.lock", "4242\n")
      Task {
        try? await Task.sleep(for: .milliseconds(50))
        try? FileManager.default.removeItem(at: sandbox.url(".inspector/session.lock"))
      }
      #expect(await lock.waitWhileHeld() == true)
    }
  }

  @Test("release leaves a lock another process holds alone")
  func releaseKeepsOthers() async throws {
    try await Sandbox.run { sandbox in
      let lock = try Self.lock(in: sandbox) { _ in true }
      try sandbox.write(".inspector/session.lock", "4242\n")

      lock.release()

      #expect(sandbox.read(".inspector/session.lock") == "4242\n")
    }
  }

  @Test("the current process runs; a process that exited does not")
  func liveness() async throws {
    #expect(SessionLock.isRunning(ProcessInfo.processInfo.processIdentifier))
    #expect(!SessionLock.isRunning(0))
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/true")
    try process.run()
    process.waitUntilExit()
    #expect(!SessionLock.isRunning(process.processIdentifier))
  }
}
