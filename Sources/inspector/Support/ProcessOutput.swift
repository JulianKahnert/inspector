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
    // Read both pipes while the program runs, so a full pipe never blocks it.
    async let stdout = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
    async let stderr = Task.detached { errorOutput.fileHandleForReading.readDataToEndOfFile() }.value
    let (outData, errorData) = await (stdout, stderr)
    for await _ in exited {}
    return ProcessOutput(
      status: process.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
      stderr: String(decoding: errorData, as: UTF8.self))
  }
}
