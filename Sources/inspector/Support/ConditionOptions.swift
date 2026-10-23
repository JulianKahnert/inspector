import ArgumentParser
import Foundation
import InspectorKit

/// A match document given on the command line: a JSON object the state has to contain.
///
/// Anything that is not a JSON object is a usage error, so a typo never turns into a condition
/// that cannot hold.
struct MatchDocument: ExpressibleByArgument, Sendable {
  var value: JSONValue

  init?(argument: String) {
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(argument.utf8)), value.objectValue != nil
    else { return nil }
    self.value = value
  }
}

/// `--timeout <s>`: how long a condition may take to hold, 3 seconds when left out.
struct ConditionTimeoutOption: ParsableArguments {
  @Option(
    help: ArgumentHelp(
      "How long the condition may take to hold, in seconds; 3 when left out.", valueName: "seconds"))
  var timeout: Double?

  /// The timeout as a request carries it; `nil` leaves the app's default.
  var timeoutMs: Int? {
    timeout.map { Int(($0 * 1000).rounded()) }
  }

  func validate() throws {
    guard let timeout else { return }
    guard timeout.isFinite, timeout > 0 else {
      throw ValidationError("--timeout must be a positive number of seconds, got \(timeout)")
    }
  }
}

/// `--until <match>` and `--timeout <s>`: after this command's step, wait inside the app until
/// the state contains the match.
///
/// A command that takes them answers like `send`, with `settled`, `state` and `diff`.
struct UntilOptions: ParsableArguments {
  @Option(
    help: ArgumentHelp(
      """
      A JSON object the state has to contain before the command answers: `{}` as a value asks \
      only for the key, an array matches as a prefix, a scalar exactly.
      """,
      valueName: "match"))
  var until: MatchDocument?

  @OptionGroup var timeout: ConditionTimeoutOption

  /// The match document, or `nil` without `--until`.
  var match: JSONValue? { until?.value }

  func validate() throws {
    guard until == nil, timeout.timeout != nil else { return }
    throw ValidationError("--timeout needs --until")
  }
}
