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
  /// The full instance name the app was reached under, such as `DemoHost @ Mac`.
  ///
  /// The app never sets it: the CLI's transport fills it in with the name it connected to, so
  /// a caller can store it and select exactly this app later. `nil` from a transport without
  /// instance names.
  public var instance: String?
  /// The app's process identifier.
  public var pid: Int
  /// The name of the conformer answering.
  ///
  /// See ``Inspectable/name``.
  public var provider: String

  /// Creates a hello answer.
  public init(app: String, instance: String? = nil, pid: Int, provider: String) {
    self.app = app
    self.instance = instance
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
  /// A match document the state has to contain before the send answers; `nil` answers once the
  /// action settled.
  ///
  /// See ``WaitRequest/until`` for the rule.
  public var until: JSONValue?
  /// How long ``until`` may take to hold after the action settled, in milliseconds; `nil` waits
  /// 3 seconds.
  public var untilTimeoutMs: Int?

  /// Creates a send request.
  public init(
    path: String,
    payload: JSONValue? = nil,
    timeoutMs: Int? = nil,
    until: JSONValue? = nil,
    untilTimeoutMs: Int? = nil
  ) {
    self.path = path
    self.payload = payload
    self.timeoutMs = timeoutMs
    self.until = until
    self.untilTimeoutMs = untilTimeoutMs
  }
}

extension SendRequest: Codable {
  private enum CodingKeys: String, CodingKey { case path, payload, timeoutMs, until, untilTimeoutMs }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(path, forKey: .path)
    // `encodeIfPresent` drops an absent payload and writes a `.null` one as null — an action with
    // no payload leaves the key out entirely, one that takes `Int?` can still send null.
    try container.encodeIfPresent(payload, forKey: .payload)
    try container.encodeIfPresent(timeoutMs, forKey: .timeoutMs)
    try container.encodeIfPresent(until, forKey: .until)
    try container.encodeIfPresent(untilTimeoutMs, forKey: .untilTimeoutMs)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    path = try container.decode(String.self, forKey: .path)
    // `decodeIfPresent` cannot tell `"payload": null` from a missing key, and the two mean
    // different things: an action with no payload has no key, one that takes `Int?` can send null.
    payload = container.contains(.payload) ? try container.decode(JSONValue.self, forKey: .payload) : nil
    timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs)
    until = try container.decodeIfPresent(JSONValue.self, forKey: .until)
    untilTimeoutMs = try container.decodeIfPresent(Int.self, forKey: .untilTimeoutMs)
  }
}

/// A condition to wait for: a match document the state has to contain.
public struct WaitRequest: Codable, Equatable, Sendable {
  /// The match document.
  ///
  /// An object matches when the state has each of its keys with a matching value, an empty
  /// object matches any value so `{"key":{}}` only asks for the key, an array matches as a
  /// prefix, and a scalar matches only itself. Keys are taken as written, never as paths.
  public var until: JSONValue
  /// How long the condition may take to hold, in milliseconds; `nil` waits 3 seconds.
  public var timeoutMs: Int?
  /// The state to diff the answer against, such as the state a caller read before its own step;
  /// `nil` diffs against the state when the wait began.
  public var baseline: JSONValue?

  /// Creates a wait request.
  public init(until: JSONValue, timeoutMs: Int? = nil, baseline: JSONValue? = nil) {
    self.until = until
    self.timeoutMs = timeoutMs
    self.baseline = baseline
  }
}

// MARK: - Result

/// What came of a send or a wait: the new state, the change it caused, and whether it settled.
public struct SendResult: Codable, Equatable, Sendable {
  /// Whether every effect the action started finished before the timeout; always `true` for a wait.
  public var settled: Bool
  /// The whole state after the action, or once the condition held.
  public var state: JSONValue
  /// The state change between before the action, or the wait's baseline, and ``state``.
  public var diff: [JSONDiffEntry]

  /// Creates a send result.
  public init(settled: Bool, state: JSONValue, diff: [JSONDiffEntry]) {
    self.settled = settled
    self.state = state
    self.diff = diff
  }
}
