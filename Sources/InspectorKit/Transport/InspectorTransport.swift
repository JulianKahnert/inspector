/// How a request reaches a running app and its response finds the way back.
///
/// Carries a ``Request`` one way and a ``Response`` the other. ``BonjourTransport`` is the one
/// this package ships; a different transport only has to carry the same two messages, and nothing
/// above it changes.
public protocol InspectorTransport: Sendable {
  /// Answers every incoming request with `handle` until the surrounding task is cancelled.
  ///
  /// The app side.
  func serve(_ handle: @escaping @Sendable (Request) async -> Response) async throws

  /// Sends one request to a serving app and waits for its response.
  ///
  /// The CLI side.
  func send(_ request: Request) async throws -> Response
}
