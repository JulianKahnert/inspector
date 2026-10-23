import Foundation
import Synchronization
import Testing

@testable import InspectorKit
@testable import inspector

/// Xcode's tools behind `xcrun mcpbridge`, in-process: every bridge launched from it answers
/// `initialize` and hands each tool call to `reply`.
final class FakeXcode: Sendable {
  /// What a tool call gets back.
  enum Reply: Sendable {
    /// A result whose content is `text`.
    case text(String)
    /// A result with `isError: true` and `text` as its content.
    case error(String)
    /// No answer at all.
    case silence
  }

  /// One tool call as the bridge received it.
  struct Call: Equatable, Sendable {
    var tool: String
    var arguments: [String: JSONValue]
  }

  let reply: @Sendable (Call) -> Reply
  private let bridges = Mutex<[FakeBridge]>([])

  init(reply: @escaping @Sendable (Call) -> Reply) {
    self.reply = reply
  }

  /// Every tool call, across all bridges, in order.
  var calls: [Call] {
    bridges.withLock { $0.flatMap(\.calls) }
  }

  /// Every bridge launched so far.
  var launched: [FakeBridge] {
    bridges.withLock { $0 }
  }

  /// `app`'s environment, or one where no app serves, with its bridges launched here.
  func environment(serving app: Environment? = nil) -> Environment {
    var environment = app ?? Environment(transport: { _ in NoApp() }, instanceNames: { _ in [] })
    environment.launchBridge = { self.launch() }
    return environment
  }

  /// Launches a new bridge; what ``Environment/launchBridge`` does in a test.
  func launch() -> any BridgeProcess {
    let reply = self.reply
    let bridge = FakeBridge { request in
      switch request["method"]?.stringValue {
      case "initialize":
        return .object([
          "protocolVersion": "2025-03-26", "serverInfo": .object(["name": "xcode-tools", "version": "1"]),
        ])
      case "tools/call":
        let call = Call(
          tool: request["params"]?["name"]?.stringValue ?? "",
          arguments: request["params"]?["arguments"]?.objectValue ?? [:])
        switch reply(call) {
        case .text(let text): return .object(["content": .array([.object(["type": "text", "text": .string(text)])])])
        case .error(let text):
          return .object(["content": .array([.object(["type": "text", "text": .string(text)])]), "isError": true])
        case .silence: return nil
        }
      default:
        return nil
      }
    }
    bridges.withLock { $0.append(bridge) }
    return bridge
  }
}

/// One `xcrun mcpbridge` stand-in: records every JSON-RPC message it is sent and answers a request
/// with the result `answer` returns for it, or not at all for `nil`.
final class FakeBridge: BridgeProcess {
  let lines: AsyncThrowingStream<String, any Error>
  private let output: AsyncThrowingStream<String, any Error>.Continuation
  private let answer: @Sendable (JSONValue) -> JSONValue?
  private let stderr: String
  private let state = Mutex(State())

  private struct State {
    var received: [JSONValue] = []
    var terminated = false
    var finished = false
  }

  /// A bridge that answers requests with `answer`; `stderr` is what it reports when it finishes.
  init(stderr: String = "", answer: @escaping @Sendable (JSONValue) -> JSONValue?) {
    (lines, output) = AsyncThrowingStream.makeStream()
    self.answer = answer
    self.stderr = stderr
  }

  /// A bridge that exits at once, having written `stderr`, as `xcrun` does for a missing tool.
  static func exited(stderr: String) -> FakeBridge {
    let bridge = FakeBridge(stderr: stderr) { _ in nil }
    bridge.output.finish()
    return bridge
  }

  /// Every message sent to the bridge, in order.
  var received: [JSONValue] { state.withLock { $0.received } }

  /// The tool calls among ``received``.
  var calls: [FakeXcode.Call] {
    received.filter { $0["method"] == "tools/call" }.map {
      FakeXcode.Call(
        tool: $0["params"]?["name"]?.stringValue ?? "", arguments: $0["params"]?["arguments"]?.objectValue ?? [:])
    }
  }

  /// Whether the bridge was killed.
  var wasTerminated: Bool { state.withLock { $0.terminated } }

  /// Whether the client closed the bridge's stdin and waited for it.
  var wasFinished: Bool { state.withLock { $0.finished } }

  func send(_ line: String) throws {
    let message = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    state.withLock { $0.received.append(message) }
    guard let id = message["id"], let result = answer(message) else { return }
    output.yield(WireJSON.line(JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result])))
  }

  func terminate() {
    state.withLock { $0.terminated = true }
    output.finish()
  }

  func finish() async -> String {
    state.withLock { $0.finished = true }
    output.finish()
    return stderr
  }
}

/// A transport that finds no serving app, like Bonjour after the app died.
struct NoApp: InspectorTransport {
  func serve(_ handle: @escaping @Sendable (Request) async -> Response) async throws {}

  func send(_ request: Request) async throws -> Response {
    throw InspectorError(code: .appNotFound, message: "no serving app found")
  }
}

extension JSONValue {
  /// The member `key` of an object; `nil` for anything else.
  subscript(key: String) -> JSONValue? {
    objectValue?[key]
  }
}
