import Foundation

/// A payload type that describes its own wire shape for the catalog.
///
/// Without a conformance, a registered action's payload is listed as
/// ``TypeSchema/decodable(type:)``, which names the Swift type but tells a caller nothing about the
/// JSON it expects. The common Foundation types, `Optional` and `Array` conform already.
public protocol SchemaDescribable {
  /// The schema listed in the catalog for this type.
  static var schema: TypeSchema { get }
}

extension Bool: SchemaDescribable { public static var schema: TypeSchema { .bool } }
extension Int: SchemaDescribable { public static var schema: TypeSchema { .int } }
extension Double: SchemaDescribable { public static var schema: TypeSchema { .double } }
extension String: SchemaDescribable { public static var schema: TypeSchema { .string } }
extension URL: SchemaDescribable { public static var schema: TypeSchema { .url } }
extension UUID: SchemaDescribable { public static var schema: TypeSchema { .uuid } }
extension Date: SchemaDescribable { public static var schema: TypeSchema { .date } }

extension Optional: SchemaDescribable where Wrapped: SchemaDescribable {
  public static var schema: TypeSchema { .optional(of: Wrapped.schema) }
}

extension Array: SchemaDescribable where Element: SchemaDescribable {
  public static var schema: TypeSchema { .array(of: Element.schema) }
}
