import Foundation
import Testing

@testable import InspectorKit
@testable import inspector

@Suite("Targets")
struct TargetTests {
  @Test("a screen's targets are its controls with a name, in hierarchy order, without containers, text or images")
  func meterDetail() throws {
    let targets = Target.list(inHierarchy: try fixture("meter-detail-hierarchy"))

    #expect(
      targets == [
        Target(type: "Button", identifier: "BackButton", label: "Zähler", hitPoint: Point(x: 38, y: 84)),
        Target(type: "Button", label: "Ändern", hitPoint: Point(x: 310.3, y: 84)),
        Target(type: "Button", label: "Stand eintragen", hitPoint: Point(x: 363.3, y: 84)),
        Target(type: "Button", label: "1ESY1160123456, Fotos: 0", hitPoint: Point(x: 201, y: 251.3)),
        Target(type: "Button", label: "Fotos dieses Zählers suchen", hitPoint: Point(x: 201, y: 320.3)),
        // The app formats the date range with thin spaces around the dash.
        Target(
          type: "Button", label: "1ESY1160098765, 1. Juni 2024\u{2009}–\u{2009}14. März 2025",
          hitPoint: Point(x: 201, y: 438.7)),
        Target(type: "Button", label: "Zählerwechsel eintragen", hitPoint: Point(x: 201, y: 499)),
        Target(type: "Button", label: "Tarif hinzufügen", hitPoint: Point(x: 201, y: 608.7)),
        Target(
          type: "Button", label: "2.000,0 kWh, 1. Okt. 2026, 10:00, Von Hand eingetragen",
          hitPoint: Point(x: 201, y: 755)),
        Target(
          type: "Button", label: "150,0 kWh, 14. März 2025, 01:00, Von Hand eingetragen",
          hitPoint: Point(x: 201, y: 823.7)),
        Target(
          type: "Button",
          label: "Zähler getauscht am 14. März 2025, 1.250,5 kWh, 14. März 2025, 01:00, Von Hand eingetragen",
          hitPoint: Point(x: 201, y: 866)),
        Target(type: "Button", label: "Zähler", hitPoint: Point(x: 75.3, y: 822)),
        Target(type: "Button", label: "Prüfen", value: "4 Objekte", hitPoint: Point(x: 148, y: 822)),
        Target(type: "Button", label: "Statistik", hitPoint: Point(x: 220.7, y: 822)),
        Target(type: "Button", label: "Einstellungen", hitPoint: Point(x: 310, y: 822)),
      ])
  }

  @Test("a text field's typed text is its value, also with no label; a value may contain commas")
  func enterReadingSheet() throws {
    let targets = Target.list(inHierarchy: try fixture("enter-reading-hierarchy"))

    #expect(
      targets == [
        Target(type: "Button", label: "Abbrechen", hitPoint: Point(x: 73.8, y: 100)),
        Target(type: "Button", label: "Sichern", hitPoint: Point(x: 339.5, y: 100)),
        Target(type: "TextField", placeholder: "0", value: "2100000", hitPoint: Point(x: 206.2, y: 193)),
        Target(
          type: "Button", label: "Datums- und Uhrzeitauswahl", value: "21:59, 22.10.2026",
          hitPoint: Point(x: 278.3, y: 252)),
        Target(type: "Button", label: "22.10.2026", hitPoint: Point(x: 241.3, y: 252)),
        Target(type: "Button", label: "21:59", hitPoint: Point(x: 335, y: 252)),
      ])
  }

  @Test("a quote inside a label, an empty field without a name, and an empty label")
  func lineForms() {
    let hierarchy = """
      Application, pid: 1, label: 'Demo'
       Window, {{0.0, 0.0}, {402.0, 874.0}}, hitPoint: {201.0, 437.0}
        Button, {{16.0, 62.0}, {44.0, 44.0}}, label: 'team's meter', Selected, hitPoint: {38.0, 84.0}
        SecureTextField, {{20.0, 100.0}, {300.0, 22.0}}, hitPoint: {170.0, 111.0}
        Switch, {{-10.0, 100.0}, {50.0, 30.0}}, identifier: 'push', label: '', value: 1, Disabled, hitPoint: {15.0, -5.5}
        Cell, {{16.0, 168.0}, {370.0, 40.3}}, hitPoint: {201.0, 188.2}
      """

    #expect(
      Target.list(inHierarchy: hierarchy) == [
        Target(type: "Button", label: "team's meter", hitPoint: Point(x: 38, y: 84)),
        Target(type: "SecureTextField", hitPoint: Point(x: 170, y: 111)),
        Target(type: "Switch", identifier: "push", value: "1", hitPoint: Point(x: 15, y: -5.5)),
      ])
  }

  @Test("a target resolves by its identifier or its label", arguments: ["BackButton", "Stand eintragen"])
  func resolves(query: String) throws {
    let targets = Target.list(inHierarchy: try fixture("meter-detail-hierarchy"))

    let target = try Target.resolve(query, in: targets)

    #expect(target == targets.first { $0.identifier == query || $0.label == query })
  }

  @Test("a name that matches no target fails with TARGET_NOT_FOUND and every target in detail")
  func notFound() throws {
    let targets = [
      Target(type: "Button", label: "Sichern", hitPoint: Point(x: 339.5, y: 100)),
      Target(type: "TextField", placeholder: "0", value: "2100000", hitPoint: Point(x: 206.2, y: 193)),
    ]

    let error = #expect(throws: InspectorError.self) { try Target.resolve("Speichern", in: targets) }

    #expect(
      error
        == InspectorError(
          code: .targetNotFound, message: "no target has the identifier or label `Speichern`",
          detail:
            #"[{"hitPoint":[339.5,100],"label":"Sichern","type":"Button"},{"hitPoint":[206.2,193],"placeholder":"0","type":"TextField","value":"2100000"}]"#
        ))
  }

  @Test("a name that matches targets at different points fails with TARGET_AMBIGUOUS and those targets in detail")
  func ambiguous() throws {
    let targets = Target.list(inHierarchy: try fixture("meter-detail-hierarchy"))

    // The back button and the first tab are both labelled `Zähler`.
    let error = #expect(throws: InspectorError.self) { try Target.resolve("Zähler", in: targets) }

    #expect(
      error
        == InspectorError(
          code: .targetAmbiguous, message: "2 targets have the identifier or label `Zähler`",
          detail:
            #"[{"hitPoint":[38,84],"identifier":"BackButton","label":"Zähler","type":"Button"},{"hitPoint":[75.3,822],"label":"Zähler","type":"Button"}]"#
        ))
  }

  @Test("matches at one point are one target: the hierarchy lists some elements twice")
  func samePoint() throws {
    let bar = Target(type: "Slider", label: "Volume", value: "0 %", hitPoint: Point(x: 384, y: 453.5))

    #expect(try Target.resolve("Volume", in: [bar, bar]) == bar)
  }

  /// The text of the fixture `name`, a hierarchy captured from a running app.
  private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
  }
}
