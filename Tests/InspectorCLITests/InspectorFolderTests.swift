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
}
