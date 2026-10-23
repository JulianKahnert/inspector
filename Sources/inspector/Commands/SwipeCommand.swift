import ArgumentParser
import InspectorKit

/// `inspector swipe <x1> <y1> <x2> <y2> [duration] [--until <match>]`: a swipe in the simulator.
struct SwipeCommand: InspectorCommand {
  static let configuration = CommandConfiguration(
    commandName: "swipe",
    abstract: "Swipes across the simulator's screen from one point to another.",
    usage: "inspector swipe [--app <name>] <x1> <y1> <x2> <y2> [<seconds>] [--until <match> [--timeout <seconds>]]",
    discussion: """
      Without --until the answer is the command Xcode ran; with it, the answer is like send's, \
      diffed against the state before the swipe. Needs `.inspector/` with a session; gestures \
      work only in the simulator.
      """)

  @OptionGroup var options: AppOptions

  @OptionGroup var condition: UntilOptions

  @Argument(help: "Where the swipe starts and ends, in points.")
  var coordinates: [Double] = []

  func validate() throws {
    guard coordinates.count == 4 || coordinates.count == 5 else {
      throw ValidationError("Expected <x1> <y1> <x2> <y2> [duration], got \(coordinates.count) numbers")
    }
    guard coordinates.count == 4 || coordinates[4] > 0 else {
      throw ValidationError("The duration must be a positive number of seconds, got \(coordinates[4])")
    }
  }

  func answer(in environment: Environment) async throws(InspectorError) -> any Encodable {
    let gesture = Gesture.swipe(
      from: Point(x: coordinates[0], y: coordinates[1]), to: Point(x: coordinates[2], y: coordinates[3]),
      duration: coordinates.count == 5 ? coordinates[4] : nil)
    return try await gesture.perform(until: condition, app: options.app, in: environment)
  }
}
