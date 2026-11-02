import Foundation
import InspectorKit

/// The files `DeviceInteractionSynthesize` wrote for one call: what the screen showed afterwards.
struct Artifacts {
  /// The hierarchy text file's path, `nil` when Xcode named none.
  var hierarchy: String?
  /// The screenshot an agent reads: the small copy when ``Screenshot`` made one, else Xcode's
  /// file; `nil` when Xcode named none.
  var screenshot: String?
  /// Xcode's full-resolution screenshot when ``screenshot`` is its small copy, else `nil`.
  var screenshotFull: String?

  /// Writes the paths to `run.json` as `lastHierarchy`, `lastScreenshot` and
  /// `lastScreenshotFull`, dropping a path this call did not produce rather than keeping an older one.
  func record(in folder: InspectorFolder) {
    // The call happened whether or not run.json can be written; failing now would hide it.
    try? folder.updateRun {
      $0["lastHierarchy"] = hierarchy.map(JSONValue.string)
      $0["lastScreenshot"] = screenshot.map(JSONValue.string)
      $0["lastScreenshotFull"] = screenshotFull.map(JSONValue.string)
    }
  }
}

extension Artifacts {
  /// The artifacts Xcode's answer names, with a small copy of a screenshot larger than
  /// ``Screenshot/maxEdge`` written beside it.
  init(of result: ToolResult) {
    let answer = result.json.objectValue ?? [:]
    hierarchy = answer["hierarchyPath"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    let named = answer["screenshotPath"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    if let named, let small = Screenshot.smallCopy(of: named) {
      screenshot = small
      screenshotFull = named
    } else {
      screenshot = named
    }
  }
}

/// A capture of the screen: its artifacts and the targets in its hierarchy.
struct Capture: Encodable {
  /// The path of the screenshot to read: at most ``Screenshot/maxEdge`` pixels on its longest edge.
  var screenshot: String?
  /// Xcode's full-resolution screenshot, for a human; only when ``screenshot`` is its small copy.
  var screenshotFull: String?
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
    return Capture(
      screenshot: artifacts.screenshot, screenshotFull: artifacts.screenshotFull, hierarchy: hierarchy,
      targets: Target.list(inHierarchy: text))
  }
}
