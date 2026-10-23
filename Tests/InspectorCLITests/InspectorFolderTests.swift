import Foundation
import Synchronization
import Testing

@testable import InspectorKit
@testable import inspector

@Suite("The .inspector folder")
struct InspectorFolderTests {
  @Test("without --app a command talks to the instance config.json names")
  func instanceFromConfig() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.write(".inspector/config.json", #"{"instance":"DemoHost @ Mac"}"#)
      let selections = Selections()
      let environment = sandbox.environment(try await demoApp()).recording(selections)

      let outcome = await InspectorCLI.outcome(of: ["state", "counter"], in: environment)

      #expect(outcome == .stdout("0"))
      #expect(selections.all == ["DemoHost @ Mac"])
    }
  }

  @Test("the folder is found from any directory below it")
  func upwardSearch() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.write("repo/.inspector/config.json", #"{"instance":"DemoHost @ Mac"}"#)
      try sandbox.makeDirectory("repo/Sources/App")
      let selections = Selections()
      let environment = sandbox.environment(try await demoApp(), in: "repo/Sources/App").recording(selections)

      _ = await InspectorCLI.outcome(of: ["hello"], in: environment)

      #expect(selections.all == ["DemoHost @ Mac"])
    }
  }

  @Test("the search ends at the repository root, so a folder above it does not count")
  func searchEndsAtRepositoryRoot() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.write(".inspector/config.json", #"{"instance":"Other @ Mac"}"#)
      try sandbox.makeDirectory("repo/.git")
      try sandbox.makeDirectory("repo/Sources")
      let selections = Selections()
      let environment = sandbox.environment(try await demoApp(), in: "repo/Sources").recording(selections)

      _ = await InspectorCLI.outcome(of: ["hello"], in: environment)

      #expect(selections.all == [nil])
    }
  }

  @Test("--app wins over the instance in config.json")
  func appOptionWins() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.write(".inspector/config.json", #"{"instance":"DemoHost @ Mac"}"#)
      let selections = Selections()
      let environment = sandbox.environment(try await demoApp()).recording(selections)

      _ = await InspectorCLI.outcome(of: ["--app", "DemoHost", "catalog"], in: environment)

      #expect(selections.all == ["DemoHost"])
    }
  }

  @Test(
    "INSPECTOR_DIR names the folder instead of the search, absolute or relative to the working directory",
    arguments: ["elsewhere/.inspector", "ABSOLUTE"])
  func inspectorDirOverride(directory: String) async throws {
    try await Sandbox.run { sandbox in
      try sandbox.write(".inspector/config.json", #"{"instance":"Nearby @ Mac"}"#)
      try sandbox.write("elsewhere/.inspector/config.json", #"{"instance":"DemoHost @ Mac"}"#)
      let selections = Selections()
      var environment = sandbox.environment(try await demoApp()).recording(selections)
      environment.inspectorDirectory = directory == "ABSOLUTE" ? sandbox.url("elsewhere/.inspector").path : directory

      _ = await InspectorCLI.outcome(of: ["hello"], in: environment)

      #expect(selections.all == ["DemoHost @ Mac"])
    }
  }

  @Test("an INSPECTOR_DIR that does not exist fails with NO_CONFIG and the path, even with --app")
  func inspectorDirMissing() async throws {
    try await Sandbox.run { sandbox in
      var environment = sandbox.environment(try await demoApp())
      environment.inspectorDirectory = sandbox.url("gone").path

      let outcome = await InspectorCLI.outcome(of: ["--app", "DemoHost", "state"], in: environment)

      #expect(
        outcome
          == .stderr(
            #"{"code":"NO_CONFIG","detail":"\#(sandbox.url("gone").path)","message":"no `.inspector/` folder; run `inspector init`"}"#
          ))
    }
  }

  @Test("without a folder the wire commands work as before, with or without --app")
  func noFolder() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("repo/.git")
      let environment = sandbox.environment(try await demoApp(), in: "repo")

      #expect(await InspectorCLI.outcome(of: ["state", "counter"], in: environment) == .stdout("0"))
      #expect(await InspectorCLI.outcome(of: ["--app", "DemoHost", "state", "counter"], in: environment) == .stdout("0"))
      #expect(sandbox.read("repo/.inspector/run.json") == nil)
    }
  }

  @Test(
    "every loop command records itself and its arguments as lastStep in run.json, failed or not",
    arguments: [
      ["hello"],
      ["catalog"],
      ["state", "counter"],
      ["send", "counter.set", "42"],
      ["--app", "DemoHost", "send", "counter.sett"],
    ])
  func lastStep(arguments: [String]) async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory(".inspector")
      let command = arguments.first { !$0.hasPrefix("-") && $0 != "DemoHost" } ?? ""

      _ = await InspectorCLI.outcome(of: arguments, in: sandbox.environment(try await demoApp()))

      #expect(
        try sandbox.json(".inspector/run.json")
          == .object([
            "lastStep": .object([
              "arguments": .array(arguments.map { .string($0) }),
              "at": "2026-10-19T08:53:20.250Z",
              "command": .string(command),
            ])
          ]))
    }
  }

  @Test("recording a step keeps what other commands wrote to run.json")
  func lastStepKeepsOtherFields() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.write(
        ".inspector/run.json",
        #"{"lastScreenshot":"/tmp/a.png","lastStep":{"arguments":["hello"],"at":"2026-01-01T00:00:00.000Z","command":"hello"}}"#)

      _ = await InspectorCLI.outcome(of: ["catalog"], in: sandbox.environment(try await demoApp()))

      #expect(
        try sandbox.json(".inspector/run.json")
          == .object([
            "lastScreenshot": "/tmp/a.png",
            "lastStep": .object(["arguments": .array(["catalog"]), "at": "2026-10-19T08:53:20.250Z", "command": "catalog"]),
          ]))
    }
  }

  @Test("apps is discovery: it records no step")
  func appsRecordsNoStep() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory(".inspector")

      _ = await InspectorCLI.outcome(of: ["apps"], in: sandbox.environment(try await demoApp()))

      #expect(sandbox.read(".inspector/run.json") == nil)
    }
  }

  @Test("no command writes config.json")
  func configIsLeftAlone() async throws {
    try await Sandbox.run { sandbox in
      let config = #"{"instance":"DemoHost @ Mac","session":"s1"}"#
      try sandbox.write(".inspector/config.json", config)
      let environment = sandbox.environment(try await demoApp())

      for arguments in [["apps"], ["hello"], ["catalog"], ["state"], ["send", "counter.set", "1"], ["send", "nope"]] {
        _ = await InspectorCLI.outcome(of: arguments, in: environment)
      }

      #expect(sandbox.read(".inspector/config.json") == config)
    }
  }

  @Test("writing the config creates the folder and stamps writtenAt; every field reads back")
  func writeConfig() async throws {
    try await Sandbox.run { sandbox in
      let folder = InspectorFolder(url: sandbox.url(".inspector"))
      let config = InspectorConfig(
        app: "DemoHost", instance: "DemoHost @ Mac", bundleId: "de.example.demo", udid: "UDID-1",
        session: "inspector-demo-1", workspace: "workspace-1", scheme: "Demo", logSubsystem: "de.example")

      try folder.writeConfig(config, at: Sandbox.now)

      #expect(
        try sandbox.json(".inspector/config.json")
          == .object([
            "app": "DemoHost", "instance": "DemoHost @ Mac", "bundleId": "de.example.demo", "udid": "UDID-1",
            "session": "inspector-demo-1", "workspace": "workspace-1", "scheme": "Demo", "logSubsystem": "de.example",
            "writtenAt": "2026-10-19T08:53:20Z",
          ]))
      var stamped = config
      stamped.writtenAt = Date(timeIntervalSince1970: 1_792_400_000)
      #expect(try folder.config() == stamped)
    }
  }
}
