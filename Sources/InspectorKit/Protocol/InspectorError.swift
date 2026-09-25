/// The machine-readable reason for a rejection; a caller branches on it, never on the message.
public enum ErrorCode: String, Codable, Equatable, Sendable {
  /// No action is registered at the sent path.
  ///
  /// ``InspectorError/didYouMean`` lists the registered paths closest to it.
  case unknownActionPath = "UNKNOWN_ACTION_PATH"
  /// The requested state path selects nothing in the current state.
  case unknownStatePath = "UNKNOWN_STATE_PATH"
  /// The payload is missing, present where none is taken, or does not decode to the action's type.
  case payloadTypeMismatch = "PAYLOAD_TYPE_MISMATCH"
  /// Anything else: an undecodable request, an unreachable app, or an error the app threw.
  case badRequest = "BAD_REQUEST"
  /// No serving app was found in time, or none matches the requested app name.
  case appNotFound = "APP_NOT_FOUND"
  /// Several serving apps match; ``InspectorError/detail`` lists their instance names.
  case ambiguousApp = "AMBIGUOUS_APP"
  /// The app was found but did not answer in time.
  case timeout = "TIMEOUT"
}

/// A rejection sent back in place of a normal response.
public struct InspectorError: Error, Equatable, Sendable {
  /// Why the request was rejected.
  public var code: ErrorCode
  /// Caller-facing prose; quotes what was received and what was expected.
  public var message: String
  /// The raw text of an underlying error, when there was one.
  public var detail: String?
  /// Registered paths close to the one sent.
  ///
  /// Filled for ``ErrorCode/unknownActionPath``, empty otherwise.
  public var didYouMean: [String]

  /// Creates a rejection.
  public init(
    code: ErrorCode,
    message: String,
    detail: String? = nil,
    didYouMean: [String] = []
  ) {
    self.code = code
    self.message = message
    self.detail = detail
    self.didYouMean = didYouMean
  }
}

// MARK: - Codable

extension InspectorError: Codable {
  private enum CodingKeys: String, CodingKey { case code, message, detail, didYouMean }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(code, forKey: .code)
    try container.encode(message, forKey: .message)
    try container.encodeIfPresent(detail, forKey: .detail)
    // Empty and absent both mean "no suggestions"; omitting the key keeps the common case terse.
    if !didYouMean.isEmpty {
      try container.encode(didYouMean, forKey: .didYouMean)
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try container.decode(ErrorCode.self, forKey: .code)
    message = try container.decode(String.self, forKey: .message)
    detail = try container.decodeIfPresent(String.self, forKey: .detail)
    didYouMean = try container.decodeIfPresent([String].self, forKey: .didYouMean) ?? []
  }
}
