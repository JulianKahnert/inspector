#if canImport(UIKit)
import UIKit

/// The controls of a UIKit app, reached from inside the process: `ui.tap` activates one by name and
/// the `ui` state lists the hit points of the bars' buttons.
///
/// ``Inspector`` registers both when it starts serving on a platform with UIKit, unless the app
/// registered the same path or key itself. Without Xcode an activation takes milliseconds instead of
/// the second a synthesized touch costs, and the hit points let a driver tap a bar button without a
/// screen capture.
///
/// Only the app's own windows are searched: a system dialog, a web page in a view service, a context
/// menu's items and other UI drawn by another process stay with Xcode's gestures.
@MainActor
enum InterfaceInspection {
  /// The action path of the in-app tap.
  static let tapPath = "ui.tap"
  /// The state key of the hit points.
  static let stateKey = "ui"

  /// What the `ui` state reports.
  struct State: Encodable, Equatable, Sendable {
    /// The centers of the labelled buttons in tab bars, navigation bars and toolbars, in window
    /// points rounded to 0.1, keyed by accessibility label.
    var hitPoints: [String: [Double]]
  }

  /// Registers `ui.tap` and the `ui` state on `inspector`, each only when nothing holds its path yet.
  static func register(on inspector: Inspector) {
    if !inspector.hasAction(tapPath) {
      inspector.action(tapPath, schema: .string) { (name: String) in
        try await MainActor.run { try activate(name, in: visibleWindows()) }
      }
    }
    if !inspector.hasState(stateKey) {
      inspector.state(stateKey) { @MainActor in State(hitPoints: hitPoints(in: visibleWindows())) }
    }
  }

  /// The app's visible windows, topmost first.
  static func visibleWindows() -> [UIWindow] {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .filter { !$0.isHidden && $0.alpha > 0 }
      .sorted { $0.windowLevel.rawValue > $1.windowLevel.rawValue }
  }

  // MARK: - Activation

  /// Activates the first visible, enabled element whose accessibility identifier or label is
  /// `name`, or the segment titled `name`, searching `windows` in order.
  ///
  /// An element is activated the way its own touch would: a segment is selected, a cell is
  /// selected through its list's delegate, a navigation bar's back button pops its stack,
  /// anything else gets `accessibilityActivate()`, and a control that declines that gets its
  /// touch-up actions.
  ///
  /// - Throws: ``ErrorCode/targetNotFound`` when nothing visible has the name or none of the
  ///   matches could be activated; ``ErrorCode/expectationFailed`` when every match is disabled.
  static func activate(_ name: String, in windows: [UIWindow]) throws {
    var matches: [NSObject] = []
    for window in windows {
      search(window, name: name, window: window, depth: 0, into: &matches)
    }
    let enabled = matches.filter(isEnabled)
    if !matches.isEmpty, enabled.isEmpty {
      throw InspectorError(
        code: .expectationFailed,
        message: "ui.tap: `\(name)` is disabled",
        detail: matches.map(describe).joined(separator: ", ")
      )
    }
    for element in enabled where fire(element, name: name) { return }
    throw InspectorError(
      code: .targetNotFound,
      message: matches.isEmpty
        ? "ui.tap: nothing visible is named `\(name)`"
        : "ui.tap: `\(name)` could not be activated",
      detail: matches.isEmpty ? nil : matches.map(describe).joined(separator: ", ")
    )
  }

  private static func describe(_ object: NSObject) -> String {
    String(describing: type(of: object))
  }

  private static func matches(_ object: NSObject, _ name: String) -> Bool {
    if identifier(of: object) == name { return true }
    if object.accessibilityLabel == name { return true }
    // Accessibility is loaded only once an assistive client (Xcode's gestures, VoiceOver) asked
    // for it; until then a button's label is nil and its title is the name.
    return (object as? UIButton)?.currentTitle == name
  }

  /// The accessibility identifier of any element: views, bar items and the elements SwiftUI
  /// creates, which implement it without a Swift-visible conformance (a cast to
  /// `UIAccessibilityIdentification` fails even for a `UIButton`).
  private static func identifier(of object: NSObject) -> String? {
    if let view = object as? UIView { return view.accessibilityIdentifier }
    guard object.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return nil }
    return object.value(forKey: "accessibilityIdentifier") as? String
  }

  private static func segmentIndex(_ control: UISegmentedControl, _ name: String) -> Int? {
    (0..<control.numberOfSegments).first { control.titleForSegment(at: $0) == name }
  }

  private static func search(_ object: NSObject, name: String, window: UIWindow, depth: Int, into found: inout [NSObject]) {
    guard depth < 60 else { return }
    if let view = object as? UIView, view.isHidden || view.alpha == 0 { return }
    if let control = object as? UISegmentedControl, segmentIndex(control, name) != nil, isOnScreen(control, in: window) {
      found.append(control)
    } else if matches(object, name), object.isAccessibilityElement || object is UIControl,
      isOnScreen(object, in: window) {
      found.append(object)
    }
    var children: [NSObject] = []
    if let view = object as? UIView { children += view.subviews }
    if let elements = object.accessibilityElements as? [NSObject] {
      children += elements
    } else {
      let count = object.accessibilityElementCount()
      if count != NSNotFound, count > 0, count < 500 {
        children += (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
      }
    }
    for child in children { search(child, name: name, window: window, depth: depth + 1, into: &found) }
  }

  /// Whether some of the element lies inside its window's bounds, by its view frame or, for an
  /// accessibility element without a view, by its accessibility frame.
  private static func isOnScreen(_ object: NSObject, in window: UIWindow) -> Bool {
    if let view = object as? UIView {
      guard view.window === window else { return false }
      let frame = view.convert(view.bounds, to: window)
      return !frame.isEmpty && frame.intersects(window.bounds)
    }
    let frame = object.accessibilityFrame
    // An element that reports no frame cannot be checked; let it through rather than hide it.
    guard !frame.isEmpty else { return true }
    return frame.intersects(window.convert(window.bounds, to: nil))
  }

  private static func isEnabled(_ object: NSObject) -> Bool {
    if let control = object as? UIControl, !control.isEnabled { return false }
    return !object.accessibilityTraits.contains(.notEnabled)
  }

  private static func fire(_ element: NSObject, name: String) -> Bool {
    // A tab switches on its bar's own touch handling, which activation does not reach; it is
    // refused here so the caller taps it at its hit point instead of a tap that did nothing.
    if isInTabBar(element) { return false }
    if let control = element as? UISegmentedControl, let index = segmentIndex(control, name) {
      control.selectedSegmentIndex = index
      control.sendActions(for: .valueChanged)
      return true
    }
    if element.accessibilityActivate() { return true }
    if isBackButton(element), popTopNavigation(from: element) { return true }
    if selectCell(around: element) { return true }
    if let control = element as? UIControl, !control.allTargets.isEmpty || control is UIButton {
      control.sendActions(for: .touchUpInside)
      control.sendActions(for: .primaryActionTriggered)
      return true
    }
    return false
  }

  private static func isInTabBar(_ element: NSObject) -> Bool {
    var view = element as? UIView ?? ((element as? UIAccessibilityElement)?.accessibilityContainer as? UIView)
    while let current = view {
      if current is UITabBar || isTabButton(current) { return true }
      view = current.superview
    }
    return false
  }

  private static func isBackButton(_ element: NSObject) -> Bool {
    String(describing: type(of: element)).contains("BackButton")
  }

  /// The back button's own action: pops the deepest visible navigation stack that can go back.
  private static func popTopNavigation(from element: NSObject) -> Bool {
    let window = (element as? UIView)?.window
    let roots = (window.map { [$0] } ?? visibleWindows()).compactMap(\.rootViewController)
    var deepest: UINavigationController?
    func visit(_ controller: UIViewController) {
      if let navigation = controller as? UINavigationController, navigation.viewControllers.count > 1,
        navigation.viewIfLoaded?.window != nil {
        deepest = navigation
      }
      controller.children.forEach(visit)
      if let presented = controller.presentedViewController { visit(presented) }
    }
    roots.forEach(visit)
    guard let deepest else { return false }
    deepest.popViewController(animated: true)
    return true
  }

  /// A row of a collection or table view: its list's delegate selects it.
  private static func selectCell(around element: NSObject) -> Bool {
    var view = element as? UIView ?? ((element as? UIAccessibilityElement)?.accessibilityContainer as? UIView)
    while let current = view {
      if let cell = current as? UICollectionViewCell, let list = enclosing(UICollectionView.self, of: cell),
        let path = list.indexPath(for: cell), let delegate = list.delegate {
        guard delegate.collectionView?(list, shouldSelectItemAt: path) ?? true else { return false }
        list.selectItem(at: path, animated: false, scrollPosition: [])
        delegate.collectionView?(list, didSelectItemAt: path)
        return true
      }
      if let cell = current as? UITableViewCell, let table = enclosing(UITableView.self, of: cell),
        let path = table.indexPath(for: cell), let delegate = table.delegate {
        table.selectRow(at: path, animated: false, scrollPosition: .none)
        delegate.tableView?(table, didSelectRowAt: path)
        return true
      }
      view = current.superview
    }
    return false
  }

  private static func enclosing<T: UIView>(_ type: T.Type, of view: UIView) -> T? {
    var current = view.superview
    while let candidate = current {
      if let match = candidate as? T { return match }
      current = candidate.superview
    }
    return nil
  }

  // MARK: - Hit points

  /// The centers of the labelled buttons in the visible tab bars, navigation bars and toolbars of
  /// `windows`, in window points rounded to 0.1, keyed by accessibility label; the topmost window
  /// wins a label.
  static func hitPoints(in windows: [UIWindow]) -> [String: [Double]] {
    var points: [String: [Double]] = [:]
    for window in windows.reversed() {
      for view in descendants(of: window) {
        if isBar(view) {
          collect(in: view, window: window, into: &points)
        } else if isTabButton(view), let label = label(of: view) {
          add(view, label: label, window: window, into: &points)
        }
      }
    }
    return points
  }

  /// A system bar, or the view a system tab bar is drawn in on a newer iOS (the class names differ
  /// between releases, so they are matched by name).
  private static func isBar(_ view: UIView) -> Bool {
    if view is UITabBar || view is UINavigationBar || view is UIToolbar { return true }
    let name = String(describing: type(of: view))
    return name.hasPrefix("_UI") && name.localizedCaseInsensitiveContains("TabBar")
      && !name.localizedCaseInsensitiveContains("button")
  }

  /// A tab button of the floating tab bar, which is no `UITabBar` subview on a newer iOS.
  private static func isTabButton(_ view: UIView) -> Bool {
    let name = String(describing: type(of: view))
    return name.localizedCaseInsensitiveContains("tab") && name.localizedCaseInsensitiveContains("button")
  }

  private static func collect(in view: UIView, window: UIWindow, into points: inout [String: [Double]]) {
    guard !view.isHidden, view.alpha > 0 else { return }
    if view.isAccessibilityElement || isTabButton(view) || view is UIControl, let label = label(of: view) {
      add(view, label: label, window: window, into: &points)
      return
    }
    for subview in view.subviews { collect(in: subview, window: window, into: &points) }
  }

  /// The view's accessibility label, else (accessibility not loaded yet) its first label's text.
  private static func label(of view: UIView) -> String? {
    if let label = view.accessibilityLabel, !label.isEmpty { return label }
    if let title = (view as? UIButton)?.currentTitle, !title.isEmpty { return title }
    return descendants(of: view).lazy.compactMap { ($0 as? UILabel)?.text }.first { !$0.isEmpty }
  }

  private static func add(_ view: UIView, label: String, window: UIWindow, into points: inout [String: [Double]]) {
    guard !view.isHidden, view.alpha > 0 else { return }
    let frame = view.convert(view.bounds, to: window)
    guard !frame.isEmpty, frame.intersects(window.bounds) else { return }
    points[label] = [(frame.midX * 10).rounded() / 10, (frame.midY * 10).rounded() / 10]
  }

  private static func descendants(of view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap { descendants(of: $0) }
  }
}
#endif
