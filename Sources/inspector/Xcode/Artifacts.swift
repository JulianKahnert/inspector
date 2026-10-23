import Foundation
import InspectorKit

/// The files `DeviceInteractionSynthesize` wrote for one call: what the screen showed afterwards.
struct Artifacts {
  /// The hierarchy text file's path, `nil` when Xcode named none.
  var hierarchy: String?
  /// The screenshot's path, `nil` when Xcode named none.
  var screenshot: String?

  /// Writes the paths to `run.json` as `lastHierarchy` and `lastScreenshot`, dropping a path Xcode
  /// did not name rather than keeping an older one.
  func record(in folder: InspectorFolder) {
    // The call happened whether or not run.json can be written; failing now would hide it.
    try? folder.updateRun {
      $0["lastHierarchy"] = hierarchy.map(JSONValue.string)
      $0["lastScreenshot"] = screenshot.map(JSONValue.string)
    }
  }
}

extension Artifacts {
  /// The artifacts Xcode's answer names.
  init(of result: ToolResult) {
    let answer = result.json.objectValue ?? [:]
    hierarchy = answer["hierarchyPath"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    screenshot = answer["screenshotPath"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
  }
}

/// A capture of the screen: its artifacts and the targets in its hierarchy.
struct Capture: Encodable {
  /// The screenshot's path.
  var screenshot: String?
  /// The hierarchy text file's path.
  var hierarchy: String
  /// The targets in the hierarchy.
  var targets: [Target]
}

extension DeviceSession {
  /// Captures the screen without acting on it.
  ///
  /// - Throws: ``ErrorCode/noHierarchy`` with Xcode's answer in `detail` when the capture has no
  ///   readable, non-empty hierarchy, and every error of ``call(_:_:timeout:on:in:)``.
  mutating func capture(on xcode: XcodeBridge, in environment: Environment) async throws(InspectorError) -> Capture {
    let result = try await call(.synthesize, on: xcode, in: environment)
    let artifacts = Artifacts(of: result)
    guard let hierarchy = artifacts.hierarchy,
      let text = try? String(contentsOfFile: hierarchy, encoding: .utf8), !text.isEmpty
    else {
      throw InspectorError(
        code: .noHierarchy, message: "the capture has no hierarchy; capture again, else read the screenshot",
        detail: result.text)
    }
    return Capture(screenshot: artifacts.screenshot, hierarchy: hierarchy, targets: Target.list(inHierarchy: text))
  }
}
