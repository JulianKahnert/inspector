import Foundation

/// A JSON document: what the state encoder builds and what travels the wire.
///
/// Numbers keep the Swift type they came from — an `Int` renders as `0`, never as `0.0` — because
/// the value is read back by an agent that branches on it.
public enum JSONValue: Codable, Equatable, Sendable {
  /// JSON `null`.
  case null
  /// `true` or `false`.
  case bool(Bool)
  /// A number without a fractional part that fits in `Int`.
  case int(Int)
  /// Any other number; a non-finite value encodes as `null`.
  case double(Double)
  /// A string.
  case string(String)
  /// An ordered list.
  case array([JSONValue])
  /// Members by key; they encode in sorted key order.
  case object([String: JSONValue])
}

extension JSONValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
  public init(booleanLiteral value: Bool) { self = .bool(value) }
}

// MARK: - Accessors

extension JSONValue {
  /// The string, or `nil` for any other kind of value.
  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  /// The number as an `Int`, or `nil` for a non-number or a number without an exact `Int` value.
  public var intValue: Int? {
    switch self {
    case .int(let value): return value
    // `Int(exactly:)`, never `Int(_:)`: the latter traps on ±inf and on anything past Int.max,
    // both of which arrive from the wire as a Double.
    case .double(let value): return Int(exactly: value)
    default: return nil
    }
  }

  /// The number as a `Double`, or `nil` for a non-number.
  public var doubleValue: Double? {
    switch self {
    case .int(let value): return Double(value)
    case .double(let value): return value
    default: return nil
    }
  }

  /// The boolean, or `nil` for any other kind of value.
  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  /// The elements, or `nil` for any other kind of value.
  public var arrayValue: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  /// The members, or `nil` for any other kind of value.
  public var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  /// Whether the value is JSON `null`.
  public var isNull: Bool { self == .null }

  /// The JSON type name, for error messages that quote what was received.
  public var typeName: String {
    switch self {
    case .null: return "null"
    case .bool: return "boolean"
    case .int, .double: return "number"
    case .string: return "string"
    case .array: return "array"
    case .object: return "object"
    }
  }
}

// MARK: - Codable

extension JSONValue {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .int(let value):
      try container.encode(value)
    case .double(let value):
      // `JSONEncoder` refuses a non-finite number outright; the rest of the state dump is worth
      // more than the one field, so it renders as null.
      if value.isFinite {
        try container.encode(value)
      } else {
        try container.encodeNil()
      }
    case .string(let value):
      try container.encode(value)
    case .array(let values):
      try container.encode(values)
    case .object(let members):
      try container.encode(members)
    }
  }
}

// MARK: - Serialization

/// The one way anything in this package becomes JSON text.
public enum WireJSON {
  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    // Sorted keys make two dumps of the same value byte-identical, which is what a diff between
    // them rests on; unescaped slashes keep file paths readable.
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  /// One line of JSON, keys in alphabetical order.
  ///
  /// Cannot fail for what travels here — the only value `JSONEncoder` rejects is a non-finite
  /// `Double`, which ``JSONValue`` already writes as null — and a debugging tool must not take the
  /// app down over a document it could not render.
  public static func line(_ value: some Encodable) -> String {
    guard let data = try? encoder.encode(value) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }
}
