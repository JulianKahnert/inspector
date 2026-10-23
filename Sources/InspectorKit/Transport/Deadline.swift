/// The value of `operation`, or `timeoutError` once `duration` passed first.
///
/// The loser is cancelled and left behind, never awaited: a task group would wait for an
/// operation that ignores cancellation, as Network's browser and connection can, and the bound
/// would not hold.
func withDeadline<Value: Sendable>(
  _ duration: Duration,
  orThrow timeoutError: InspectorError,
  _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  let (outcome, settle) = AsyncThrowingStream<Value, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
  let work = Task {
    do {
      settle.yield(try await operation())
      settle.finish()
    } catch {
      settle.finish(throwing: error)
    }
  }
  let timer = Task {
    do {
      try await Task.sleep(for: duration)
    } catch {
      return
    }
    settle.finish(throwing: timeoutError)
  }
  defer {
    work.cancel()
    timer.cancel()
  }
  // The first to settle the stream wins; whatever the other one does afterwards is dropped.
  for try await value in outcome { return value }
  // The stream ends without a value only when this task was cancelled.
  throw CancellationError()
}
