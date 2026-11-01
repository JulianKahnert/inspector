import Foundation
import Synchronization
import Testing

@testable import InspectorKit
@testable import inspector

@Suite("simulator")
struct SimulatorTests {
  /// A simulator in `simctl list`.
  struct Device {
    var udid: String
    var name: String
    var state = "Shutdown"
    var runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
    var type = "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"
  }

  /// `simctl` with `devices` and three iOS runtimes: 27.2 with an iPhone 18 Pro and an iPad Pro,
  /// a 27.2 for one prerelease device only, and 26.5 with an iPhone 17 Pro. `create` adds a
  /// device as `NEW-<n>`.
  final class FakeSimctl: Sendable {
    let devices: Mutex<[Device]>

    init(_ devices: [Device] = []) {
      self.devices = Mutex(devices)
    }

    var processes: FakeProcesses { FakeProcesses(reply: reply) }

    /// The answer to `command`: `list` and `create` as `simctl` gives them, success for any other.
    func reply(_ command: [String]) -> ProcessOutput {
        guard command.starts(with: ["/usr/bin/xcrun", "simctl"]) else { return ProcessOutput(status: 0) }
        switch command[2] {
        case "list": return ProcessOutput(status: 0, stdout: self.listJSON())
        case "create":
          let udid = self.devices.withLock { devices in
            let udid = "NEW-\(devices.count + 1)"
            devices.append(Device(udid: udid, name: command[3], runtime: command[5], type: command[4]))
            return udid
          }
          return ProcessOutput(status: 0, stdout: udid + "\n")
        default: return ProcessOutput(status: 0)
        }
    }

    private func listJSON() -> String {
      let byRuntime = Dictionary(grouping: devices.withLock { $0 }, by: \.runtime).mapValues { list in
        "[" + list.map {
          #"{"udid":"\#($0.udid)","name":"\#($0.name)","state":"\#($0.state)","isAvailable":true,"deviceTypeIdentifier":"\#($0.type)"}"#
        }.joined(separator: ",") + "]"
      }
      let devices = byRuntime.map { #""\#($0.key)":\#($0.value)"# }.joined(separator: ",")
      let type = { (id: String, name: String, family: String) in
        #"{"identifier":"com.apple.CoreSimulator.SimDeviceType.\#(id)","name":"\#(name)","productFamily":"\#(family)"}"#
      }
      return #"""
        {"devicetypes":[],"devices":{\#(devices)},"runtimes":[
        {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","version":"26.5","platform":"iOS","isAvailable":true,
         "supportedDeviceTypes":[\#(type("iPhone-17-Pro", "iPhone 17 Pro", "iPhone"))]},
        {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-2-Prerelease","version":"27.2","platform":"iOS","isAvailable":true,
         "supportedDeviceTypes":[\#(type("iPhone-Duo", "iPhone Duo", "iPhone"))]},
        {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-2","version":"27.2","platform":"iOS","isAvailable":true,
         "supportedDeviceTypes":[\#(type("iPad-Pro", "iPad Pro", "iPad")),\#(type("iPhone-18-Pro", "iPhone 18 Pro", "iPhone")),\#(type("iPhone-17-Pro", "iPhone 17 Pro", "iPhone"))]},
        {"identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-12-0","version":"12.0","platform":"watchOS","isAvailable":true,"supportedDeviceTypes":[]}
        ]}
        """#
    }
  }

  static func choose(
    _ simctl: FakeSimctl, in sandbox: Sandbox, folder: String = "app/.inspector", label: String = "ABC-123",
    requested: String? = nil, previous: String? = nil, family: Simulator.Family = .iPhone
  ) async throws(InspectorError) -> String {
    let environment = sandbox.environment(
      simctl.processes.environment(Environment(transport: { _ in NoApp() }, instanceNames: { _ in [] })))
    return try await Simulator.choose(
      requested: requested, previous: previous, label: label, family: family,
      folder: InspectorFolder(url: sandbox.url(folder)), in: environment)
  }

  /// `folder` holds a live session on `udid`: it claimed it and its `config.json` names it.
  static func liveSession(_ folder: String, on udid: String, in sandbox: Sandbox) throws {
    try sandbox.write("\(folder)/config.json", #"{"udid":"\#(udid)"}"#)
    #expect(
      SimulatorClaims(directory: sandbox.url("simulator-claims"), now: Sandbox.now)
        .claim(udid, for: InspectorFolder(url: sandbox.url(folder))))
  }

  @Test(
    "the label is the ticket key from the branch, else from the directory, in upper case, else the directory",
    arguments: [
      ("feature/abc-123-login", "app", "ABC-123"),
      ("main", "XY2-77-fix", "XY2-77"),
      ("ABC-1-first", "DEF-2", "ABC-1"),
      ("main", "app", "app"),
      ("main", "app-1.2", "app-1.2"),
      (nil, "XY-9", "XY-9"),
    ] as [(String?, String, String)])
  func label(branch: String?, directory: String, expected: String) {
    #expect(Simulator.label(branch: branch, directory: directory) == expected)
  }

  @Test("with no simulator for the worktree it creates one: the newest iPhone on the newest iOS runtime, and claims it")
  func createsNewest() async throws {
    try await Sandbox.run { sandbox in
      let simctl = FakeSimctl([Device(udid: "OTHER", name: "iPhone 18 Pro", state: "Booted")])

      let udid = try await Self.choose(simctl, in: sandbox)

      #expect(udid == "NEW-2")
      #expect(simctl.devices.withLock { $0.last?.name } == "ABC-123 inspector iPhone 18 Pro")
      #expect(simctl.devices.withLock { $0.last?.runtime } == "com.apple.CoreSimulator.SimRuntime.iOS-27-2")
      #expect(
        try sandbox.json("simulator-claims/NEW-2.json")["owner"] == .string(sandbox.url("app/.inspector").path))
    }
  }

  @Test("an iPad app gets the newest iPad")
  func createsIPad() async throws {
    try await Sandbox.run { sandbox in
      let simctl = FakeSimctl()

      _ = try await Self.choose(simctl, in: sandbox, family: .iPad)

      #expect(simctl.devices.withLock { $0.last?.name } == "ABC-123 inspector iPad Pro")
    }
  }

  @Test("a later init of the worktree reuses its simulator, also after .inspector/ was removed")
  func reusesNamed() async throws {
    try await Sandbox.run { sandbox in
      let simctl = FakeSimctl([
        Device(udid: "MINE", name: "ABC-123 inspector iPhone 17 Pro"),
        Device(udid: "GENERIC", name: "iPhone 18 Pro", state: "Booted"),
      ])

      let chosen1 = try await Self.choose(simctl, in: sandbox)
      #expect(chosen1 == "MINE")
      let chosen2 = try await Self.choose(simctl, in: sandbox, previous: "MINE")
      #expect(chosen2 == "MINE")
      #expect(simctl.devices.withLock { $0.count } == 2)
    }
  }

  @Test("a simulator another live session holds is never taken: a second worktree with the same key gets its own")
  func skipsLiveClaim() async throws {
    try await Sandbox.run { sandbox in
      let simctl = FakeSimctl([Device(udid: "FIRST", name: "ABC-123 inspector iPhone 18 Pro", state: "Booted")])
      try Self.liveSession("first/.inspector", on: "FIRST", in: sandbox)

      let udid = try await Self.choose(simctl, in: sandbox, folder: "second/.inspector", previous: "FIRST")

      #expect(udid == "NEW-2")
      #expect(simctl.devices.withLock { $0.last?.name } == "ABC-123 inspector iPhone 18 Pro 2")
      #expect(try sandbox.json("simulator-claims/FIRST.json")["owner"] == .string(sandbox.url("first/.inspector").path))
    }
  }

  @Test("a claim whose folder no longer names the simulator is stale and taken over")
  func takesStaleClaim() async throws {
    try await Sandbox.run { sandbox in
      let simctl = FakeSimctl([Device(udid: "FIRST", name: "ABC-123 inspector iPhone 18 Pro")])
      try Self.liveSession("first/.inspector", on: "FIRST", in: sandbox)
      try FileManager.default.removeItem(at: sandbox.url("first/.inspector"))

      let chosen3 = try await Self.choose(simctl, in: sandbox, folder: "second/.inspector")
      #expect(chosen3 == "FIRST")
      #expect(try sandbox.json("simulator-claims/FIRST.json")["owner"] == .string(sandbox.url("second/.inspector").path))
    }
  }

  @Test("an old config's simulator that is not the worktree's own is left alone; the new one copies its type and runtime")
  func leavesSharedPrevious() async throws {
    try await Sandbox.run { sandbox in
      let simctl = FakeSimctl([
        Device(
          udid: "SHARED", name: "iPhone 17 Pro", state: "Booted", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
          type: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
      ])

      let udid = try await Self.choose(simctl, in: sandbox, previous: "SHARED")

      #expect(udid == "NEW-2")
      let created = simctl.devices.withLock { $0.last }
      #expect(created?.name == "ABC-123 inspector iPhone 17 Pro")
      #expect(created?.runtime == "com.apple.CoreSimulator.SimRuntime.iOS-26-5")
    }
  }

  @Test("an old config's simulator this folder claimed stays, whatever its name")
  func keepsClaimedPrevious() async throws {
    try await Sandbox.run { sandbox in
      let simctl = FakeSimctl([Device(udid: "OLD", name: "OLD-1 inspector iPhone 18 Pro")])
      try Self.liveSession("app/.inspector", on: "OLD", in: sandbox)

      let chosen4 = try await Self.choose(simctl, in: sandbox, previous: "OLD")
      #expect(chosen4 == "OLD")
    }
  }

  @Test("--udid takes a free simulator and claims it; one another live session holds ends in DEVICE_IN_USE")
  func requested() async throws {
    try await Sandbox.run { sandbox in
      let simctl = FakeSimctl([Device(udid: "FREE", name: "iPhone 18 Pro"), Device(udid: "HELD", name: "iPhone 17 Pro")])
      try Self.liveSession("first/.inspector", on: "HELD", in: sandbox)

      let chosen5 = try await Self.choose(simctl, in: sandbox, requested: "FREE")
      #expect(chosen5 == "FREE")
      let error = await #expect(throws: InspectorError.self) {
        try await Self.choose(simctl, in: sandbox, requested: "HELD")
      }
      #expect(error?.code == .deviceInUse)
      #expect(error?.detail == sandbox.url("first/.inspector").path)
      let missing = await #expect(throws: InspectorError.self) {
        try await Self.choose(simctl, in: sandbox, requested: "NONE")
      }
      #expect(missing?.code == .badRequest)
    }
  }
}
