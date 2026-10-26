import Foundation
import InspectorKit
import Synchronization

/// The standard input and output of one `xcrun mcpbridge` process, the seam a test fakes.
protocol BridgeProcess: Sendable {
  /// The lines the bridge writes to stdout; the sequence ends when the bridge exits.
  var lines: AsyncThrowingStream<String, any Error> { get }

  /// Writes `line` and a newline to the bridge's stdin.
  func send(_ line: String) throws

  /// Kills the bridge at once and ends ``lines``.
  func terminate()

  /// Closes stdin, waits for the bridge to exit and returns what it wrote to stderr.
  func finish() async -> String
}

/// `xcrun mcpbridge`, started as a direct child of this process.
///
/// Xcode approves the bridge's parent process by its signature, so the bridge must not run under
/// a shell or another interpreter.
final class BridgeSubprocess: BridgeProcess {
  let lines: AsyncThrowingStream<String, any Error>
  private let linesEnd: AsyncThrowingStream<String, any Error>.Continuation
  private let process = Process()
  private let input = Pipe()
  private let exited: AsyncStream<Void>
  private let errors: PipeReader

  /// Starts the bridge.
  ///
  /// - Throws: ``ErrorCode/xcodeError`` when `xcrun` itself cannot be started.
  init() throws(InspectorError) {
    Self.failWritesInsteadOfSignalling(input.fileHandleForWriting)
    let output = Pipe()
    let errorOutput = Pipe()
    process.executableURL = URL(filePath: "/usr/bin/xcrun")
    process.arguments = ["mcpbridge"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errorOutput
    let (exited, exit) = AsyncStream<Void>.makeStream()
    self.exited = exited
    process.terminationHandler = { _ in exit.finish() }
    let (lines, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
    self.lines = lines
    linesEnd = continuation
    errors = PipeReader(errorOutput.fileHandleForReading)
    do {
      try process.run()
    } catch {
      throw InspectorError(code: .xcodeError, message: "could not start `xcrun mcpbridge`", detail: "\(error)")
    }
    // Not `FileHandle.bytes`: on a pipe it holds a short reply back until the bridge exits.
    // A lock, not an actor: `readabilityHandler` is a synchronous callback, and each chunk has to
    // join the buffer before the next one arrives.
    let pending = Mutex(Data())
    output.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        continuation.finish()
        return
      }
      let complete = pending.withLock { buffer in
        buffer.append(data)
        guard let end = buffer.lastIndex(of: UInt8(ascii: "\n")) else { return Data() }
        defer { buffer.removeSubrange(...end) }
        return Data(buffer[...end])
      }
      for line in complete.split(separator: UInt8(ascii: "\n")) {
        continuation.yield(String(decoding: line, as: UTF8.self))
      }
    }
  }

  func send(_ line: String) throws {
    try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
  }

  func terminate() {
    kill(process.processIdentifier, SIGKILL)
    // A child of the bridge may hold its stdout open; the caller waits for no further line.
    linesEnd.finish()
  }

  func finish() async -> String {
    // Closing fails only when the bridge already exited, which is what this waits for anyway.
    try? input.fileHandleForWriting.close()
    // The bridge exits about 0.1 s after stdin closes.
    let pid = process.processIdentifier
    await Self.awaitExit(
      exited, patience: .seconds(2), terminate: { kill(pid, SIGTERM) }, kill: { kill(pid, SIGKILL) })
    return await errors.text(waitingAtMost: ProcessOutput.pipeGrace)
  }

  /// Waits until `exited` ends; a process still running after `patience` gets `terminate`, and
  /// one still running after another `patience` gets `kill`, which no process can ignore.
  static func awaitExit(
    _ exited: AsyncStream<Void>, patience: Duration, terminate: @escaping @Sendable () -> Void,
    kill: @escaping @Sendable () -> Void
  ) async {
    let deadline = Task {
      do {
        try await Task.sleep(for: patience)
        terminate()
        try await Task.sleep(for: patience)
        kill()
      } catch {}
    }
    for await _ in exited {}
    deadline.cancel()
  }

  /// Makes a write to `handle` fail with `EPIPE` once its reader is gone, instead of raising
  /// `SIGPIPE`, which would end this process; for this pipe only, so the process keeps its default.
  static func failWritesInsteadOfSignalling(_ handle: FileHandle) {
    _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
  }
}
