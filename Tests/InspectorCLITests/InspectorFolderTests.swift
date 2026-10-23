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

  @Test(
    "send fills ${NAME} in the payload from .inspector/.env",
    arguments: [
      ("${VALUE}", "VALUE=42"),
      ("${VALUE}", "# a comment\n\nexport VALUE=\"42\"\n"),
      ("${TENS}${ONES}", "TENS=4\nONES='2'\n"),
    ])
  func substitution(payload: String, dotenv: String) async throws {
    try await Sandbox.run { sandbox in
      try sandbox.write(".inspector/.env", dotenv)
      let environment = sandbox.environment(try await demoApp())

      let outcome = await InspectorCLI.outcome(of: ["send", "counter.set", payload], in: environment)

      #expect(outcome.exitCode == 0)
      #expect(await InspectorCLI.outcome(of: ["state", "counter"], in: environment) == .stdout("42"))
    }
  }

  @Test("a ${NAME} inside a JSON string is filled as text, even with quotes in the value")
  func substitutionInsideJSON() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.write(".inspector/.env", #"SECRET=pa"ss"#)
      let environment = sandbox.environment(try await echoApp())

      let outcome = await InspectorCLI.outcome(
        of: ["send", "login", #"{"user":"team","password":"${SECRET}"}"#], in: environment)

      #expect(outcome.exitCode == 0)
      #expect(
        await InspectorCLI.outcome(of: ["state", "received"], in: environment)
          == .stdout(#"{"password":"pa\"ss","user":"team"}"#))
    }
  }

  @Test("a placeholder without a value fails with ENV_MISSING naming every missing variable; nothing is sent")
  func envMissing() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.write(".inspector/.env", "USER=team\n")
      let environment = sandbox.environment(try await echoApp())

      let outcome = await InspectorCLI.outcome(
        of: ["send", "login", #"{"user":"${USER}","password":"${PASSWORD}","otp":"${OTP}"}"#], in: environment)

      let dotenv = sandbox.url(".inspector/.env").path
      #expect(
        outcome
          == .stderr(
            #"{"code":"ENV_MISSING","detail":"PASSWORD OTP","message":"no value for `${PASSWORD}`, `${OTP}` in `\#(dotenv)`"}"#
          ))
      #expect(await InspectorCLI.outcome(of: ["state", "received"], in: environment) == .stdout("null"))
    }
  }

  @Test("without .env every placeholder is missing")
  func envFileMissing() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory(".inspector")

      let outcome = await InspectorCLI.outcome(
        of: ["send", "counter.set", "${VALUE}"], in: sandbox.environment(try await demoApp()))

      #expect(outcome.stderr.hasPrefix(#"{"code":"ENV_MISSING","detail":"VALUE","#))
    }
  }

  @Test("a placeholder without a folder fails with NO_CONFIG and where the folder belongs")
  func placeholderWithoutFolder() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("repo/.git")
      try sandbox.makeDirectory("repo/Sources")
      let environment = sandbox.environment(try await demoApp(), in: "repo/Sources")

      let outcome = await InspectorCLI.outcome(of: ["send", "counter.set", "${VALUE}"], in: environment)

      #expect(
        outcome
          == .stderr(
            #"{"code":"NO_CONFIG","detail":"\#(sandbox.url("repo/.inspector").path)","message":"no `.inspector/` folder; run `inspector init`"}"#
          ))
    }
  }

  @Test("a filled-in value shows as ${NAME} in the answer, also where the state has it for another reason")
  func maskedAnswer() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.write(".inspector/.env", "VALUE=42\n")

      let outcome = await InspectorCLI.outcome(
        of: ["send", "login", #"{"code":"${VALUE}"}"#], in: sandbox.environment(try await echoApp()))

      #expect(
        outcome
          == .stdout(
            #"{"diff":[{"new":{"code":"${VALUE}"},"old":null,"path":"received"}],"settled":true,"state":{"motto":"the answer is ${VALUE}","received":{"code":"${VALUE}"}}}"#
          ))
    }
  }

  @Test("a number that equals a filled-in value is masked as the string ${NAME}")
  func maskedNumber() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.write(".inspector/.env", "VALUE=42\n")

      let outcome = await InspectorCLI.outcome(
        of: ["send", "counter.set", "${VALUE}"], in: sandbox.environment(try await demoApp()))

      #expect(
        outcome
          == .stdout(
            #"{"diff":[{"new":"${VALUE}","old":0,"path":"counter"}],"settled":true,"state":{"counter":"${VALUE}","device":{"name":"Mac","pid":"1"}}}"#
          ))
    }
  }

  @Test("a filled-in value shows as ${NAME} in an error's message, detail and suggestions")
  func maskedError() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.write(".inspector/.env", "TOKEN=s3cr3t\n")

      let outcome = await InspectorCLI.outcome(
        of: ["send", "reject", "Bearer ${TOKEN}"], in: sandbox.environment(try await echoApp()))

      #expect(
        outcome
          == .stderr(
            #"{"code":"BAD_REQUEST","detail":"Bearer ${TOKEN}","didYouMean":["Bearer ${TOKEN}"],"message":"rejected `Bearer ${TOKEN}`"}"#
          ))
    }
  }

  @Test("run.json shows a filled-in value as ${NAME}, also where it was typed literally")
  func maskedRun() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.write(".inspector/.env", "VALUE=42\n")

      _ = await InspectorCLI.outcome(
        of: ["send", "login", #"{"a":"${VALUE}","b":"42"}"#], in: sandbox.environment(try await echoApp()))

      #expect(
        try sandbox.json(".inspector/run.json")
          == .object([
            "lastStep": .object([
              "arguments": .array(["send", "login", #"{"a":"${VALUE}","b":"${VALUE}"}"#]),
              "at": "2026-10-19T08:53:20.250Z",
              "command": "send",
            ])
          ]))
    }
  }

  @Test("a value that is part of its own placeholder leaves the placeholder intact")
  func valueInsidePlaceholder() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.write(".inspector/.env", "NAME=NAME\n")

      let outcome = await InspectorCLI.outcome(
        of: ["send", "reject", "${NAME}"], in: sandbox.environment(try await echoApp()))

      #expect(outcome.stderr.contains(#""message":"rejected `${NAME}`""#))
      #expect(
        try sandbox.json(".inspector/run.json").objectValue?["lastStep"]?.objectValue?["arguments"]
          == .array(["send", "reject", "${NAME}"]))
    }
  }

  @Test("only filled-in values are masked: no key name, and no .env value the payload did not use")
  func noKeywordHeuristic() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.write(".inspector/.env", "USER=team\nPASSWORD=unused\n")

      let outcome = await InspectorCLI.outcome(
        of: ["send", "login", #"{"user":"${USER}","password":"unused","token":"abc"}"#],
        in: sandbox.environment(try await echoApp()))

      #expect(
        outcome
          == .stdout(
            #"{"diff":[{"new":{"password":"unused","token":"abc","user":"${USER}"},"old":null,"path":"received"}],"settled":true,"state":{"motto":"the answer is 42","received":{"password":"unused","token":"abc","user":"${USER}"}}}"#
          ))
    }
  }

  @Test("masking ends with the call: a later call that fills nothing in prints the value")
  func nothingFilledNothingMasked() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.write(".inspector/.env", "VALUE=42\n")
      let environment = sandbox.environment(try await demoApp())

      _ = await InspectorCLI.outcome(of: ["send", "counter.set", "${VALUE}"], in: environment)

      #expect(await InspectorCLI.outcome(of: ["state", "counter"], in: environment) == .stdout("42"))
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
