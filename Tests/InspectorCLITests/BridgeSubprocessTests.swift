import Foundation
import Synchronization
import Testing

@testable import inspector

@Suite("Ending the bridge process")
struct BridgeSubprocessTests {
  @Test("a bridge that exits on its own is neither asked to stop nor killed")
  func exitsOnItsOwn() async {
    let (exited, exit) = AsyncStream<Void>.makeStream()
    let signals = Signals()
    exit.finish()

    await BridgeSubprocess.awaitExit(
      exited, patience: .seconds(60), terminate: { signals.append("TERM") }, kill: { signals.append("KILL") })

    #expect(signals.sent == [])
  }

  @Test("a bridge that ignores SIGTERM is killed once the patience ran out a second time")
  func killedWhenItIgnoresTerminate() async {
    let (exited, exit) = AsyncStream<Void>.makeStream()
    let signals = Signals()
    // Ends the wait in any case, so a missing SIGKILL shows as a failure instead of a hang.
    let rescue = Task {
      try? await Task.sleep(for: .seconds(5))
      exit.finish()
    }

    await BridgeSubprocess.awaitExit(
      exited, patience: .milliseconds(10),
      terminate: { signals.append("TERM") },
      kill: {
        signals.append("KILL")
        exit.finish()
      })

    #expect(signals.sent == ["TERM", "KILL"])
    rescue.cancel()
  }

  @Test("a write to a bridge that closed its stdin fails as an error instead of ending this process")
  func writeAfterTheBridgeClosedStdin() throws {
    let pipe = Pipe()
    BridgeSubprocess.failWritesInsteadOfSignalling(pipe.fileHandleForWriting)
    try pipe.fileHandleForReading.close()

    #expect(throws: (any Error).self) { try pipe.fileHandleForWriting.write(contentsOf: Data("{}\n".utf8)) }
  }
}

/// The signals sent to a process, in order.
private final class Signals: Sendable {
  private let names = Mutex<[String]>([])

  var sent: [String] { names.withLock { $0 } }

  func append(_ name: String) {
    names.withLock { $0.append(name) }
  }
}
