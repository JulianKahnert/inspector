import Foundation
import Testing

@testable import InspectorKit

@Suite("Messages")
struct MessagesTests {
  @Test("A request decodes from the line the CLI writes")
  func requestRoundTrip() throws {
    let requests: [Request] = [
      .hello, .catalog,
      .state(path: nil), .state(path: "counter"),
      .send(SendRequest(path: "counter.set", payload: 42, timeoutMs: 500)),
    ]
    for request in requests {
      let data = Data(WireJSON.line(request).utf8)
      #expect(try JSONDecoder().decode(Request.self, from: data) == request)
    }
  }

  @Test("A send request with no payload omits the key; one sending null keeps it")
  func sendRequestPayloadPresence() throws {
    let noPayload = WireJSON.line(Request.send(SendRequest(path: "counter.increment")))
    #expect(!noPayload.contains("payload"))

    let nullPayload = WireJSON.line(Request.send(SendRequest(path: "counter.reset", payload: .null)))
    #expect(nullPayload.contains(#""payload":null"#))

    let decodedNoPayload = try JSONDecoder().decode(Request.self, from: Data(noPayload.utf8))
    guard case .send(let request) = decodedNoPayload else {
      Issue.record("expected a send request")
      return
    }
    #expect(request.payload == nil)

    let decodedNullPayload = try JSONDecoder().decode(Request.self, from: Data(nullPayload.utf8))
    guard case .send(let request2) = decodedNullPayload else {
      Issue.record("expected a send request")
      return
    }
    #expect(request2.payload == .null)
  }

  @Test("A response round-trips through the wire, hello and catalog inlined next to v and t")
  func responseRoundTrip() throws {
    let responses: [Response] = [
      .hello(Hello(app: "DemoHost", pid: 42, provider: "Inspector")),
      .catalog(Catalog(actions: [ActionNode(path: "counter.increment"), ActionNode(path: "counter.set", payload: .int)])),
      .state(.object(["counter": 0])),
      .sendResult(SendResult(settled: true, state: .object(["counter": 42]), diff: [JSONDiffEntry(path: "counter", old: 0, new: 42)])),
      .error(InspectorError(code: .unknownActionPath, message: "no action at `nope`", didYouMean: ["counter.set"])),
    ]
    for response in responses {
      let data = Data(WireJSON.line(response).utf8)
      #expect(try JSONDecoder().decode(Response.self, from: data) == response)
    }
  }

  @Test("hello is inlined flat, without a nested object")
  func helloIsFlat() {
    let line = WireJSON.line(Response.hello(Hello(app: "DemoHost", pid: 1, provider: "Inspector")))
    #expect(line == #"{"app":"DemoHost","pid":1,"provider":"Inspector","t":"hello"}"#)
  }

  @Test("An error carries the code and suggestions, and omits absent detail and empty suggestions")
  func errorOmitsAbsentFields() throws {
    let error = InspectorError(code: .unknownActionPath, message: "no action at `nope`")
    let line = WireJSON.line(Response.error(error))
    #expect(!line.contains("detail"))
    #expect(!line.contains("didYouMean"))

    let data = Data(line.utf8)
    #expect(try JSONDecoder().decode(Response.self, from: data) == .error(error))
  }
}
