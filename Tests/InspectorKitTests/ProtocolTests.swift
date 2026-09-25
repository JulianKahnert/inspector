import Foundation
import Testing

@testable import InspectorKit

@Suite("Protocol")
struct ProtocolTests {
  @Test("An object renders its members in sorted order, whatever order they were built in")
  func objectKeysAreSorted() {
    let object = JSONValue.object(["b": 3, "a": 2])
    #expect(WireJSON.line(object) == #"{"a":2,"b":3}"#)
  }

  @Test("Quotes, backslashes, newlines and control characters are escaped, slashes are not")
  func stringEscaping() {
    let control = String(UnicodeScalar(1))
    #expect(WireJSON.line(JSONValue.string("a\"b")) == #""a\"b""#)
    #expect(WireJSON.line(JSONValue.string("a\\b")) == #""a\\b""#)
    #expect(WireJSON.line(JSONValue.string("a\nb")) == #""a\nb""#)
    #expect(WireJSON.line(JSONValue.string(control)) == "\"\\u0001\"")
    #expect(WireJSON.line(JSONValue.string("/tmp/inspector")) == #""/tmp/inspector""#)
  }

  @Test("A number no JSON can hold renders as null instead of failing the document")
  func nonFiniteNumbers() {
    #expect(WireJSON.line(JSONValue.object(["a": .double(.infinity), "b": .double(.nan)])) == #"{"a":null,"b":null}"#)
  }

  @Test("Decoding distinguishes booleans, integers and doubles")
  func decoding() throws {
    let data = Data(#"{"a":true,"b":3,"c":3.5,"d":null,"e":["x"]}"#.utf8)
    let object = try #require(JSONDecoder().decode(JSONValue.self, from: data).objectValue)
    #expect(object["a"] == .bool(true))
    #expect(object["b"] == .int(3))
    #expect(object["c"] == .double(3.5))
    #expect(object["d"] == .null)
    #expect(object["e"] == .array(["x"]))
  }

  @Test("A number outside Int's range is no integer, and reading it never traps")
  func integersOutsideRange() {
    #expect(JSONValue.double(3).intValue == 3)
    #expect(JSONValue.double(3.5).intValue == nil)
    #expect(JSONValue.double(1e20).intValue == nil)
    #expect(JSONValue.double(Double("1e400")!).intValue == nil)
    #expect(JSONValue.double(-1e20).intValue == nil)
  }

  @Test("A diff reports the changed leaves, additions and removals")
  func diff() {
    let old = JSONValue.object(["a": 1, "b": .object(["c": "x"]), "d": 0])
    let new = JSONValue.object(["a": 2, "b": .object(["c": "y"]), "e": 9])
    #expect(
      jsonDiff(old, new) == [
        JSONDiffEntry(path: "a", old: 1, new: 2),
        JSONDiffEntry(path: "b.c", old: "x", new: "y"),
        JSONDiffEntry(path: "d", old: 0, new: nil),
        JSONDiffEntry(path: "e", old: nil, new: 9),
      ]
    )
  }

  @Test("A diff of arrays reports index changes and length changes")
  func arrayDiff() {
    #expect(
      jsonDiff(.array([1, 2]), .array([1, 3, 4])) == [
        JSONDiffEntry(path: "[1]", old: 2, new: 3),
        JSONDiffEntry(path: "[2]", old: nil, new: 4),
      ]
    )
  }

  @Test("Equal documents diff to nothing")
  func emptyDiff() {
    let value = JSONValue.object(["a": 1])
    #expect(jsonDiff(value, value).isEmpty)
  }

  @Test("A schema decodes from the line the app writes")
  func schemaRoundTrip() throws {
    let schemas: [TypeSchema] = [
      .bool, .int, .double, .string, .url, .uuid, .date,
      .optional(of: .int),
      .array(of: .string),
      .enumeration(values: ["free", "pro"]),
      .rawValue(raw: .string),
      .decodable(type: "Filter"),
      .tuple(fields: [TupleField(label: "old", schema: .string)], input: .object),
      .opaque(type: "Document"),
    ]
    for schema in schemas {
      let data = Data(WireJSON.line(schema).utf8)
      #expect(try JSONDecoder().decode(TypeSchema.self, from: data) == schema)
    }
  }
}
