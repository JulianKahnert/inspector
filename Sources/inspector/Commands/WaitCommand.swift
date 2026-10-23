import ArgumentParser
import InspectorKit

/// `inspector wait <match>`: the state, as soon as it contains the match document.
struct WaitCommand: InspectorCommand {
  static let configuration = CommandConfiguration(
    commandName: "wait",
    abstract: "Prints the state as soon as it contains a match document.",
    discussion: """
      The app checks the condition itself, right away, whenever a screen registers or goes away, \
      and every 25 ms. A condition that does not hold in time fails with EXPECTATION_FAILED, the \
      last state in `detail`.
      """)

  @OptionGroup var options: AppOptions

  @Argument(
    help: ArgumentHelp(
      """
      A JSON object the state has to contain: `{}` as a value asks only for the key, an array \
      matches as a prefix, a scalar exactly.
      """,
      valueName: "match"))
  var match: MatchDocument

  @OptionGroup var timeout: ConditionTimeoutOption

  func answer(in environment: Environment) async throws(InspectorError) -> any Encodable {
    try await environment.wait(WaitRequest(until: match.value, timeoutMs: timeout.timeoutMs), from: options.app).state
  }
}
