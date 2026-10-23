import ArgumentParser
import InspectorKit

/// The `inspector` command line: parses the arguments, runs one command and prints its outcome.
///
/// A new command is one file under `Commands/` that conforms to ``InspectorCommand``, plus its
/// entry in `subcommands` below.
@main
struct InspectorCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "inspector",
    abstract: "Reads the state of a running app and sends it actions.",
    discussion: """
      Every answer is one JSON document on stdout with sorted keys. A failure is one JSON line \
      with a `code` on stderr and exit code 1; a usage error exits with 64.
      """,
    subcommands: [
      AppsCommand.self,
      HelloCommand.self,
      CatalogCommand.self,
      StateCommand.self,
      SendCommand.self,
      WaitCommand.self,
      InitCommand.self,
      EndCommand.self,
    ])

  @OptionGroup var options: AppOptions

  /// Runs the command `CommandLine.arguments` names against the apps on the network and exits
  /// with its exit code.
  static func main() async {
    await outcome(of: Array(CommandLine.arguments.dropFirst()), in: .live).write()
  }

  /// What running `arguments` against `environment` prints and how it exits.
  ///
  /// The one way into the CLI, so a test sees exactly what a caller sees.
  static func outcome(of arguments: [String], in environment: Environment) async -> Outcome {
    let parsed: any ParsableCommand
    do {
      parsed = try parseAsRoot(arguments)
    } catch {
      return usage(error)
    }
    guard let command = parsed as? any InspectorCommand else {
      if parsed is InspectorCLI { return usage(ValidationError("Missing a command.")) }
      // `--help` and `help` parse to ArgumentParser's own help command, whose `run()` throws the
      // help text as a clean exit.
      do {
        var builtIn = parsed
        try builtIn.run()
        return Outcome(stdout: "", stderr: "", exitCode: 0)
      } catch {
        return usage(error)
      }
    }
    var environment = environment
    let substitutions = Substitutions()
    environment.substitutions = substitutions
    let start = environment.now()
    var folder: InspectorFolder?
    let outcome: Outcome
    do throws(InspectorError) {
      if type(of: command).isLoopStep { folder = try environment.folder() }
      outcome = .answer(substitutions.mask(answer: try await command.answer(in: environment)))
    } catch {
      outcome = .failure(substitutions.mask(error))
    }
    // `init` creates the folder; its step belongs in it like any other.
    if folder == nil, type(of: command).isLoopStep { folder = try? environment.folder() }
    // The step happened whether or not run.json can be written; failing now would hide its answer.
    try? folder?.recordStep(
      command: type(of: command).configuration.commandName ?? "", arguments: arguments.map(substitutions.mask),
      at: start)
    return outcome
  }

  /// ArgumentParser's message for a parse error or a help request: help goes to stdout with exit
  /// code 0, a usage error to stderr with 64.
  private static func usage(_ error: any Error) -> Outcome {
    let exitCode = exitCode(for: error).rawValue
    var message = fullMessage(for: error)
    if !message.isEmpty, !message.hasSuffix("\n") { message += "\n" }
    return exitCode == 0
      ? Outcome(stdout: message, stderr: "", exitCode: exitCode)
      : Outcome(stdout: "", stderr: message, exitCode: exitCode)
  }
}
