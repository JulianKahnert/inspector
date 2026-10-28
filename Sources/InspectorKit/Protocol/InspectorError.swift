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
  /// A condition did not hold before its timeout; ``InspectorError/detail`` carries the last
  /// state checked, as one line of JSON.
  case expectationFailed = "EXPECTATION_FAILED"
  /// The call needs the `.inspector/` folder and there is none; ``InspectorError/detail`` is the
  /// path where it was expected.
  case noConfig = "NO_CONFIG"
  /// A payload names `${NAME}` and `.inspector/.env` has no value for it;
  /// ``InspectorError/detail`` lists the missing names.
  case envMissing = "ENV_MISSING"
  /// The Xcode device interaction session in `.inspector/config.json` has ended, and the app it
  /// started with it.
  case noSession = "NO_SESSION"
  /// Xcode has not approved this `inspector` binary for its tools; a human confirms Xcode's
  /// dialog, calling again changes nothing.
  case notApproved = "NOT_APPROVED"
  /// The selected Xcode has no `mcpbridge`.
  case xcodeTooOld = "XCODE_TOO_OLD"
  /// One of Xcode's tools failed; the message quotes Xcode's text, ``InspectorError/detail`` is
  /// that text alone.
  case xcodeError = "XCODE_ERROR"
  /// A capture came back without the screen's hierarchy; ``InspectorError/detail`` is Xcode's
  /// answer.
  case noHierarchy = "NO_HIERARCHY"
  /// No target on the screen has the identifier or label asked for; ``InspectorError/detail``
  /// lists every target, as one line of JSON.
  case targetNotFound = "TARGET_NOT_FOUND"
  /// Targets at more than one point have the identifier or label asked for;
  /// ``InspectorError/detail`` lists them, as one line of JSON.
  case targetAmbiguous = "TARGET_AMBIGUOUS"
  /// Several simulators are booted and nothing names the one to run on; ``InspectorError/detail``
  /// lists them, as one line of JSON.
  case deviceAmbiguous = "DEVICE_AMBIGUOUS"
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
