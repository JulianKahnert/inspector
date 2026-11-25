#if canImport(UIKit)
import Testing
import UIKit
@testable import InspectorKit

/// `ui.tap` and the `ui` hit points against windows built in the test, without an app. Runs only
/// where UIKit is (an iOS simulator through `xcodebuild test`), not under `swift test` on the Mac.
@MainActor
@Suite("Interface inspection")
struct InterfaceInspectionTests {
  /// Records the events a control sends. A test process has no `UIApplication`, so the event is
  /// recorded where the control sends it rather than where a target receives it.
  final class RecordingButton: UIButton {
    var sent: [UIControl.Event] = []
    override func sendActions(for controlEvents: UIControl.Event) {
      sent.append(controlEvents)
    }
  }

  final class RecordingSegments: UISegmentedControl {
    var sent: [UIControl.Event] = []
    override func sendActions(for controlEvents: UIControl.Event) {
      sent.append(controlEvents)
    }
  }

  private func window(with views: UIView...) -> UIWindow {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
    window.rootViewController = UIViewController()
    views.forEach(window.addSubview)
    window.isHidden = false
    return window
  }

  private func button(_ label: String, enabled: Bool = true) -> RecordingButton {
    let button = RecordingButton(type: .system)
    button.setTitle(label, for: .normal)
    button.frame = CGRect(x: 20, y: 100, width: 120, height: 44)
    button.isEnabled = enabled
    return button
  }

  @Test("activates a button by its label")
  func tapsButtonByLabel() throws {
    let save = button("Save")
    try InterfaceInspection.activate("Save", in: [window(with: save)])
    #expect(save.sent.contains(.touchUpInside))
  }

  @Test("activates a button by its accessibility identifier")
  func tapsButtonByIdentifier() throws {
    let save = button("Save")
    save.accessibilityIdentifier = "form.save"
    try InterfaceInspection.activate("form.save", in: [window(with: save)])
    #expect(save.sent.contains(.touchUpInside))
  }

  @Test("selects a segment by its title")
  func selectsSegment() throws {
    let control = RecordingSegments(items: ["Month", "Year"])
    control.frame = CGRect(x: 20, y: 200, width: 200, height: 32)
    try InterfaceInspection.activate("Year", in: [window(with: control)])
    #expect(control.selectedSegmentIndex == 1)
    #expect(control.sent == [.valueChanged])
  }

  @Test("refuses a disabled button")
  func refusesDisabled() {
    let save = button("Save", enabled: false)
    let error = #expect(throws: InspectorError.self) {
      try InterfaceInspection.activate("Save", in: [window(with: save)])
    }
    #expect(error?.code == .expectationFailed)
    #expect(save.sent.isEmpty)
  }

  @Test("ignores a hidden or off-screen button")
  func ignoresInvisible() {
    let hidden = button("Save")
    hidden.isHidden = true
    let offScreen = button("Save")
    offScreen.frame.origin = CGPoint(x: 900, y: 100)
    let error = #expect(throws: InspectorError.self) {
      try InterfaceInspection.activate("Save", in: [window(with: hidden, offScreen)])
    }
    #expect(error?.code == .targetNotFound)
    #expect(hidden.sent.isEmpty && offScreen.sent.isEmpty)
  }

  @Test("lists the tab bar's items by label with their centers")
  func hitPointsOfTabBar() throws {
    let bar = UITabBar(frame: CGRect(x: 0, y: 720, width: 400, height: 80))
    bar.items = [UITabBarItem(title: "Home", image: nil, tag: 0), UITabBarItem(title: "Menu", image: nil, tag: 1)]
    let window = window(with: bar)
    bar.layoutIfNeeded()
    let points = InterfaceInspection.hitPoints(in: [window])
    let home = try #require(points["Home"])
    let menu = try #require(points["Menu"])
    #expect(home[0] < menu[0])
    #expect(home[1] > 720 && home[1] < 800)
  }

  @Test("refuses a tab bar's button, which only its hit point switches")
  func refusesTab() {
    let bar = UITabBar(frame: CGRect(x: 0, y: 720, width: 400, height: 80))
    bar.items = [UITabBarItem(title: "Home", image: nil, tag: 0), UITabBarItem(title: "Menu", image: nil, tag: 1)]
    let window = window(with: bar)
    bar.layoutIfNeeded()
    let error = #expect(throws: InspectorError.self) {
      try InterfaceInspection.activate("Menu", in: [window])
    }
    #expect(error?.code == .targetNotFound)
  }

  @Test("registers ui.tap and the ui state, but keeps the app's own")
  func registersWithoutReplacing() async throws {
    let inspector = Inspector()
    InterfaceInspection.register(on: inspector)
    #expect(await inspector.catalog().actions.map(\.path) == ["ui.tap"])
    guard case let .object(state) = try await inspector.state() else { Issue.record("no object"); return }
    #expect(state["ui"] != nil)

    let own = Inspector()
    own.action("ui.tap") {}
    InterfaceInspection.register(on: own)
    #expect(await own.catalog().actions.first?.payload == nil)
  }
}
#endif
