import ArgumentParser
import InspectorKit

/// `inspector state [path]`: the whole state, or the subtree at a dotted path.
struct StateCommand: InspectorCommand {
  static let configuration = CommandConfiguration(
    commandName: "state",
    abstract: "Prints the whole state, or the subtree at a dotted path.")

  @OptionGroup var options: AppOptions

  @Argument(help: "A dotted path into the state, such as `settings.detail`; an index selects an array element.")
  var path: String?

  func answer(in environment: Environment) async throws(InspectorError) -> any Encodable {
    try await environment.answer(to: .state(path: path), from: options.app)
  }
}
