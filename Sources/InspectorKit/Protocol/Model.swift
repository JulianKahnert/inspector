import Foundation

/// One action in the catalog.
public struct ActionNode: Codable, Equatable, Sendable {
  /// The dotted address `inspector send` takes.
  public var path: String
  /// The payload the action accepts; `nil` for an action that takes none.
  public var payload: TypeSchema?

  /// Creates a catalog entry.
  public init(path: String, payload: TypeSchema? = nil) {
    self.path = path
    self.payload = payload
  }
}

/// Every action that can currently be sent.
///
/// The list is flat; a path's dotted segments carry its nesting.
public struct Catalog: Codable, Equatable, Sendable {
  /// The actions, one per path.
  public var actions: [ActionNode]

  /// Creates a catalog.
  public init(actions: [ActionNode]) {
    self.actions = actions
  }
}

/// Which app answered, and what is answering inside it.
public struct Hello: Codable, Equatable, Sendable {
  /// The name the app passed to `serve`.
  public var app: String
  /// The app's process identifier.
  public var pid: Int
  /// The name of the conformer answering.
  ///
  /// See ``Inspectable/name``.
  public var provider: String

  /// Creates a hello answer.
  public init(app: String, pid: Int, provider: String) {
    self.app = app
    self.pid = pid
    self.provider = provider
  }
}

// MARK: - Requests

/// The action to send: its path and payload.
public struct SendRequest: Equatable, Sendable {
  /// The action's dotted path, as listed in the catalog.
  public var path: String
  /// The payload; nil sends none, a null value sends an explicit null.
  public var payload: JSONValue?
  /// How long to wait for the action's effects to settle, in milliseconds; `nil` waits 5 seconds.
  public var timeoutMs: Int?

  /// Creates a send request.
  public init(path: String, payload: JSONValue? = nil, timeoutMs: Int? = nil) {
    self.path = path
    self.payload = payload
    self.timeoutMs = timeoutMs
  }
}

extension SendRequest: Codable {
  private enum CodingKeys: String, CodingKey { case path, payload, timeoutMs }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(path, forKey: .path)
    // `encodeIfPresent` drops an absent payload and writes a `.null` one as null — an action with
    // no payload leaves the key out entirely, one that takes `Int?` can still send null.
    try container.encodeIfPresent(payload, forKey: .payload)
    try container.encodeIfPresent(timeoutMs, forKey: .timeoutMs)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    path = try container.decode(String.self, forKey: .path)
    // `decodeIfPresent` cannot tell `"payload": null` from a missing key, and the two mean
    // different things: an action with no payload has no key, one that takes `Int?` can send null.
    payload = container.contains(.payload) ? try container.decode(JSONValue.self, forKey: .payload) : nil
    timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs)
  }
}

// MARK: - Result

/// What came of a send: the new state, the change it caused, and whether it settled.
public struct SendResult: Codable, Equatable, Sendable {
  /// Whether every effect the action started finished before the timeout.
  public var settled: Bool
  /// The whole state after the action.
  public var state: JSONValue
  /// The state change between before and after the action.
  public var diff: [JSONDiffEntry]

  /// Creates a send result.
  public init(settled: Bool, state: JSONValue, diff: [JSONDiffEntry]) {
    self.settled = settled
    self.state = state
    self.diff = diff
  }
}
