import ArgumentParser
import InspectorKit

/// One `inspector` subcommand.
///
/// A command only computes its answer; ``InspectorCLI/outcome(of:in:)`` prints it as one JSON
/// document, or the thrown error as one JSON line on stderr.
protocol InspectorCommand: ParsableCommand {
  /// The JSON document this command answers with.
  ///
  /// - Throws: the ``InspectorError`` the call ends with.
  func answer(in environment: Environment) async throws(InspectorError) -> any Encodable
}

/// The options every command takes.
///
/// ``InspectorCLI`` declares them too, so they stand before or after the command name; the
/// command's own copy receives the value either way.
struct AppOptions: ParsableArguments {
  @Option(
    help: ArgumentHelp(
      """
      The app, by its full instance name `<app> @ <device>` or its `<app>` part. Without it, a \
      command works only while exactly one app serves.
      """,
      valueName: "name"))
  var app: String?
}
