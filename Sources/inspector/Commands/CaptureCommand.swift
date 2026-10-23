import ArgumentParser
import Foundation
import InspectorKit

/// `inspector capture`: the simulator's screen as Xcode captures it, with the targets on it.
struct CaptureCommand: InspectorCommand {
  static let configuration = CommandConfiguration(
    commandName: "capture",
    abstract: "Captures the screen: the screenshot's and the hierarchy's paths, and the targets on it.",
    discussion: """
      A target is a control on the screen, with its `type`, `identifier`, `label`, `placeholder` \
      and `value` where the hierarchy names them, and the `hitPoint` a tap goes to, as [x, y] in \
      points. The paths go to `run.json` as `lastScreenshot` and `lastHierarchy`. Needs \
      `.inspector/` with a session, which `inspector init` starts.
      """)

  func answer(in environment: Environment) async throws(InspectorError) -> any Encodable {
    var session = try DeviceSession(in: environment)
    let result = try await environment.withXcode { xcode throws(InspectorError) in
      try await session.call(.synthesize, on: xcode, in: environment)
    }
    let artifacts = result.json.objectValue ?? [:]
    guard let hierarchy = artifacts["hierarchyPath"]?.stringValue, !hierarchy.isEmpty,
      let text = try? String(contentsOfFile: hierarchy, encoding: .utf8), !text.isEmpty
    else {
      throw InspectorError(
        code: .noHierarchy, message: "the capture has no hierarchy; capture again, else read the screenshot",
        detail: result.text)
    }
    let screenshot = artifacts["screenshotPath"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    // The capture happened whether or not run.json can be written; failing now would hide it.
    try? session.folder.updateRun {
      $0["lastHierarchy"] = .string(hierarchy)
      $0["lastScreenshot"] = screenshot.map(JSONValue.string)
    }
    return Captured(screenshot: screenshot, hierarchy: hierarchy, targets: Target.list(inHierarchy: text))
  }

  /// Where the capture's artifacts are and what an agent can act on.
  struct Captured: Encodable {
    var screenshot: String?
    var hierarchy: String
    var targets: [Target]
  }
}
