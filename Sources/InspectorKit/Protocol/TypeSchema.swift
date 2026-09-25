/// What an action payload accepts, as published by `inspector catalog` and consumed by `inspector send`.
///
/// The schema is the whole contract an agent has for building a payload: there is no second,
/// undocumented way to pass a value.
public indirect enum TypeSchema: Equatable, Sendable {
  /// A JSON boolean.
  case bool
  /// A JSON number without a fractional part.
  case int
  /// Any JSON number.
  case double
  /// A JSON string.
  case string
  /// A string holding a URL.
  case url
  /// A string holding a UUID.
  case uuid
  /// A string holding an ISO 8601 date.
  case date
  /// The wrapped schema, or `null`.
  case optional(of: TypeSchema)
  /// An array whose elements all match the element schema.
  case array(of: TypeSchema)
  /// A closed set of case names; the input is one of `values`.
  case enumeration(values: [String])
  /// A value of the raw type, such as a raw-value enum's `String` or `Int`.
  case rawValue(raw: TypeSchema)
  /// JSON that decodes to the named Swift type; the schema says nothing more about its shape.
  case decodable(type: String)
  /// Several values, passed as an object keyed by label or as an array in order.
  case tuple(fields: [TupleField], input: TupleInput)
  /// No way to build this type from JSON; the owning action cannot be sent.
  case opaque(type: String)
}

/// One element of a tuple schema.
///
/// See ``TypeSchema/tuple(fields:input:)``.
public struct TupleField: Equatable, Sendable, Codable {
  /// The element's label, used as the object key when the input is an object.
  public var label: String?
  /// What the element accepts.
  public var schema: TypeSchema

  /// Creates a tuple element.
  public init(label: String?, schema: TypeSchema) {
    self.label = label
    self.schema = schema
  }
}

/// How a tuple payload is passed.
public enum TupleInput: String, Equatable, Sendable, Codable {
  /// As an object keyed by each field's label.
  case object
  /// As an array, one element per field in order.
  case array
}

extension TypeSchema {
  /// Caller-facing name of the expected input, used in `PAYLOAD_TYPE_MISMATCH` messages.
  public var displayName: String {
    switch self {
    case .bool: return "boolean"
    case .int: return "integer"
    case .double: return "number"
    case .string: return "string"
    case .url: return "URL string"
    case .uuid: return "UUID string"
    case .date: return "ISO 8601 date string"
    case .optional(let wrapped): return "\(wrapped.displayName) or null"
    case .array(let element): return "array of \(element.displayName)"
    case .enumeration(let values): return "one of \(values.joined(separator: ", "))"
    case .rawValue(let raw): return "raw \(raw.displayName)"
    case .decodable(let type): return "JSON for \(type)"
    case .tuple(_, let input): return input == .object ? "object" : "array"
    case .opaque(let type): return type
    }
  }
}

// MARK: - Codable

extension TypeSchema: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, of, values, raw, type, fields, input
  }

  var kind: String {
    switch self {
    case .bool: return "bool"
    case .int: return "int"
    case .double: return "double"
    case .string: return "string"
    case .url: return "url"
    case .uuid: return "uuid"
    case .date: return "date"
    case .optional: return "optional"
    case .array: return "array"
    case .enumeration: return "enum"
    case .rawValue: return "rawValue"
    case .decodable: return "decodable"
    case .tuple: return "tuple"
    case .opaque: return "opaque"
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    switch self {
    case .bool, .int, .double, .string, .url, .uuid, .date:
      break
    case .optional(let wrapped), .array(let wrapped):
      try container.encode(wrapped, forKey: .of)
    case .enumeration(let values):
      try container.encode(values, forKey: .values)
    case .rawValue(let raw):
      try container.encode(raw, forKey: .raw)
    case .decodable(let type), .opaque(let type):
      try container.encode(type, forKey: .type)
    case .tuple(let fields, let input):
      try container.encode(fields, forKey: .fields)
      try container.encode(input, forKey: .input)
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    switch kind {
    case "bool": self = .bool
    case "int": self = .int
    case "double": self = .double
    case "string": self = .string
    case "url": self = .url
    case "uuid": self = .uuid
    case "date": self = .date
    case "optional": self = .optional(of: try container.decode(TypeSchema.self, forKey: .of))
    case "array": self = .array(of: try container.decode(TypeSchema.self, forKey: .of))
    case "enum": self = .enumeration(values: try container.decode([String].self, forKey: .values))
    case "rawValue": self = .rawValue(raw: try container.decode(TypeSchema.self, forKey: .raw))
    case "decodable": self = .decodable(type: try container.decode(String.self, forKey: .type))
    case "tuple":
      self = .tuple(
        fields: try container.decode([TupleField].self, forKey: .fields),
        input: try container.decode(TupleInput.self, forKey: .input)
      )
    case "opaque": self = .opaque(type: try container.decode(String.self, forKey: .type))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: container, debugDescription: "unknown schema kind \(kind)")
    }
  }
}
