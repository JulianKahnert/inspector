import ArgumentParser
import InspectorKit

/// `inspector hello`: which app answers, its pid and the provider behind it.
struct HelloCommand: InspectorCommand {
  static let configuration = CommandConfiguration(
    commandName: "hello",
    abstract: "Names the app, its process ID and the provider answering.")

  @OptionGroup var options: AppOptions

  func answer(in environment: Environment) async throws(InspectorError) -> any Encodable {
    try await environment.answer(to: .hello, from: options.app)
  }
}
