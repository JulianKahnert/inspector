extension JSONValue {
  /// Whether `match` is contained in this value: the rule a `wait` or a send's `until` checks.
  ///
  /// - An object matches an object that has every one of its keys, each value matching in turn.
  ///   Keys are taken as written, so `"settings.detail"` names one top-level key, never a path.
  /// - An empty object matches any value, so `{"key":{}}` asks only for `key` to exist.
  /// - An array matches an array that starts with matching elements, so `[]` matches any array.
  /// - A scalar matches only the same scalar; numbers compare by value, so `1` matches `1.0`.
  ///
  /// There are no operators: a condition beyond containment is a shell filter on `inspector state`.
  public func contains(_ match: JSONValue) -> Bool {
    switch (self, match) {
    case (_, .object(let expected)) where expected.isEmpty:
      return true
    case (.object(let actual), .object(let expected)):
      return expected.allSatisfy { key, value in actual[key]?.contains(value) ?? false }
    case (.array(let actual), .array(let expected)):
      return expected.count <= actual.count && zip(actual, expected).allSatisfy { $0.contains($1) }
    case (.int, .double), (.double, .int), (.double, .double):
      return doubleValue == match.doubleValue
    default:
      return self == match
    }
  }
}
