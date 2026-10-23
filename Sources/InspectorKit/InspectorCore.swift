import Foundation

/// A provider that reports every registration and every cancelled one, so a condition waiting
/// in the app is checked again at once instead of on the next tick.
protocol RegistrationObserving: Inspectable {
  /// Calls `onChange` after every change to the registered readers or actions, until the
  /// returned token is cancelled.
  func observeRegistrations(_ onChange: @escaping @Sendable () -> Void) -> Registration
}

extension Inspector: RegistrationObserving {}

/// Answers every request against one inspectable conformer.
///
/// Builds `hello`, forwards `catalog` and `state` to the ``Inspectable``, turns a `send` into a
/// before/after diff, and checks a condition inside the app until it holds.
actor InspectorCore {
  private let provider: any Inspectable
  private let app: String
  private let defaultTimeout: Duration
  private let tick: Duration

  /// How long a send waits for its effects when the request names no `timeoutMs`.
  static let defaultSettleTimeout: Duration = .seconds(5)

  /// How long a condition may take to hold when the request names no timeout.
  static let defaultConditionTimeout: Duration = .seconds(3)

  /// How often a waiting condition is checked when no registration changed in between.
  ///
  /// A state change inside a registered value has no signal of its own, so it is found on the
  /// next tick; 25 ms is short against a screen transition and cheap against the state readers.
  static let defaultTick: Duration = .milliseconds(25)

  init(
    provider: any Inspectable,
    app: String,
    defaultTimeout: Duration = InspectorCore.defaultSettleTimeout,
    tick: Duration = InspectorCore.defaultTick
  ) {
    self.provider = provider
    self.app = app
    self.defaultTimeout = defaultTimeout
    self.tick = tick
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
      case .wait(let waitRequest):
        return .sendResult(try await wait(waitRequest))
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
    let after: JSONValue
    if let match = request.until {
      after = try await state(containing: match, timeoutMs: request.untilTimeoutMs)
    } else {
      after = try await provider.state()
    }
    return SendResult(settled: settled, state: after, diff: jsonDiff(before, after))
  }

  func wait(_ request: WaitRequest) async throws -> SendResult {
    var start = request.baseline
    let state = try await state(containing: request.until, timeoutMs: request.timeoutMs) { first in
      if start == nil { start = first }
    }
    return SendResult(settled: true, state: state, diff: jsonDiff(start ?? state, state))
  }

  /// The first state that contains `match`, checked at once, after every registration change and
  /// on every tick.
  ///
  /// - Parameter onFirstCheck: Receives the state of the first check.
  /// - Throws: ``ErrorCode/expectationFailed`` with the last state checked once the timeout
  ///   passed, or whatever reading the state throws.
  private func state(
    containing match: JSONValue,
    timeoutMs: Int?,
    onFirstCheck: (JSONValue) -> Void = { _ in }
  ) async throws -> JSONValue {
    let timeout = timeoutMs.map { Duration.milliseconds($0) } ?? Self.defaultConditionTimeout
    let deadline = ContinuousClock.now + timeout
    let (checks, check) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    // Observing starts before the first check, so a registration during that check is not lost.
    let observation = (provider as? any RegistrationObserving)?.observeRegistrations { check.yield() }
    defer { observation?.cancel() }

    return try await withThrowingTaskGroup { group in
      group.addTask { [tick] in
        while true {
          try await Task.sleep(for: tick)
          check.yield()
        }
      }
      group.addTask {
        try await Task.sleep(until: deadline)
        check.yield()
      }
      defer { group.cancelAll() }

      var state = try await provider.state()
      onFirstCheck(state)
      var pending = checks.makeAsyncIterator()
      while !state.contains(match) {
        guard ContinuousClock.now < deadline else {
          throw InspectorError(
            code: .expectationFailed,
            message: "`\(WireJSON.line(match))` did not hold within \(timeout.milliseconds) ms",
            detail: WireJSON.line(state))
        }
        await pending.next()
        state = try await provider.state()
      }
      return state
    }
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

extension Duration {
  /// The whole milliseconds, for messages that name a timeout the way the request did.
  fileprivate var milliseconds: Int64 {
    components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
  }
}
