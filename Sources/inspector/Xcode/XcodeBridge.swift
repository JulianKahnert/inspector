import Foundation
import InspectorKit

/// One connection to Xcode's tools through `xcrun mcpbridge`: `initialize`, the tool calls, then
/// the bridge exits.
///
/// A device interaction session outlives the connection that started it, so every CLI call opens
/// its own and no process stays behind.
final class XcodeBridge {
  private let process: any BridgeProcess
  private var replies: AsyncThrowingStream<String, any Error>.Iterator
  private var nextID = 1

  private init(process: any BridgeProcess) {
    self.process = process
    replies = process.lines.makeAsyncIterator()
  }

  /// Starts a bridge with `launch`, initializes it, runs `body` with it and lets the bridge exit,
  /// whether `body` succeeds or not.
  ///
  /// - Throws: ``ErrorCode/timeout`` when the bridge does not answer `initialize` within
  ///   `initializeTimeout`, ``ErrorCode/xcodeTooOld`` when the selected Xcode has no `mcpbridge`,
  ///   ``ErrorCode/xcodeError`` when the bridge exits early, and whatever `body` throws.
  static func connect<T>(
    launch: () throws(InspectorError) -> any BridgeProcess,
    initializeTimeout: Duration = .seconds(10),
    _ body: (XcodeBridge) async throws(InspectorError) -> T
  ) async throws(InspectorError) -> T {
    let bridge = XcodeBridge(process: try launch())
    do throws(InspectorError) {
      let id = try bridge.send(
        "initialize",
        params: .object([
          "protocolVersion": "2025-03-26",
          "capabilities": .object([:]),
          "clientInfo": .object(["name": "inspector", "version": "1"]),
        ]))
      _ = try await bridge.reply(to: id, within: initializeTimeout, for: "initialize")
      try bridge.notify("notifications/initialized")
      let result = try await body(bridge)
      _ = await bridge.process.finish()
      return result
    } catch {
      _ = await bridge.process.finish()
      throw error
    }
  }

  /// Calls `tool` with `arguments` and returns its result.
  ///
  /// - Throws: ``ErrorCode/notApproved`` when Xcode has not approved this binary,
  ///   ``ErrorCode/xcodeError`` with Xcode's text when the tool fails, and ``ErrorCode/timeout``
  ///   when it does not answer within `timeout`.
  func call(
    _ tool: String, _ arguments: [String: JSONValue], timeout: Duration = .seconds(30)
  ) async throws(InspectorError) -> ToolResult {
    let id = try send("tools/call", params: .object(["name": .string(tool), "arguments": .object(arguments)]))
    let reply = try await reply(to: id, within: timeout, for: tool)
    if let error = reply["error"] {
      throw Self.failure(of: tool, text: error.objectValue?["message"]?.stringValue ?? WireJSON.line(error))
    }
    let result = reply["result"]?.objectValue ?? [:]
    let text = (result["content"]?.arrayValue ?? []).compactMap { $0.objectValue?["text"]?.stringValue }
      .joined(separator: "\n")
    if result["isError"]?.boolValue == true { throw Self.failure(of: tool, text: text) }
    return ToolResult(text: text, structured: result["structuredContent"])
  }

  /// A failed tool call as the error a caller branches on.
  private static func failure(of tool: String, text: String) -> InspectorError {
    // Xcode answers every tool call this way until a human approves the binary in its dialog;
    // calling again cannot change that.
    if text.contains("isn't approved") {
      return InspectorError(
        code: .notApproved,
        message: """
          Xcode has not approved this inspector binary; a human confirms Xcode's dialog that asks to \
          allow `\(signingIdentifier)`
          """,
        detail: text)
    }
    return InspectorError(code: .xcodeError, message: "`\(tool)` failed: \(text)", detail: text)
  }

  /// The identifier `inspector.sh` signs the binary with; Xcode's approval names it.
  static let signingIdentifier = "de.juliankahnert.inspector"

  // MARK: - JSON-RPC

  private func send(_ method: String, params: JSONValue) throws(InspectorError) -> Int {
    let id = nextID
    nextID += 1
    try write(.object(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params]))
    return id
  }

  private func notify(_ method: String) throws(InspectorError) {
    try write(.object(["jsonrpc": "2.0", "method": .string(method)]))
  }

  private func write(_ message: JSONValue) throws(InspectorError) {
    do {
      try process.send(WireJSON.line(message))
    } catch {
      throw InspectorError(code: .xcodeError, message: "could not write to `xcrun mcpbridge`", detail: "\(error)")
    }
  }

  /// The response with `id`, skipping notifications and anything else the bridge prints.
  private func reply(
    to id: Int, within timeout: Duration, for what: String
  ) async throws(InspectorError) -> [String: JSONValue] {
    let process = self.process
    let deadline = Task {
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return false
      }
      process.terminate()
      return true
    }
    defer { deadline.cancel() }
    do {
      while let line = try await replies.next(isolation: nil) {
        // A line that is not a JSON object, or answers another id, is not this reply.
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)).objectValue,
          message["id"] == .int(id)
        else { continue }
        return message
      }
    } catch {
      throw InspectorError(code: .xcodeError, message: "could not read from `xcrun mcpbridge`", detail: "\(error)")
    }
    deadline.cancel()
    if await deadline.value {
      let seconds = timeout / .seconds(1)
      let shown = seconds.rounded() == seconds ? "\(Int(seconds))" : "\(seconds)"
      throw InspectorError(code: .timeout, message: "Xcode did not answer `\(what)` within \(shown) s")
    }
    throw Self.exitedEarly(stderr: await process.finish())
  }

  /// The error for a bridge that exited before it answered.
  private static func exitedEarly(stderr: String) -> InspectorError {
    let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    // `xcrun` reports a tool the selected Xcode does not have this way, before any JSON.
    if detail.contains("unable to find utility") {
      return InspectorError(
        code: .xcodeTooOld, message: "the selected Xcode has no `mcpbridge`; select Xcode 27.2 or newer",
        detail: detail)
    }
    return InspectorError(code: .xcodeError, message: "`xcrun mcpbridge` exited before it answered", detail: detail)
  }
}

/// What a tool returned.
struct ToolResult: Equatable, Sendable {
  /// The text of its content, one line per content item.
  var text: String
  /// Its `structuredContent`, when it has one.
  var structured: JSONValue?

  /// The text as JSON: Xcode's tools answer with a JSON document as text; anything else is a
  /// string.
  var json: JSONValue {
    (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
  }
}
