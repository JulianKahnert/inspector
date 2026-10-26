import Foundation
import Testing

@testable import inspector

@Suite("Reading a program's pipe")
struct PipeReaderTests {
  @Test("a pipe that ends gives everything written to it")
  func pipeThatEnds() async throws {
    let pipe = Pipe()
    let reader = PipeReader(pipe.fileHandleForReading)
    try pipe.fileHandleForWriting.write(contentsOf: Data("one\ntwo\n".utf8))
    try pipe.fileHandleForWriting.close()

    #expect(await reader.text(waitingAtMost: .seconds(60)) == "one\ntwo\n")
  }

  @Test("a pipe a program's child keeps open gives what arrived once the grace passed")
  func pipeKeptOpen() async throws {
    let pipe = Pipe()
    let reader = PipeReader(pipe.fileHandleForReading)
    let writer = pipe.fileHandleForWriting
    try writer.write(contentsOf: Data("partial".utf8))
    // Closes the pipe in any case, so a missing bound shows as a failure instead of a hang.
    let rescue = Task {
      try? await Task.sleep(for: .seconds(5))
      try? writer.close()
    }

    let started = ContinuousClock.now
    let text = await reader.text(waitingAtMost: .milliseconds(50))

    #expect(ContinuousClock.now - started < .seconds(3))
    #expect(text == "partial")
    rescue.cancel()
    try? writer.close()
  }
}
