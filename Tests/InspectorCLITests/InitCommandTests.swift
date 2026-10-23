import Foundation
import Synchronization
import Testing

@testable import InspectorKit
@testable import inspector

@Suite("init")
struct InitCommandTests {
  /// Xcode with the demo workspace open: one app target, its build settings, a session on
  /// `UDID-1` and a build that succeeds.
  static func xcode(
    installAndRun: FakeXcode.Reply = .text(#"{"userMessage":"Application installed and running"}"#)
  ) -> FakeXcode {
    FakeXcode { call in
      switch call.tool {
      case "XcodeOpenWorkspace":
        return .text(
          #"{"activeRunDestination":"iPhone 17","activeScheme":"DemoHost","workspaceIdentifier":"workspace-1","workspacePath":"\#(call.arguments["path"]?.stringValue ?? "")"}"#
        )
      case "XcodeListTargets":
        return .text(
          #"{"targets":[{"name":"DemoHost","productTypeIdentifier":"com.apple.product-type.application"}],"totalTargets":1,"truncated":false}"#
        )
      case "GetTargetBuildSettings":
        return .text(
          #"{"buildSettings":[{"evaluatedValue":"com.example.demo","macroName":"PRODUCT_BUNDLE_IDENTIFIER"},{"evaluatedValue":"DemoHost","macroName":"PRODUCT_NAME","value":"$(TARGET_NAME)"}],"targetName":"DemoHost"}"#
        )
      case "DeviceInteractionStartWorkspaceSession":
        return .text(
          #"{"deviceIsSimulator":true,"deviceUUID":"UDID-1","interactionSessionKey":"\#(call.arguments["sessionIdentifier"]?.stringValue ?? "")"}"#
        )
      case "DeviceInteractionInstallAndRun":
        return installAndRun
      case "DeviceInteractionEndSession":
        return .text(#"{"userMessage":"Session stopped"}"#)
      default:
        return .error("unexpected tool \(call.tool)")
      }
    }
  }

  /// Xcode runs; `git` sees `.inspector/` as not ignored and keeps its excludes in
  /// `.git/info/exclude`.
  static func processes() -> FakeProcesses {
    FakeProcesses { command in
      switch command.dropFirst().last {
      case "Xcode": return ProcessOutput(status: 0, stdout: "8160\n")
      case ".inspector/": return ProcessOutput(status: 1)
      case "info/exclude": return ProcessOutput(status: 0, stdout: ".git/info/exclude\n")
      default: return ProcessOutput(status: 0)
      }
    }
  }

  @Test("init opens the repository's workspace, starts a session, installs and runs the app and writes every field")
  func cold() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.makeDirectory("app/App/Demo.xcodeproj")
      let xcode = Self.xcode()
      let processes = Self.processes()
      let environment = processes.environment(xcode.environment(serving: try await demoApp().named("DemoHost @ Mac")))

      let outcome = await InspectorCLI.outcome(of: ["init"], in: sandbox.environment(environment, in: "app"))

      let project = sandbox.url("app/App/Demo.xcodeproj").path
      let config =
        #"{"app":"DemoHost","bundleId":"com.example.demo","instance":"DemoHost @ Mac","logSubsystem":"com.example.","scheme":"DemoHost","session":"inspector-app-20261019-085320","udid":"UDID-1","workspace":"workspace-1","writtenAt":"2026-10-19T08:53:20Z"}"#
      #expect(
        outcome
          == .stdout(
            #"{"config":\#(config),"hello":{"app":"DemoHost","instance":"DemoHost @ Mac","pid":\#(ProcessInfo.processInfo.processIdentifier),"provider":"Inspector"},"state":{"counter":0,"device":{"name":"Mac","pid":"1"}}}"#
          ))
      #expect(
        xcode.calls == [
          FakeXcode.Call(tool: "XcodeOpenWorkspace", arguments: ["path": .string(project)]),
          FakeXcode.Call(
            tool: "XcodeListTargets",
            arguments: ["workspaceIdentifier": "workspace-1", "productTypeFilter": .array(["application"])]),
          FakeXcode.Call(
            tool: "GetTargetBuildSettings", arguments: ["workspaceIdentifier": "workspace-1", "targetName": "DemoHost"]),
          FakeXcode.Call(
            tool: "DeviceInteractionStartWorkspaceSession",
            arguments: ["sessionIdentifier": "inspector-app-20261019-085320", "workspaceIdentifier": "workspace-1"]),
          FakeXcode.Call(
            tool: "DeviceInteractionInstallAndRun",
            arguments: ["interactionSessionKey": "inspector-app-20261019-085320", "workspaceIdentifier": "workspace-1"]),
        ])
      #expect(try sandbox.json("app/.inspector/config.json") == (try JSONDecoder().decode(JSONValue.self, from: Data(config.utf8))))
      #expect(sandbox.read("app/.git/info/exclude") == "/.inspector/\n")
    }
  }

  @Test("init --warm reads hello and state of the serving app, starts no bridge and keeps the session")
  func warm() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.write(
        "app/.inspector/config.json",
        #"{"app":"DemoHost","bundleId":"com.example.demo","session":"inspector-app-1","udid":"UDID-1","workspace":"workspace-1"}"#)
      let xcode = FakeXcode { _ in .text("unexpected") }
      let processes = FakeProcesses { _ in ProcessOutput(status: 0) }
      let environment = processes.environment(xcode.environment(serving: try await demoApp().named("DemoHost @ Mac")))

      let outcome = await InspectorCLI.outcome(of: ["init", "--warm"], in: sandbox.environment(environment, in: "app"))

      #expect(
        outcome
          == .stdout(
            #"{"config":{"app":"DemoHost","bundleId":"com.example.demo","instance":"DemoHost @ Mac","session":"inspector-app-1","udid":"UDID-1","workspace":"workspace-1","writtenAt":"2026-10-19T08:53:20Z"},"hello":{"app":"DemoHost","instance":"DemoHost @ Mac","pid":\#(ProcessInfo.processInfo.processIdentifier),"provider":"Inspector"},"state":{"counter":0,"device":{"name":"Mac","pid":"1"}}}"#
          ))
      #expect(xcode.launched.isEmpty)
    }
  }

  @Test("init --warm without a serving app names the one next step, a cold init, and writes nothing")
  func warmWithoutApp() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      let xcode = FakeXcode { _ in .text("unexpected") }

      let outcome = await InspectorCLI.outcome(
        of: ["init", "--warm"], in: sandbox.environment(xcode.environment(), in: "app"))

      #expect(
        outcome
          == .stderr(
            #"{"code":"APP_NOT_FOUND","detail":"no serving app found","message":"the app does not serve; run `inspector init` without `--warm`"}"#
          ))
      #expect(xcode.launched.isEmpty)
      #expect(sandbox.read("app/.inspector/config.json") == nil)
    }
  }

  @Test("init --reset ends the old session, asks for the old device and uninstalls the app before the install")
  func resetWithOldSession() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.makeDirectory("app/Demo.xcodeproj")
      try sandbox.write("app/.inspector/config.json", #"{"session":"inspector-app-old","udid":"UDID-1"}"#)
      let processes = Self.processes()
      let uninstalledBeforeInstall = Mutex<Bool?>(nil)
      let xcode = FakeXcode { call in
        if call.tool == "DeviceInteractionInstallAndRun" {
          uninstalledBeforeInstall.withLock { $0 = processes.commands.contains { $0.contains("uninstall") } }
        }
        return Self.xcode().reply(call)
      }
      let environment = processes.environment(xcode.environment(serving: try await demoApp().named("DemoHost @ Mac")))

      let outcome = await InspectorCLI.outcome(of: ["init", "--reset"], in: sandbox.environment(environment, in: "app"))

      #expect(outcome.exitCode == 0)
      #expect(
        xcode.calls.map(\.tool) == [
          "XcodeOpenWorkspace", "XcodeListTargets", "GetTargetBuildSettings", "DeviceInteractionEndSession",
          "DeviceInteractionStartWorkspaceSession", "DeviceInteractionInstallAndRun",
        ])
      #expect(xcode.calls[3].arguments == ["interactionSessionKey": "inspector-app-old"])
      #expect(xcode.calls[4].arguments["deviceIdentifier"] == "UDID-1")
      #expect(processes.commands.contains(["/usr/bin/xcrun", "simctl", "uninstall", "UDID-1", "com.example.demo"]))
      #expect(uninstalledBeforeInstall.withLock { $0 } == true)
    }
  }

  @Test("init records itself as lastStep in the folder it created, so logs.sh reads from its start")
  func recordsStep() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.makeDirectory("app/Demo.xcodeproj")
      let environment = Self.processes().environment(Self.xcode().environment(serving: try await demoApp()))

      _ = await InspectorCLI.outcome(of: ["init"], in: sandbox.environment(environment, in: "app"))

      #expect(
        try sandbox.json("app/.inspector/run.json")
          == .object([
            "lastStep": .object(["arguments": .array(["init"]), "at": "2026-10-19T08:53:20.250Z", "command": "init"])
          ]))
    }
  }

  @Test("init creates the folder INSPECTOR_DIR names, and adds no exclude for a folder outside the repository root")
  func createsInspectorDirectory() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.makeDirectory("app/Demo.xcodeproj")
      let processes = Self.processes()
      var environment = processes.environment(Self.xcode().environment(serving: try await demoApp()))
      environment.inspectorDirectory = sandbox.url("elsewhere/.inspector").path

      let outcome = await InspectorCLI.outcome(of: ["init"], in: sandbox.environment(environment, in: "app"))

      #expect(outcome.exitCode == 0)
      #expect(try sandbox.json("elsewhere/.inspector/config.json")["session"] == "inspector-app-20261019-085320")
      #expect(try sandbox.json("elsewhere/.inspector/run.json")["lastStep"]?["command"] == "init")
      #expect(!processes.commands.contains { $0.first == "/usr/bin/git" })
    }
  }

  @Test(
    "logSubsystem is the bundle ID's vendor prefix, so the app's packages are covered; a short ID stays whole",
    arguments: [
      ("de.juliankahnert.RoommateAlbert", "de.juliankahnert."),
      ("com.example.demo.debug", "com.example."),
      ("com.example", "com.example"),
      ("demo", "demo"),
    ])
  func logSubsystem(bundleID: String, expected: String) {
    #expect(InitCommand.logSubsystem(forBundleID: bundleID) == expected)
  }

  @Test("init without --reset never uninstalls")
  func noReset() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.makeDirectory("app/Demo.xcodeproj")
      let processes = Self.processes()
      let environment = processes.environment(Self.xcode().environment(serving: try await demoApp()))

      _ = await InspectorCLI.outcome(of: ["init"], in: sandbox.environment(environment, in: "app"))

      #expect(!processes.commands.contains { $0.contains("uninstall") })
    }
  }

  @Test("init starts Xcode with the workspace when it is not running, before the bridge")
  func startsXcode() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.makeDirectory("app/Demo.xcodeproj")
      let xcode = Self.xcode()
      let openedBeforeBridge = Mutex<Bool?>(nil)
      let processes = FakeProcesses { command in
        command.last == "Xcode" ? ProcessOutput(status: 1) : ProcessOutput(status: 0)
      }
      var environment = processes.environment(xcode.environment(serving: try await demoApp()))
      environment.launchBridge = {
        openedBeforeBridge.withLock { $0 = processes.commands.contains { $0.first == "/usr/bin/xed" } }
        return xcode.launch()
      }

      let outcome = await InspectorCLI.outcome(of: ["init"], in: sandbox.environment(environment, in: "app"))

      #expect(outcome.exitCode == 0)
      #expect(processes.commands.contains(["/usr/bin/xed", "-b", sandbox.url("app/Demo.xcodeproj").path]))
      #expect(openedBeforeBridge.withLock { $0 } == true)
    }
  }

  @Test("init on a binary Xcode has not approved ends in NOT_APPROVED with the human's step, writing nothing")
  func notApproved() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.makeDirectory("app/Demo.xcodeproj")
      let refusal =
        "This agent isn't approved to use Xcode's tools yet. Call XcodeOpenWorkspace or XcodeNewProject first."
      let xcode = FakeXcode { _ in .error(refusal) }
      let environment = Self.processes().environment(xcode.environment(serving: try await demoApp()))

      let outcome = await InspectorCLI.outcome(of: ["init"], in: sandbox.environment(environment, in: "app"))

      #expect(
        outcome
          == .stderr(
            #"{"code":"NOT_APPROVED","detail":"\#(refusal)","message":"Xcode has not approved this inspector binary; a human confirms Xcode's dialog that asks to allow `de.juliankahnert.inspector`, then `inspector init` runs again"}"#
          ))
      #expect(xcode.calls.map(\.tool) == ["XcodeOpenWorkspace"])
      #expect(sandbox.read("app/.inspector/config.json") == nil)
    }
  }

  @Test("init on an Xcode without mcpbridge ends in XCODE_TOO_OLD")
  func xcodeTooOld() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.makeDirectory("app/Demo.xcodeproj")
      var environment = Self.processes().environment(try await demoApp())
      environment.launchBridge = { FakeBridge.exited(stderr: "xcrun: error: unable to find utility \"mcpbridge\"") }

      let outcome = await InspectorCLI.outcome(of: ["init"], in: sandbox.environment(environment, in: "app"))

      #expect(
        outcome
          == .stderr(
            #"{"code":"XCODE_TOO_OLD","detail":"xcrun: error: unable to find utility \"mcpbridge\"","message":"the selected Xcode has no `mcpbridge`; select Xcode 27.2 or newer"}"#
          ))
    }
  }

  @Test("a failed build passes Xcode's output through and leaves config.json naming the session for `end`")
  func buildFails() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.makeDirectory("app/Demo.xcodeproj")
      let failure = "Build failed: ContentView.swift:12: error: cannot find 'x' in scope"
      let environment = Self.processes().environment(
        Self.xcode(installAndRun: .error(failure)).environment(serving: try await demoApp()))

      let outcome = await InspectorCLI.outcome(of: ["init"], in: sandbox.environment(environment, in: "app"))

      #expect(
        outcome
          == .stderr(
            #"{"code":"XCODE_ERROR","detail":"\#(failure)","message":"`DeviceInteractionInstallAndRun` failed: \#(failure)"}"#))
      #expect(try sandbox.json("app/.inspector/config.json")["session"] == "inspector-app-20261019-085320")
    }
  }

  @Test("an app that does not serve after its launch ends in APP_NOT_FOUND with the next step, after three tries")
  func launchedAppDoesNotServe() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.makeDirectory("app/Demo.xcodeproj")
      let selections = Selections()
      let environment = Self.processes().environment(Self.xcode().environment().recording(selections))

      let outcome = await InspectorCLI.outcome(of: ["init"], in: sandbox.environment(environment, in: "app"))

      #expect(
        outcome
          == .stderr(
            #"{"code":"APP_NOT_FOUND","detail":"no serving app found","message":"the app does not serve after its launch; check that its debug build calls `serve()`, or pass `--app` with the name `inspector apps` lists"}"#
          ))
      #expect(selections.all == ["DemoHost", "DemoHost", "DemoHost"])
      #expect(try sandbox.json("app/.inspector/config.json")["session"] == "inspector-app-20261019-085320")
    }
  }

  @Test("--app names the scheme to build when the workspace has one of that name")
  func appPicksScheme() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.makeDirectory("app/Demo.xcodeproj")
      let xcode = FakeXcode { call in
        switch call.tool {
        case "XcodeListSchemes":
          return .text(#"{"activeSchemeName":"DemoHost","schemes":[{"name":"DemoHost"},{"name":"Other"}]}"#)
        case "XcodeSwitchScheme":
          return .text(#"{"activeSchemeName":"Other"}"#)
        case "XcodeListTargets":
          return .text(
            #"{"targets":[{"name":"DemoHost","productTypeIdentifier":"com.apple.product-type.application"},{"name":"Other","productTypeIdentifier":"com.apple.product-type.application"}]}"#
          )
        default:
          return Self.xcode().reply(call)
        }
      }
      let environment = Self.processes().environment(xcode.environment(serving: try await demoApp()))

      _ = await InspectorCLI.outcome(
        of: ["init", "--app", "Other @ iPhone 17"], in: sandbox.environment(environment, in: "app"))

      #expect(
        xcode.calls.prefix(5) == [
          FakeXcode.Call(tool: "XcodeOpenWorkspace", arguments: ["path": .string(sandbox.url("app/Demo.xcodeproj").path)]),
          FakeXcode.Call(tool: "XcodeListSchemes", arguments: ["workspaceIdentifier": "workspace-1"]),
          FakeXcode.Call(tool: "XcodeSwitchScheme", arguments: ["workspaceIdentifier": "workspace-1", "schemeName": "Other"]),
          FakeXcode.Call(
            tool: "XcodeListTargets",
            arguments: ["workspaceIdentifier": "workspace-1", "productTypeFilter": .array(["application"])]),
          FakeXcode.Call(
            tool: "GetTargetBuildSettings", arguments: ["workspaceIdentifier": "workspace-1", "targetName": "Other"]),
        ])
      let config = try sandbox.json("app/.inspector/config.json")
      #expect(config["app"] == "Other @ iPhone 17")
      #expect(config["scheme"] == "Other")
    }
  }

  @Test("a repository that ignores .inspector/ already gets no exclude entry")
  func alreadyIgnored() async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      try sandbox.makeDirectory("app/Demo.xcodeproj")
      let processes = FakeProcesses { _ in ProcessOutput(status: 0) }
      let environment = processes.environment(Self.xcode().environment(serving: try await demoApp()))

      let outcome = await InspectorCLI.outcome(of: ["init"], in: sandbox.environment(environment, in: "app"))

      #expect(outcome.exitCode == 0)
      #expect(!processes.commands.contains { $0.contains("rev-parse") })
      #expect(sandbox.read("app/.git/info/exclude") == nil)
    }
  }

  @Test(
    "init finds the one workspace, preferring it over the project it holds; several or none are a usage problem",
    arguments: [
      (["App/Demo.xcodeproj", "App/Demo.xcworkspace", "Pods/Pods.xcodeproj"], "App/Demo.xcworkspace"),
      (["Demo.xcodeproj", ".build/Hidden.xcworkspace", "build/Out.xcworkspace"], "Demo.xcodeproj"),
      (["A.xcodeproj", "B/B.xcodeproj"], nil),
      ([], nil),
    ])
  func findsWorkspace(directories: [String], expected: String?) async throws {
    try await Sandbox.run { sandbox in
      try sandbox.makeDirectory("app/.git")
      for directory in directories { try sandbox.makeDirectory("app/\(directory)") }

      let found = Result { () throws(InspectorError) in try WorkspaceFinder.find(in: sandbox.url("app")) }

      switch (found, expected) {
      case (.success(let url), let expected?):
        #expect(url.standardizedFileURL.path(percentEncoded: false).hasSuffix("app/\(expected)/"))
      case (.failure(let error), nil):
        #expect(error.code == .badRequest)
        #expect(error.message.contains("pass `--workspace <path>`"))
      default:
        Issue.record("found \(found), expected \(expected ?? "an error")")
      }
    }
  }

  @Test("--reset and --workspace need a build; with --warm they are usage errors", arguments: ["--reset", "--workspace=x"])
  func warmUsage(option: String) async throws {
    let outcome = await InspectorCLI.outcome(of: ["init", "--warm", option], in: try await demoApp())

    #expect(outcome.exitCode == 64)
  }
}
