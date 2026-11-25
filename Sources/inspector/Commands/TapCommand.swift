import ArgumentParser
import InspectorKit

/// `inspector tap <x> <y> | --target <name> [--until <match>]`: a tap in the simulator.
struct TapCommand: InspectorCommand {
  static let configuration = CommandConfiguration(
    commandName: "tap",
    abstract: "Taps the simulator's screen at a point or on a target.",
    usage: """
      inspector tap [--app <name>] (<x> <y> | --target <name> [--find <seconds>]) [--targets] \
      [--xcode] [--until <match> [--timeout <seconds>]]
      """,
    discussion: """
      --target captures the screen first and taps the hit point of the one target whose \
      identifier or label is the name; none fails with TARGET_NOT_FOUND, several with \
      TARGET_AMBIGUOUS, both with the targets in `detail`. --find captures again every 300 ms \
      while the target is missing, until the seconds have passed, so a dialog that is still \
      appearing needs no sleep. Without --until the answer is the \
      command Xcode ran; with it, the answer is like send's, diffed against the state before the \
      tap. Needs `.inspector/` with a session; gestures work only in the simulator.

      --target first asks the app: its `ui.tap` action (built into InspectorKit on iOS) \
      activates the control inside the app in milliseconds; a name in the state's \
      `ui.hitPoints` is tapped there through Xcode without a capture; only then is the screen \
      captured. `via` in the answer says which: app, hitPoint or capture. --xcode skips the \
      first two.
      """)

  @OptionGroup var options: AppOptions

  @OptionGroup var condition: UntilOptions

  @OptionGroup var targets: TargetsOption

  @Option(help: ArgumentHelp("The identifier or label of the target to tap.", valueName: "name"))
  var target: String?

  @Option(
    help: ArgumentHelp(
      "With --target, how long to capture again every 300 ms while the target is missing.", valueName: "seconds"))
  var find: Double?

  @Flag(help: "With --target, tap through Xcode only, without asking the app first.")
  var xcode = false

  @Argument(help: "The x coordinate, in points.")
  var x: Double?

  @Argument(help: "The y coordinate, in points.")
  var y: Double?

  private static let usage = "Expected either <x> <y> or --target <name>"

  /// The tap the arguments name, or `nil` for neither or both of a point and a target.
  private var gesture: Gesture? {
    switch (x, y, target) {
    case (let x?, let y?, nil): .tap(Point(x: x, y: y))
    case (nil, nil, let name?): .tapTarget(name)
    default: nil
    }
  }

  func validate() throws {
    guard gesture != nil else { throw ValidationError(Self.usage) }
    if xcode, target == nil { throw ValidationError("--xcode needs --target") }
    guard let find else { return }
    guard target != nil else { throw ValidationError("--find needs --target") }
    guard find.isFinite, find > 0 else {
      throw ValidationError("--find must be a positive number of seconds, got \(find)")
    }
  }

  func answer(in environment: Environment) async throws(InspectorError) -> any Encodable {
    // `validate()` has rejected every other combination before this runs.
    guard let gesture else { throw InspectorError(code: .badRequest, message: Self.usage) }
    guard let target, !xcode else { return try await perform(gesture, in: environment) }
    let fastPath = FastTap(name: target, app: options.app, until: condition.request, targets: targets.targets)
    switch try await fastPath.attempt(in: environment) {
    case .answered(let answer):
      return Via(answer: answer, via: .app)
    case .hitPoint(let point):
      return Via(answer: try await perform(.tap(point), in: environment), via: .hitPoint)
    case .notInApp:
      return Via(answer: try await perform(gesture, in: environment), via: .capture)
    }
  }

  private func perform(_ gesture: Gesture, in environment: Environment) async throws(InspectorError) -> any Encodable {
    try await gesture.perform(
      until: condition.request, app: options.app, targets: targets.targets,
      find: find.map { .milliseconds(Int(($0 * 1000).rounded())) }, in: environment)
  }
}

/// The way `tap --target` took to the control.
enum TapRoute: String, Encodable {
  /// The app activated it through its `ui.tap` action.
  case app
  /// Xcode tapped the point the app's `ui.hitPoints` gave for the name.
  case hitPoint
  /// Xcode captured the screen and tapped the target's hit point.
  case capture
}

/// An answer with `via` beside its own fields.
struct Via: Encodable {
  var answer: any Encodable
  var via: TapRoute

  private enum CodingKeys: String, CodingKey { case via }

  func encode(to encoder: any Encoder) throws {
    try answer.encode(to: encoder)
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(via, forKey: .via)
  }
}

/// The ways `tap --target` tries before it captures the screen: the app's own `ui.tap`, then a
/// hit point from the app's `ui.hitPoints`.
struct FastTap {
  /// The action InspectorKit registers on iOS.
  static let actionPath = "ui.tap"

  var name: String
  var app: String?
  var until: WaitRequest?
  var targets: Bool

  enum Outcome {
    /// The app activated the control; the tap's answer.
    case answered(any Encodable)
    /// The app knows where the control is; Xcode taps there.
    case hitPoint(Point)
    /// Neither: Xcode captures the screen and looks for the target.
    case notInApp
  }

  /// Tries the app's `ui.tap`, then its hit points.
  ///
  /// An app that does not answer, has no `ui.tap` or cannot activate the name leads to the next
  /// way; once `ui.tap` passed, the tap happened, so an `--until` that does not hold fails like
  /// any other instead of tapping again.
  func attempt(in environment: Environment) async throws(InspectorError) -> Outcome {
    let before: JSONValue
    do throws(InspectorError) {
      before = try await environment.state(from: app)
    } catch {
      return .notInApp
    }
    do throws(InspectorError) {
      _ = try await environment.answer(
        to: .send(SendRequest(path: Self.actionPath, payload: .string(name))), from: app)
    } catch where Self.fallsBack(error) {
      // Not activated in the app; the hit points or a capture decide.
      if let point = Self.hitPoint(of: name, in: before) { return .hitPoint(point) }
      return .notInApp
    }
    // Outside the `do`: the control was activated, so a failing wait must not tap it again.
    return .answered(try await answer(before: before, in: environment))
  }

  /// Errors of `ui.tap` after which the control was not activated.
  private static func fallsBack(_ error: InspectorError) -> Bool {
    [.unknownActionPath, .targetNotFound, .expectationFailed, .payloadTypeMismatch].contains(error.code)
  }

  /// The answer after the app activated the control: the wait's, diffed against `before`, or
  /// what the app answered; with `targets`, plus the targets of a capture.
  private func answer(
    before: JSONValue, in environment: Environment
  ) async throws(InspectorError) -> any Encodable {
    var answer: any Encodable = Activated(target: name)
    if var until {
      until.baseline = before
      answer = try await environment.wait(until, from: app)
    }
    guard targets else { return answer }
    var session = try DeviceSession(in: environment)
    let capture = try await environment.withXcode { xcode throws(InspectorError) in
      try await session.capture(on: xcode, in: environment)
    }
    Artifacts(hierarchy: capture.hierarchy, screenshot: capture.screenshot, screenshotFull: capture.screenshotFull)
      .record(in: session.folder)
    return Gesture.WithTargets(answer: AnyEncodable(answer), targets: capture.targets)
  }

  /// The point `ui.hitPoints` lists for `name` in `state`.
  static func hitPoint(of name: String, in state: JSONValue) -> Point? {
    let points = state.objectValue?["ui"]?.objectValue?["hitPoints"]?.objectValue
    guard case .array(let pair)? = points?[name], pair.count == 2,
      let x = pair[0].doubleValue, let y = pair[1].doubleValue
    else { return nil }
    return Point(x: x, y: y)
  }

  /// What a tap the app performed answers without `--until`.
  struct Activated: Encodable {
    var target: String
  }
}

/// Any answer as a concrete `Encodable`.
struct AnyEncodable: Encodable {
  var value: any Encodable
  init(_ value: any Encodable) { self.value = value }
  func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
}
