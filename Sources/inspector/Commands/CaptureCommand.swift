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
    let capture = try await environment.withXcode { xcode throws(InspectorError) in
      try await session.capture(on: xcode, in: environment)
    }
    Artifacts(hierarchy: capture.hierarchy, screenshot: capture.screenshot).record(in: session.folder)
    return capture
  }
}
