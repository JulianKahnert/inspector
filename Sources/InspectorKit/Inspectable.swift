/// Something whose state can be read and whose actions can be sent from the command line.
///
/// ``Inspector`` is the built-in conformer: an app registers state readers and actions by hand. A
/// framework adapter is another conformer, deriving the catalog and the state from the framework's
/// own types. Either way the wire protocol and the CLI stay the same.
public protocol Inspectable: Sendable {
  /// The kind of conformer, reported to the CLI.
  ///
  /// Appears as ``Hello/provider``.
  var name: String { get }

  /// Every action that can currently be sent, with the payload each one accepts.
  func catalog() async -> Catalog

  /// The current state as one JSON document.
  ///
  /// Called before and after every send; the CLI's diff is the difference between the two.
  func state() async throws -> JSONValue

  /// Builds the action at a dotted path from a JSON payload and runs it.
  ///
  /// - Parameters:
  ///   - path: The action's address, as listed in ``catalog()``.
  ///   - payload: The payload as sent; `nil` when the request carried none, ``JSONValue/null``
  ///     when it carried an explicit `null`.
  ///   - timeout: How long to wait for the effects the action starts.
  /// - Returns: Whether every effect has settled by the time this returns. A conformer with no
  ///   notion of in-flight effects returns `true`.
  /// - Throws: ``InspectorError`` with ``ErrorCode/unknownActionPath`` or
  ///   ``ErrorCode/payloadTypeMismatch``; any other error reaches the CLI as
  ///   ``ErrorCode/badRequest``.
  func perform(path: String, payload: JSONValue?, timeout: Duration) async throws -> Bool
}
