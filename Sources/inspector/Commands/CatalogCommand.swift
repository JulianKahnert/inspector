import ArgumentParser
import InspectorKit

/// `inspector catalog`: every registered action with the payload schema it accepts.
struct CatalogCommand: InspectorCommand {
  static let configuration = CommandConfiguration(
    commandName: "catalog",
    abstract: "Lists every registered action with the payload schema it accepts.")

  @OptionGroup var options: AppOptions

  func answer(in environment: Environment) async throws(InspectorError) -> any Encodable {
    try await environment.answer(to: .catalog, from: options.app)
  }
}
