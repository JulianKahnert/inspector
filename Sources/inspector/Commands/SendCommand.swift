import ArgumentParser
import Foundation
import InspectorKit

/// `inspector send <path> [json]`: one action, answered with whether its effects settled, the
/// new state and the diff.
struct SendCommand: InspectorCommand {
  static let configuration = CommandConfiguration(
    commandName: "send",
    abstract: "Sends one action and prints whether its effects settled, the new state and the diff.",
    usage: "inspector send [--app <name>] <path> [<json>]")

  @OptionGroup var options: AppOptions

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
    var payload: JSONValue?
    if let raw = self.payload.first { payload = try Self.parsePayload(raw, filledFrom: environment) }
    let request = SendRequest(path: path, payload: payload)
    return try await environment.answer(to: .send(request), from: options.app)
  }

  /// A payload argument with its `${NAME}` placeholders filled from `.inspector/.env`.
  ///
  /// In a payload that is JSON already, the values go into its strings and keys as text, so a
  /// quote in a value cannot break the JSON; otherwise into the raw text before it is parsed, so
  /// `${VALUE}` alone can become a number.
  static func parsePayload(_ raw: String, filledFrom environment: Environment) throws(InspectorError) -> JSONValue {
    let values = try environment.placeholderValues(in: raw)
    guard !values.isEmpty else { return parsePayload(raw) }
    if let json = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) {
      return json.mappingStrings { Placeholders.fill($0, from: values) }
    }
    return parsePayload(Placeholders.fill(raw, from: values))
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
