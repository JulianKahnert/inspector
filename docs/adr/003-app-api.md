# App API: the app side is defined by `Inspectable`

This ADR defines the app side of inspector through `Inspectable`, the protocol for anything whose state the CLI reads and whose actions it sends.

## The API

`Inspectable`, as declared in `Sources/InspectorKit/Inspectable.swift`:

```swift
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
```

`Inspector` is the built-in conformer: an app or a feature package registers state readers and actions on `Inspector.shared` and serves them. A framework integration is another conformer outside this package, deriving the catalog and the state from the framework's own types.

## Open questions

- Whether to add opt-in helpers that do nothing without `DEBUG`, and in what shape ([ADR 002](002-no-debug-release-decision.md)).
- Whether the app reports its own events, such as navigation or errors. Today the CLI sees only state and the diff of each action it sends, so such events would need a way to reach the CLI.
