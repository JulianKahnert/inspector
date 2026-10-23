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

  func validate() throws {
    switch (x, y, target) {
    case (.some, .some, nil), (nil, nil, .some): return
    default: throw ValidationError("Expected either <x> <y> or --target <name>")
    }
  }

  func answer(in environment: Environment) async throws(InspectorError) -> any Encodable {
    var gesture = Gesture.tapTarget(target ?? "")
    if let x, let y { gesture = .tap(Point(x: x, y: y)) }
    return try await gesture.perform(until: condition, app: options.app, in: environment)
  }
}
