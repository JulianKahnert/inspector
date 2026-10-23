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
    let names = ["DemoHost @ Mac", "DemoHostTwo @ Mac", "Meters @ iPhone"]
    #expect(try BonjourTransport.select("DemoHost", from: names) == "DemoHost @ Mac")
    #expect(try BonjourTransport.select("Meters @ iPhone", from: names) == "Meters @ iPhone")
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

  @Test("A send with until waits for the settle timeout, then the condition's, plus the margin")
  func sendWithUntil() {
    let defaultTimeout = Request.send(SendRequest(path: "counter.set", until: .object([:])))
    #expect(BonjourTransport.responseTimeout(for: defaultTimeout) == .seconds(13))
    let explicit = Request.send(SendRequest(path: "counter.set", timeoutMs: 1_000, until: .object([:]), untilTimeoutMs: 20_000))
    #expect(BonjourTransport.responseTimeout(for: explicit) == .seconds(26))
  }

  @Test("A wait waits for its timeout, 3 seconds by default, plus the margin")
  func wait() {
    #expect(BonjourTransport.responseTimeout(for: .wait(WaitRequest(until: .object([:])))) == .seconds(8))
    #expect(BonjourTransport.responseTimeout(for: .wait(WaitRequest(until: .object([:]), timeoutMs: 60_000))) == .seconds(65))
  }
}

@Suite("BonjourTransport.answer")
struct BonjourTransportAnswerTests {
  @Test("A hello answer names the instance the app was reached under")
  func helloCarriesInstance() {
    let response = BonjourTransport.answer(
      .hello(Hello(app: "DemoHost", pid: 1, provider: "Inspector")), from: "DemoHost @ Mac")
    #expect(response == .hello(Hello(app: "DemoHost", instance: "DemoHost @ Mac", pid: 1, provider: "Inspector")))
  }

  @Test("Every other answer passes through unchanged")
  func otherAnswersUnchanged() {
    #expect(BonjourTransport.answer(.state(.int(1)), from: "DemoHost @ Mac") == .state(.int(1)))
  }
}

@Suite("BonjourTransport.discover")
struct BonjourTransportDiscoverTests {
  @Test("A full instance name ends discovery at its first exact match, without the grace window")
  func fullNameSkipsGraceWindow() async throws {
    let (updates, continuation) = AsyncStream.makeStream(of: [String].self)
    continuation.yield(["DemoHost @ Mac"])
    let found = try await BonjourTransport.discover("DemoHost @ Mac", in: updates, name: { $0 }) {
      Issue.record("a full instance name waited for a second app")
      continuation.finish()
    }
    #expect(found == "DemoHost @ Mac")
  }

  @Test("A short name waits out the grace window, so a second app found meanwhile is ambiguous")
  func shortNameWithTwoAppsIsAmbiguous() async {
    let (updates, continuation) = AsyncStream.makeStream(of: [String].self)
    continuation.yield(["DemoHost @ Mac"])
    await #expect {
      try await BonjourTransport.discover("DemoHost", in: updates, name: { $0 }) {
        continuation.yield(["DemoHost @ Mac", "DemoHost @ iPhone 17"])
        continuation.finish()
      }
    } throws: { error in
      guard let error = error as? InspectorError else { return false }
      return error.code == .ambiguousApp && error.detail == "DemoHost @ Mac, DemoHost @ iPhone 17"
    }
  }

  @Test("A short name with one app waits out the grace window, then selects it")
  func shortNameWithOneAppWaits() async throws {
    let (updates, continuation) = AsyncStream.makeStream(of: [String].self)
    continuation.yield(["DemoHost @ Mac"])
    var waited = false
    let found = try await BonjourTransport.discover("DemoHost", in: updates, name: { $0 }) {
      waited = true
      continuation.finish()
    }
    #expect(waited)
    #expect(found == "DemoHost @ Mac")
  }

  @Test("A name that equals an instance name selects that instance, even with prefix matches beside it")
  func exactNameFoundDuringGraceWindowWins() async throws {
    let (updates, continuation) = AsyncStream.makeStream(of: [String].self)
    continuation.yield(["DemoHost @ Mac"])
    let found = try await BonjourTransport.discover("DemoHost", in: updates, name: { $0 }) {
      continuation.yield(["DemoHost", "DemoHost @ Mac"])
      continuation.finish()
    }
    #expect(found == "DemoHost")
  }

  @Test("No match by the end of the updates selects nothing")
  func noMatchSelectsNothing() async throws {
    let (updates, continuation) = AsyncStream.makeStream(of: [String].self)
    continuation.yield(["Meters @ iPhone 17"])
    continuation.finish()
    let found = try await BonjourTransport.discover("DemoHost @ Mac", in: updates, name: { $0 }) {}
    #expect(found == nil)
  }
}
