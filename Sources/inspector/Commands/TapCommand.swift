import ArgumentParser
import InspectorKit

/// `inspector tap <x> <y> | --target <name> [--until <match>]`: a tap in the simulator.
struct TapCommand: InspectorCommand {
  static let configuration = CommandConfiguration(
    commandName: "tap",
    abstract: "Taps the simulator's screen at a point or on a target.",
    usage: "inspector tap [--app <name>] (<x> <y> | --target <name>) [--until <match> [--timeout <seconds>]]",
    discussion: """
      --target captures the screen first and taps the hit point of the one target whose \
      identifier or label is the name; none fails with TARGET_NOT_FOUND, several with \
      TARGET_AMBIGUOUS, both with the targets in `detail`. Without --until the answer is the \
      command Xcode ran; with it, the answer is like send's, diffed against the state before the \
      tap. Needs `.inspector/` with a session; gestures work only in the simulator.
      """)

  @OptionGroup var options: AppOptions

  @OptionGroup var condition: UntilOptions

  @Option(help: ArgumentHelp("The identifier or label of the target to tap.", valueName: "name"))
  var target: String?

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
  }

  func answer(in environment: Environment) async throws(InspectorError) -> any Encodable {
    // `validate()` has rejected every other combination before this runs.
    guard let gesture else { throw InspectorError(code: .badRequest, message: Self.usage) }
    return try await gesture.perform(until: condition.request, app: options.app, in: environment)
  }
}
