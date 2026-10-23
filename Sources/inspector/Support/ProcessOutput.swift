import Foundation
import InspectorKit

/// How a program the CLI ran ended: its exit status and what it printed.
struct ProcessOutput: Equatable, Sendable {
  var status: Int32
  var stdout = ""
  var stderr = ""

  /// Runs `command` to its end; `command[0]` is the program's absolute path, so no shell or
  /// `PATH` lookup is involved.
  ///
  /// - Throws: ``ErrorCode/badRequest`` when the program cannot be started.
  static func run(_ command: [String]) async throws(InspectorError) -> ProcessOutput {
    let process = Process()
    process.executableURL = URL(filePath: command[0])
    process.arguments = Array(command.dropFirst())
    let output = Pipe()
    let errorOutput = Pipe()
    process.standardOutput = output
    process.standardError = errorOutput
    process.standardInput = FileHandle.nullDevice
    let (exited, exit) = AsyncStream<Void>.makeStream()
    process.terminationHandler = { _ in exit.finish() }
    do {
      try process.run()
    } catch {
      throw InspectorError(
        code: .badRequest, message: "could not start `\(command.joined(separator: " "))`", detail: "\(error)")
    }
    let stdout = PipeReader(output.fileHandleForReading)
    let stderr = PipeReader(errorOutput.fileHandleForReading)
    for await _ in exited {}
    async let outText = stdout.text(waitingAtMost: Self.pipeGrace)
    async let errorText = stderr.text(waitingAtMost: Self.pipeGrace)
    return ProcessOutput(status: process.terminationStatus, stdout: await outText, stderr: await errorText)
  }

  /// How long the pipes may stay open after the program exited; its own output is complete by
  /// then, and only a child it left running holds a pipe longer.
  static let pipeGrace: Duration = .seconds(1)
}
