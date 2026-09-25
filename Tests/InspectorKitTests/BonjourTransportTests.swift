import Testing

@testable import InspectorKit

@Suite("BonjourTransport.select")
struct BonjourTransportSelectTests {
  @Test("Without an app name, the one serving app is picked")
  func singleAppWithoutName() throws {
    #expect(try BonjourTransport.select(nil, from: ["DemoHost @ Mac"]) == "DemoHost @ Mac")
  }

  @Test("Nothing found yet selects nothing, so browsing goes on")
  func noAppsYet() throws {
    #expect(try BonjourTransport.select(nil, from: []) == nil)
    #expect(try BonjourTransport.select("DemoHost", from: ["Other @ Mac"]) == nil)
  }

  @Test("The app part before ` @ ` or the full instance name selects the app")
  func matchesAppPartOrFullName() throws {
    let names = ["DemoHost @ Mac", "DemoHostTwo @ Mac", "Chat @ iPhone"]
    #expect(try BonjourTransport.select("DemoHost", from: names) == "DemoHost @ Mac")
    #expect(try BonjourTransport.select("Chat @ iPhone", from: names) == "Chat @ iPhone")
  }

  @Test("Several matches are rejected with every matching name in detail")
  func severalMatchesAreAmbiguous() {
    let names = ["DemoHost @ Mac", "DemoHost @ iPhone"]
    #expect {
      try BonjourTransport.select(nil, from: names)
    } throws: { error in
      guard let error = error as? InspectorError else { return false }
      return error.code == .ambiguousApp && error.detail == "DemoHost @ Mac, DemoHost @ iPhone"
    }
    #expect(throws: InspectorError.self) { try BonjourTransport.select("DemoHost", from: names) }
  }
}

@Suite("BonjourTransport.responseTimeout")
struct BonjourTransportResponseTimeoutTests {
  @Test("A request without effects gets the margin alone")
  func plainRequest() {
    #expect(BonjourTransport.responseTimeout(for: .hello) == .seconds(5))
  }

  @Test("A send waits for the app's default settle timeout plus the margin")
  func sendWithDefaultTimeout() {
    let request = Request.send(SendRequest(path: "counter.set", payload: .int(1)))
    #expect(BonjourTransport.responseTimeout(for: request) == .seconds(10))
  }

  @Test("A send with timeoutMs waits for that plus the margin, never less")
  func sendWithExplicitTimeout() {
    let request = Request.send(SendRequest(path: "counter.set", payload: nil, timeoutMs: 30_000))
    #expect(BonjourTransport.responseTimeout(for: request) == .seconds(35))
  }
}
