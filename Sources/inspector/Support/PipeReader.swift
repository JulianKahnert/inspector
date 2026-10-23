import Foundation

/// What a program writes to one pipe, read as it arrives so a full pipe never blocks the program.
///
/// Never `readDataToEndOfFile`: it blocks a thread and ignores cancellation, and a child of the
/// program that inherited the pipe keeps it open after the program exited.
struct PipeReader: Sendable {
  private let chunks: AsyncStream<Data>
  private let end: AsyncStream<Data>.Continuation

  /// Starts reading `handle`.
  init(_ handle: FileHandle) {
    (chunks, end) = AsyncStream<Data>.makeStream()
    let end = end
    handle.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty { end.finish() } else { end.yield(data) }
    }
    end.onTermination = { _ in handle.readabilityHandler = nil }
  }

  /// Everything written to the pipe until its end, or until `grace` passed: once the program
  /// exited, what a child still writes later is not its output.
  func text(waitingAtMost grace: Duration) async -> String {
    let end = end
    let deadline = Task {
      do {
        try await Task.sleep(for: grace)
      } catch {
        return
      }
      end.finish()
    }
    defer { deadline.cancel() }
    var data = Data()
    for await chunk in chunks { data.append(chunk) }
    return String(decoding: data, as: UTF8.self)
  }
}
