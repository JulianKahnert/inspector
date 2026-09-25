import Foundation

/// Answers every request against one inspectable conformer.
///
/// Builds `hello`, forwards `catalog` and `state` to the ``Inspectable``, and turns a `send` into a
/// before/after diff.
actor InspectorCore {
  private let provider: any Inspectable
  private let app: String
  private let defaultTimeout: Duration

  /// How long a send waits for its effects when the request names no `timeoutMs`.
  static let defaultSettleTimeout: Duration = .seconds(5)

  init(
    provider: any Inspectable,
    app: String,
    defaultTimeout: Duration = InspectorCore.defaultSettleTimeout
  ) {
    self.provider = provider
    self.app = app
    self.defaultTimeout = defaultTimeout
  }

  func handle(_ request: Request) async -> Response {
    do {
      switch request {
      case .hello:
        return .hello(Hello(app: app, pid: Int(ProcessInfo.processInfo.processIdentifier), provider: provider.name))
      case .catalog:
        return .catalog(await provider.catalog())
      case .state(let path):
        return .state(try await state(path: path))
      case .send(let sendRequest):
        return .sendResult(try await send(sendRequest))
      }
    } catch let error as InspectorError {
      return .error(error)
    } catch {
      return .error(InspectorError(code: .badRequest, message: "request failed", detail: "\(error)"))
    }
  }

  func send(_ request: SendRequest) async throws -> SendResult {
    let before = try await provider.state()
    let timeout = request.timeoutMs.map { Duration.milliseconds($0) } ?? defaultTimeout
    let settled = try await provider.perform(path: request.path, payload: request.payload, timeout: timeout)
    let after = try await provider.state()
    return SendResult(settled: settled, state: after, diff: jsonDiff(before, after))
  }

  func state(path: String?) async throws -> JSONValue {
    let value = try await provider.state()
    guard let path, !path.isEmpty else { return value }
    let segments = path.split(separator: ".").map(String.init)
    return try select(value, remaining: segments, fullPath: path)
  }

  private func select(_ value: JSONValue, remaining: [String], fullPath: String) throws -> JSONValue {
    guard let segment = remaining.first else { return value }
    let rest = Array(remaining.dropFirst())
    if let index = Int(segment), let array = value.arrayValue, array.indices.contains(index) {
      return try select(array[index], remaining: rest, fullPath: fullPath)
    }
    if let object = value.objectValue, let child = object[segment] {
      return try select(child, remaining: rest, fullPath: fullPath)
    }
    throw InspectorError(code: .unknownStatePath, message: "no state at `\(fullPath)`")
  }
}
