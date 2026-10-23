import ArgumentParser
import Foundation
import InspectorKit

/// `inspector send <path> [json] [--until <match>]`: one action, answered with whether its
/// effects settled, the new state and the diff; with `--until` once the state contains the match.
struct SendCommand: InspectorCommand {
  static let configuration = CommandConfiguration(
    commandName: "send",
    abstract: "Sends one action and prints whether its effects settled, the new state and the diff.",
    usage: "inspector send [--app <name>] <path> [<json>] [--until <match> [--timeout <seconds>]]",
    discussion: """
      With --until, the answer waits until the state contains the match; the app checks it \
      itself, so a screen that registers after the action is seen without polling. A condition \
      that does not hold in time fails with EXPECTATION_FAILED, the last state in `detail`.
      """)

  @OptionGroup var options: AppOptions

  @OptionGroup var condition: UntilOptions

  @Argument(help: "The action's path, as `inspector catalog` lists it.")
  var path: String

  // An array that takes unrecognized input, so a payload starting with a dash, such as `-5`, is
  // not read as an option. `validate()` keeps it to one value.
  @Argument(
    parsing: .allUnrecognized,
    help: ArgumentHelp(
      "The payload; anything that does not parse as JSON is sent as a string.", valueName: "json"))
  var payload: [String] = []

  func validate() throws {
    guard payload.count <= 1 else {
      throw ValidationError("Expected at most one payload, got \(payload.count): \(payload.joined(separator: " "))")
    }
  }

  func answer(in environment: Environment) async throws(InspectorError) -> any Encodable {
    let request = SendRequest(
      path: path,
      payload: payload.first.map(Self.parsePayload),
      until: condition.match,
      untilTimeoutMs: condition.match == nil ? nil : condition.timeout.timeoutMs)
    return try await environment.answer(to: .send(request), from: options.app)
  }

  /// A payload argument is JSON if it parses as JSON, otherwise a plain string.
  static func parsePayload(_ raw: String) -> JSONValue {
    guard let data = raw.data(using: .utf8),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data)
    else {
      return .string(raw)
    }
    return value
  }
}
