import ArgumentParser
import InspectorKit

/// `inspector type <text> [--until <match>]`: text typed into the simulator's focused field.
struct TypeCommand: InspectorCommand {
  static let configuration = CommandConfiguration(
    commandName: "type",
    abstract: "Types text into the focused field in the simulator.",
    usage: "inspector type [--app <name>] <text> [--until <match> [--timeout <seconds>]]",
    discussion: """
      `${NAME}` in the text is filled from `.inspector/.env` and masked in the answer and in \
      `run.json`. Xcode reads `\\u{000A}` in the text as Return. Without --until the answer is \
      the command Xcode ran; with it, the answer is like send's, diffed against the state before \
      typing. Needs `.inspector/` with a session; gestures work only in the simulator.
      """)

  @OptionGroup var options: AppOptions

  @OptionGroup var condition: UntilOptions

  // An array that takes unrecognized input, so text starting with a dash, such as `-5`, is not
  // read as an option. `validate()` keeps it to one value.
  @Argument(parsing: .allUnrecognized, help: ArgumentHelp("The text to type.", valueName: "text"))
  var text: [String] = []

  func validate() throws {
    guard text.count == 1 else {
      throw ValidationError("Expected one text, got \(text.count); quote text with spaces")
    }
  }

  func answer(in environment: Environment) async throws(InspectorError) -> any Encodable {
    let raw = text[0]
    let filled = Placeholders.fill(raw, from: try environment.placeholderValues(in: raw))
    return try await Gesture.type(filled).perform(until: condition, app: options.app, in: environment)
  }
}
