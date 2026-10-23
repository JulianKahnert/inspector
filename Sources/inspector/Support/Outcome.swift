import Foundation
import InspectorKit

/// What one CLI call prints and how it exits.
///
/// Every command ends in one of these shapes, so a caller can rely on them: an answer is exactly
/// one JSON document on stdout, a failure exactly one JSON line with a `code` on stderr.
struct Outcome: Equatable, Sendable {
  var stdout: String
  var stderr: String
  var exitCode: Int32

  /// One JSON document on stdout, keys sorted, exit code 0.
  static func answer(_ value: some Encodable) -> Outcome {
    Outcome(stdout: WireJSON.line(value) + "\n", stderr: "", exitCode: 0)
  }

  /// One JSON error line on stderr, exit code 1, so a calling agent branches on `code` instead of
  /// parsing prose.
  static func failure(_ error: InspectorError) -> Outcome {
    Outcome(stdout: "", stderr: WireJSON.line(error) + "\n", exitCode: 1)
  }

  /// Prints to the real stdout and stderr and ends the process with `exitCode`.
  func write() -> Never {
    FileHandle.standardOutput.write(Data(stdout.utf8))
    FileHandle.standardError.write(Data(stderr.utf8))
    exit(exitCode)
  }
}
