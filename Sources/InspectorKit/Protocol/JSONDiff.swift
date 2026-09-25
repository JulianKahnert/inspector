/// One changed leaf between two JSON documents.
public struct JSONDiffEntry: Codable, Equatable, Sendable {
  /// The leaf's dotted path; an array index appears as `[n]`.
  public var path: String
  /// The value before; `nil` when the key did not exist yet.
  public var old: JSONValue?
  /// The value after; `nil` when the key no longer exists.
  public var new: JSONValue?

  /// Creates a diff entry.
  public init(path: String, old: JSONValue?, new: JSONValue?) {
    self.path = path
    self.old = old
    self.new = new
  }

  private enum CodingKeys: String, CodingKey { case path, old, new }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(path, forKey: .path)
    // An absent side means the key did not exist, a `null` side that it did and was null;
    // `encodeIfPresent` writes exactly that difference.
    try container.encodeIfPresent(old, forKey: .old)
    try container.encodeIfPresent(new, forKey: .new)
  }

  // An absent side means the key did not exist; a `null` side means it did and was null. Only
  // `contains` tells the two apart — `decodeIfPresent` answers nil for both.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    path = try container.decode(String.self, forKey: .path)
    old = container.contains(.old) ? try container.decode(JSONValue.self, forKey: .old) : nil
    new = container.contains(.new) ? try container.decode(JSONValue.self, forKey: .new) : nil
  }
}

/// Recursive diff of two JSON documents, reported as the changed leaves in key order.
///
/// A key present on only one side is reported with the other side absent, so an added and a
/// nulled-out field stay distinguishable.
func jsonDiff(_ old: JSONValue, _ new: JSONValue) -> [JSONDiffEntry] {
  var entries: [JSONDiffEntry] = []
  diff(old, new, path: "", into: &entries)
  return entries
}

private func diff(_ old: JSONValue, _ new: JSONValue, path: String, into entries: inout [JSONDiffEntry]) {
  if old == new { return }
  switch (old, new) {
  case (.object(let oldObject), .object(let newObject)):
    // Sorted, because an object has no order of its own and two diffs of the same change have to
    // come out identical.
    for (key, oldValue) in oldObject.sorted(by: { $0.key < $1.key }) {
      let child = join(path, key)
      if let newValue = newObject[key] {
        diff(oldValue, newValue, path: child, into: &entries)
      } else {
        entries.append(JSONDiffEntry(path: child, old: oldValue, new: nil))
      }
    }
    for (key, newValue) in newObject.sorted(by: { $0.key < $1.key }) where oldObject[key] == nil {
      entries.append(JSONDiffEntry(path: join(path, key), old: nil, new: newValue))
    }
  case (.array(let oldElements), .array(let newElements)):
    for index in 0..<Swift.max(oldElements.count, newElements.count) {
      let child = "\(path)[\(index)]"
      switch (index < oldElements.count, index < newElements.count) {
      case (true, true):
        diff(oldElements[index], newElements[index], path: child, into: &entries)
      case (true, false):
        entries.append(JSONDiffEntry(path: child, old: oldElements[index], new: nil))
      case (false, true):
        entries.append(JSONDiffEntry(path: child, old: nil, new: newElements[index]))
      case (false, false):
        break
      }
    }
  default:
    entries.append(JSONDiffEntry(path: path, old: old, new: new))
  }
}

private func join(_ path: String, _ key: String) -> String {
  path.isEmpty ? key : "\(path).\(key)"
}
