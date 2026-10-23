import Foundation
import Testing

@testable import InspectorKit

@Suite("Match document")
struct MatchTests {
  private let state: JSONValue = .object([
    "counter": 42,
    "ratio": .double(0.5),
    "title": "Inbox",
    "isLoading": false,
    "selection": .null,
    "settings.detail": .object(["isLoading": false, "rows": .array(["a", "b", "c"])]),
  ])

  @Test(
    "A match holds when every member it names is in the state with a matching value",
    arguments: [
      #"{"counter":42}"#,
      #"{"counter":42,"title":"Inbox"}"#,
      #"{"ratio":0.5}"#,
      #"{"isLoading":false}"#,
      #"{"selection":null}"#,
      #"{"settings.detail":{"isLoading":false}}"#,
      #"{}"#,
    ])
  func holds(match: String) throws {
    #expect(state.contains(try JSONValue(parsing: match)))
  }

  @Test(
    "An empty object only asks for the key to exist, whatever its value",
    arguments: [
      #"{"counter":{}}"#, #"{"title":{}}"#, #"{"selection":{}}"#, #"{"settings.detail":{}}"#,
      #"{"settings.detail":{"rows":{}}}"#,
    ])
  func emptyObjectIsExistence(match: String) throws {
    #expect(state.contains(try JSONValue(parsing: match)))
  }

  @Test("An empty object does not hold for a missing key")
  func emptyObjectMissingKey() throws {
    #expect(!state.contains(try JSONValue(parsing: #"{"readings":{}}"#)))
  }

  @Test(
    "An array matches the state's array as a prefix",
    arguments: [
      (#"{"settings.detail":{"rows":[]}}"#, true),
      (#"{"settings.detail":{"rows":["a"]}}"#, true),
      (#"{"settings.detail":{"rows":["a","b","c"]}}"#, true),
      (#"{"settings.detail":{"rows":["b"]}}"#, false),
      (#"{"settings.detail":{"rows":["a","b","c","d"]}}"#, false),
      (#"{"title":[]}"#, false),
    ])
  func arrayPrefix(match: String, holds: Bool) throws {
    #expect(state.contains(try JSONValue(parsing: match)) == holds)
  }

  @Test(
    "A scalar matches only the exact same value",
    arguments: [
      #"{"counter":41}"#, #"{"counter":"42"}"#, #"{"title":"inbox"}"#, #"{"isLoading":0}"#,
      #"{"isLoading":null}"#, #"{"selection":false}"#, #"{"counter":null}"#, #"{"missing":null}"#,
      #"{"settings.detail":{"isLoading":true}}"#, #"{"settings":{"detail":{}}}"#,
    ])
  func scalarExact(match: String) throws {
    #expect(!state.contains(try JSONValue(parsing: match)))
  }

  @Test("A whole number matches an integer and a double of the same value alike")
  func numbersCompareByValue() throws {
    #expect(state.contains(try JSONValue(parsing: #"{"counter":42.0}"#)))
    #expect(JSONValue.object(["ratio": .double(2)]).contains(try JSONValue(parsing: #"{"ratio":2}"#)))
  }

  @Test("Arrays match element by element, so an object inside an array matches by containment too")
  func nestedArrayElements() throws {
    let list: JSONValue = .object(["items": .array([.object(["id": 1, "name": "a"]), .object(["id": 2])])])
    #expect(list.contains(try JSONValue(parsing: #"{"items":[{"id":1}]}"#)))
    #expect(!list.contains(try JSONValue(parsing: #"{"items":[{"id":2}]}"#)))
  }
}

extension JSONValue {
  /// The JSON document `text` holds, as the CLI parses a match argument.
  fileprivate init(parsing text: String) throws {
    self = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }
}
