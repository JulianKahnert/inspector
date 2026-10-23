import Foundation
import InspectorKit
import Synchronization

/// The `.env` values one call filled into `${NAME}` placeholders.
///
/// Whatever the call prints or writes shows each of them as `${NAME}` again: the answer on stdout,
/// the error on stderr and `run.json`. Only these values are masked; the CLI guesses nothing from
/// key names.
final class Substitutions: Sendable {
  private let values = Mutex<[String: String]>([:])

  /// Notes the values a call filled in, by name.
  func record(_ filled: [String: String]) {
    values.withLock { $0.merge(filled) { _, new in new } }
  }

  /// `text` with every filled-in value replaced by its `${NAME}`.
  ///
  /// One pass, longest value first; a `${NAME}` already in the text stays as it is, so a value
  /// that happens to be part of a placeholder does not garble it.
  func mask(_ text: String) -> String {
    let tokens = maskingTokens()
    guard !tokens.isEmpty else { return text }
    let scalars = Array(text.unicodeScalars)
    var masked = String.UnicodeScalarView()
    var index = 0
    scan: while index < scalars.count {
      for token in tokens where scalars[index...].starts(with: token.match) {
        masked.append(contentsOf: token.replacement)
        index += token.match.count
        continue scan
      }
      masked.append(scalars[index])
      index += 1
    }
    return String(masked)
  }

  /// `value` with every filled-in value masked: inside strings and keys, and a number or boolean
  /// that equals one becomes the string `${NAME}`.
  func mask(_ value: JSONValue) -> JSONValue {
    switch value {
    case .null:
      return .null
    case .string(let text):
      return .string(mask(text))
    case .array(let elements):
      return .array(elements.map(mask))
    case .object(let members):
      return .object(Dictionary(members.map { (mask($0.key), mask($0.value)) }) { first, _ in first })
    case .bool, .int, .double:
      let text = WireJSON.line(value)
      let name = values.withLock { values in values.filter { $0.value == text }.keys.min() }
      return name.map { .string("${\($0)}") } ?? value
    }
  }

  /// An answer with every filled-in value masked; unchanged when nothing was filled in.
  func mask(answer: any Encodable) -> any Encodable {
    guard !values.withLock(\.isEmpty),
      let json = try? JSONDecoder().decode(JSONValue.self, from: Data(WireJSON.line(answer).utf8))
    else { return answer }
    return mask(json)
  }

  /// An error with every filled-in value masked in its message, detail and suggestions.
  func mask(_ error: InspectorError) -> InspectorError {
    InspectorError(
      code: error.code, message: mask(error.message), detail: error.detail.map(mask),
      didYouMean: error.didYouMean.map(mask))
  }

  /// What a masking pass looks for, longest first: every value, replaced by its placeholder, and
  /// every placeholder, kept as it is.
  private func maskingTokens() -> [(match: [Unicode.Scalar], replacement: [Unicode.Scalar])] {
    let filled = values.withLock { $0 }.sorted { $0.key < $1.key }
    var tokens: [(match: [Unicode.Scalar], replacement: [Unicode.Scalar])] = []
    for (name, value) in filled {
      let placeholder = Array("${\(name)}".unicodeScalars)
      tokens.append((placeholder, placeholder))
      if !value.isEmpty { tokens.append((Array(value.unicodeScalars), placeholder)) }
    }
    // Stable, so of two names with the same value the first in alphabetical order wins.
    return tokens.enumerated()
      .sorted { ($0.element.match.count, $1.offset) > ($1.element.match.count, $0.offset) }
      .map(\.element)
  }
}

/// `${NAME}` placeholders: a letter or underscore, then letters, digits and underscores.
enum Placeholders {
  // A computed property: `Regex` is not `Sendable`, so it cannot be a shared constant.
  private static var pattern: Regex<(Substring, Substring)> { #/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/# }

  /// The names in `text`, each once, in order of appearance.
  static func names(in text: String) -> [String] {
    var names: [String] = []
    for match in text.matches(of: pattern) where !names.contains(String(match.output.1)) {
      names.append(String(match.output.1))
    }
    return names
  }

  /// `text` with each placeholder replaced by its value in `values`; one without a value stays.
  static func fill(_ text: String, from values: [String: String]) -> String {
    text.replacing(pattern) { match in values[String(match.output.1)] ?? String(match.output.0) }
  }
}

extension JSONValue {
  /// This value with `transform` applied to every string and key in it.
  func mappingStrings(_ transform: (String) -> String) -> JSONValue {
    switch self {
    case .string(let text):
      return .string(transform(text))
    case .array(let elements):
      return .array(elements.map { $0.mappingStrings(transform) })
    case .object(let members):
      return .object(
        Dictionary(members.map { (transform($0.key), $0.value.mappingStrings(transform)) }) { first, _ in first })
    case .null, .bool, .int, .double:
      return self
    }
  }
}

/// `.inspector/.env`: one `NAME=value` per line.
///
/// Blank lines and `#` comments are skipped, an `export ` prefix is allowed, and a value in
/// matching single or double quotes loses them. Nothing is expanded inside a value.
enum DotEnv {
  /// The values in `text`, by name; a later line wins over an earlier one.
  static func parse(_ text: String) -> [String: String] {
    var values: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      var entry = line.trimmingCharacters(in: .whitespaces)
      guard !entry.isEmpty, !entry.hasPrefix("#") else { continue }
      if entry.hasPrefix("export ") { entry = String(entry.dropFirst("export ".count)) }
      guard let equals = entry.firstIndex(of: "=") else { continue }
      let name = entry[..<equals].trimmingCharacters(in: .whitespaces)
      var value = entry[entry.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
        value = String(value.dropFirst().dropLast())
      }
      values[name] = value
    }
    return values
  }
}
