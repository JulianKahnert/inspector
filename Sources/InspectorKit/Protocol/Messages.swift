/// One message from the CLI to the app, encoded as a flat JSON object tagged by `t`.
///
/// The whole wire protocol is this enum and ``Response``.
///
/// | Request | Answered with |
/// |---|---|
/// | `{"t":"hello"}` | `{"t":"hello","app","pid","provider"}` |
/// | `{"t":"catalog"}` | `{"t":"catalog","actions":[…]}` |
/// | `{"t":"state","path"?}` | `{"t":"state","state":…}` |
/// | `{"t":"send","path","payload"?,"timeoutMs"?}` | `{"t":"sendResult","settled","state","diff"}` |
///
/// Any of them can be answered with `{"t":"error","code","message","detail"?,"didYouMean"?}`
/// instead. Branch on ``InspectorError/code``, never on the message.
public enum Request: Equatable, Sendable {
  /// Asks which app this is, and what kind of provider is answering.
  case hello
  /// Asks for every registered action and its payload schema.
  case catalog
  /// Asks for the whole state, or the subtree at a dotted path.
  case state(path: String?)
  /// Builds an action from a dotted path and dispatches it.
  case send(SendRequest)
}

extension Request: Codable {
  private enum CodingKeys: String, CodingKey { case t, path }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .hello:
      try container.encode("hello", forKey: .t)
    case .catalog:
      try container.encode("catalog", forKey: .t)
    case .state(let path):
      try container.encode("state", forKey: .t)
      try container.encodeIfPresent(path, forKey: .path)
    case .send(let request):
      try container.encode("send", forKey: .t)
      try request.encode(to: encoder)
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .t) {
    case "hello": self = .hello
    case "catalog": self = .catalog
    case "state": self = .state(path: try container.decodeIfPresent(String.self, forKey: .path))
    case "send": self = .send(try SendRequest(from: decoder))
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .t, in: container, debugDescription: "unknown request type \(other)")
    }
  }
}

// MARK: - Response

/// The app's answer to one request, or a rejection in its place.
///
/// `hello`, `catalog`, `sendResult` and `error` inline their payload's members next to `t`
/// rather than nesting them, so the document stays flat.
public enum Response: Equatable, Sendable {
  /// The answer to a hello request.
  case hello(Hello)
  /// The answer to a catalog request.
  case catalog(Catalog)
  /// The answer to a state request: the whole state or the selected subtree.
  case state(JSONValue)
  /// The answer to a send request.
  case sendResult(SendResult)
  /// A rejection of any request.
  case error(InspectorError)
}

extension Response: Codable {
  private enum CodingKeys: String, CodingKey { case t, state }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .hello(let hello):
      try container.encode("hello", forKey: .t)
      try hello.encode(to: encoder)
    case .catalog(let catalog):
      try container.encode("catalog", forKey: .t)
      try catalog.encode(to: encoder)
    case .state(let state):
      try container.encode("state", forKey: .t)
      try container.encode(state, forKey: .state)
    case .sendResult(let result):
      try container.encode("sendResult", forKey: .t)
      try result.encode(to: encoder)
    case .error(let error):
      try container.encode("error", forKey: .t)
      try error.encode(to: encoder)
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .t) {
    case "hello": self = .hello(try Hello(from: decoder))
    case "catalog": self = .catalog(try Catalog(from: decoder))
    case "state": self = .state(try container.decode(JSONValue.self, forKey: .state))
    case "sendResult": self = .sendResult(try SendResult(from: decoder))
    case "error": self = .error(try InspectorError(from: decoder))
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .t, in: container, debugDescription: "unknown response type \(other)")
    }
  }
}
