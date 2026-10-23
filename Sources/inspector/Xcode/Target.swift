import Foundation
import InspectorKit

/// An element on the screen an agent can tap or type into, as Xcode's hierarchy names it.
///
/// `capture` lists them so an agent finds what to tap without reading the whole hierarchy.
struct Target: Codable, Equatable, Sendable {
  /// The element type, such as `Button` or `TextField`.
  var type: String
  /// Its accessibility identifier.
  var identifier: String?
  /// Its accessibility label.
  var label: String?
  /// The placeholder of an empty text field.
  var placeholder: String?
  /// Its value: the text in a field, a picker's choice, a badge.
  var value: String?
  /// Where a tap reaches it, in points.
  var hitPoint: Point

  /// The targets in `hierarchy`, the text Xcode's device interaction tools write, in its order.
  ///
  /// A target is a control with something to know it by (identifier, label, value or
  /// placeholder), or a text input in any case. Containers, text, images and the keyboard's keys
  /// are left out: a control carries the label of the text and image inside it.
  static func list(inHierarchy hierarchy: String) -> [Target] {
    // `element` builds a new regex on each access; one per call compiles it once.
    let element = element
    return hierarchy.split(whereSeparator: \.isNewline).compactMap { target(in: $0, element) }
  }

  /// The one target in `targets` whose identifier or label is `name`.
  ///
  /// Matches at one point count as one: the hierarchy lists some elements twice.
  ///
  /// - Throws: ``ErrorCode/targetNotFound`` with every target in `detail`,
  ///   ``ErrorCode/targetAmbiguous`` with the matches in `detail`.
  static func resolve(_ name: String, in targets: [Target]) throws(InspectorError) -> Target {
    let matches = targets.filter { $0.identifier == name || $0.label == name }
    guard let first = matches.first else {
      throw InspectorError(
        code: .targetNotFound, message: "no target has the identifier or label `\(name)`",
        detail: WireJSON.line(targets))
    }
    guard matches.allSatisfy({ $0.hitPoint == first.hitPoint }) else {
      throw InspectorError(
        code: .targetAmbiguous, message: "\(matches.count) targets have the identifier or label `\(name)`",
        detail: WireJSON.line(matches))
    }
    return first
  }

  private static func target(in line: Substring, _ element: Element) -> Target? {
    // Most lines are containers and text; skipping them before the regex runs keeps a capture of a
    // busy screen from spending tens of milliseconds on it.
    let type = String(line.drop { $0 == " " }.prefix { $0 != "," })
    guard controls.contains(type), let match = try? element.wholeMatch(in: line),
      let x = Double(match.x), let y = Double(match.y)
    else { return nil }
    let target = Target(
      type: type, identifier: text(match.identifier), label: text(match.label),
      placeholder: text(match.placeholder), value: text(match.value), hitPoint: Point(x: x, y: y))
    let named = [target.identifier, target.label, target.value, target.placeholder].contains { $0 != nil }
    return named || textInputs.contains(type) ? target : nil
  }

  private static func text(_ part: Substring?) -> String? {
    guard let part, !part.isEmpty else { return nil }
    return String(part)
  }

  private typealias Element = Regex<
    (
      Substring, type: Substring, identifier: Substring?, label: Substring?, placeholder: Substring?,
      value: Substring?, x: Substring, y: Substring
    )
  >

  /// One element line: `<indent>Type, {{x, y}, {w, h}}, identifier: '…', label: '…',
  /// placeholderValue: '…', value: …, <states>, hitPoint: {x, y}`, every part between the frame
  /// and the hit point optional.
  ///
  /// The value is not quoted and may contain commas; the states that can follow it are known, so
  /// it ends where they begin. A quoted part ends at the quote the next part follows.
  private static var element: Element {
    #/
      \ *(?<type>[A-Za-z]+),\ \{\{[^}]*\},\ \{[^}]*\}\}
      (?:,\ identifier:\ '(?<identifier>.*?)')?
      (?:,\ label:\ '(?<label>.*?)')?
      (?:,\ placeholderValue:\ '(?<placeholder>.*?)')?
      (?:,\ value:\ (?<value>.*?))?
      (?:,\ (?:Selected|Disabled|Keyboard\ Focused|Focused))*
      ,\ hitPoint:\ \{(?<x>-?[0-9.]+),\ (?<y>-?[0-9.]+)\}
      /#
  }

  /// Element types an agent acts on.
  private static let controls: Set<String> = [
    "Button", "Cell", "CheckBox", "ComboBox", "DatePicker", "Icon", "Link", "MenuItem", "PageIndicator", "Picker",
    "PickerWheel", "PopUpButton", "RadioButton", "SearchField", "SecureTextField", "SegmentedControl", "Slider",
    "Stepper", "Switch", "Tab", "TextField", "TextView", "Toggle",
  ]

  /// Controls that are targets even without a name: an empty, unlabelled field is still where
  /// text goes.
  private static let textInputs: Set<String> = ["SearchField", "SecureTextField", "TextField", "TextView"]
}

/// A point on the screen, written as `[x, y]`.
struct Point: Codable, Equatable, Sendable {
  var x: Double
  var y: Double

  init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    x = try container.decode(Double.self)
    y = try container.decode(Double.self)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.unkeyedContainer()
    try container.encode(x)
    try container.encode(y)
  }
}
