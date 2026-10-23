import Foundation
import InspectorKit
import Synchronization

/// The standard input and output of one `xcrun mcpbridge` process, the seam a test fakes.
protocol BridgeProcess: Sendable {
  /// The lines the bridge writes to stdout; the sequence ends when the bridge exits.
  var lines: AsyncThrowingStream<String, any Error> { get }

  /// Writes `line` and a newline to the bridge's stdin.
  func send(_ line: String) throws

  /// Kills the bridge at once; ``lines`` ends with it.
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
  private let process = Process()
  private let input = Pipe()
  private let exited: AsyncStream<Void>
  private let errors: Task<String, Never>

  /// Starts the bridge.
  ///
  /// - Throws: ``ErrorCode/xcodeError`` when `xcrun` itself cannot be started.
  init() throws(InspectorError) {
    // A write to a bridge that already exited must fail as an error, not end this process.
    signal(SIGPIPE, SIG_IGN)
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
    do {
      try process.run()
    } catch {
      throw InspectorError(code: .xcodeError, message: "could not start `xcrun mcpbridge`", detail: "\(error)")
    }
    let (lines, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
    self.lines = lines
    // Not `FileHandle.bytes`: on a pipe it holds a short reply back until the bridge exits.
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
    errors = Task {
      var text: [UInt8] = []
      do {
        for try await byte in errorOutput.fileHandleForReading.bytes { text.append(byte) }
      } catch {
        text.append(contentsOf: Array("\n(stderr unreadable: \(error))".utf8))
      }
      return String(decoding: text, as: UTF8.self)
    }
  }

  func send(_ line: String) throws {
    try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
  }

  func terminate() {
    process.terminate()
  }

  func finish() async -> String {
    // Closing fails only when the bridge already exited, which is what this waits for anyway.
    try? input.fileHandleForWriting.close()
    // The bridge exits about 0.1 s after stdin closes; one that does not is killed.
    let deadline = Task { [process] in
      try await Task.sleep(for: .seconds(2))
      process.terminate()
    }
    for await _ in exited {}
    deadline.cancel()
    return await errors.value
  }
}
