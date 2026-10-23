import Foundation
import Network

#if os(macOS)
import SystemConfiguration
#else
import UIKit
#endif

/// A transport over TCP on the local network, found through Bonjour.
///
/// The app advertises ``serviceType``; the CLI browses for it and opens one connection per
/// request.
@available(iOS 26, macOS 26, *)
public struct BonjourTransport: InspectorTransport {
  /// The Bonjour service type both sides use.
  public static let serviceType = "_inspector._tcp"

  /// The Bonjour instance name to advertise, or the app to connect to.
  ///
  /// When serving, `nil` advertises under the device's name; ``Inspector/serve(app:)`` passes
  /// `<app> @ <device>`. When sending, the name selects the app by its full instance name or by
  /// the part before ` @ `, and `nil` works only while exactly one app serves. A full instance
  /// name connects as soon as Bonjour reports it; the part before ` @ ` and `nil` wait about half
  /// a second longer for a second match.
  public var name: String?

  /// Creates a transport that advertises or looks for the given instance name.
  public init(name: String? = nil) {
    self.name = name
  }

  public func serve(_ handle: @escaping @Sendable (Request) async -> Response) async throws {
    try await NetworkListener(for: .bonjour(name: name, type: Self.serviceType)) {
      Coder(WireMessage.self, using: .json) { TCP() }
    }
    .run { connection in
      for try await (message, _) in connection.messages {
        guard case .request(let request) = message else { continue }
        try await connection.send(.response(await handle(request)))
      }
    }
  }

  /// - Throws: ``ErrorCode/appNotFound`` when no matching app appears within 5 seconds,
  ///   ``ErrorCode/ambiguousApp`` when several match, and ``ErrorCode/timeout`` when the app does
  ///   not answer within ``responseTimeout(for:)``.
  public func send(_ request: Request) async throws -> Response {
    let name = name
    let notFound = InspectorError(
      code: .appNotFound,
      message: name.map { "no serving app matches `\($0)`" } ?? "no serving app found")
    let endpoint: Bonjour.Endpoint = try await withDeadline(.seconds(5), orThrow: notFound) {
      try await Self.browse(for: name, orThrow: notFound)
    }

    let responseTimeout = Self.responseTimeout(for: request)
    let timedOut = InspectorError(
      code: .timeout,
      message: "`\(endpoint.name)` did not answer within \(responseTimeout.components.seconds) s")
    return try await withDeadline(responseTimeout, orThrow: timedOut) {
      let connection = NetworkConnection(to: endpoint) {
        Coder(WireMessage.self, using: .json) { TCP() }
      }
      try await connection.send(.request(request))
      guard case .response(let response) = try await connection.receive().content else {
        throw InspectorError(code: .badRequest, message: "unexpected message from app")
      }
      return Self.stampingInstance(endpoint.name, on: response)
    }
  }

  /// `response` with `instance` stamped on it when it is a hello answer, so `hello` names the
  /// instance the CLI reached; every other answer as it is.
  static func stampingInstance(_ instance: String, on response: Response) -> Response {
    guard case .hello(var hello) = response else { return response }
    hello.instance = instance
    return .hello(hello)
  }

  /// The one endpoint `app` selects among the services Bonjour finds.
  private static func browse(for app: String?, orThrow notFound: InspectorError) async throws -> Bonjour.Endpoint {
    let (updates, continuation) = AsyncStream.makeStream(
      of: [Bonjour.Endpoint].self, bufferingPolicy: .bufferingNewest(1))
    // Cancelled, never awaited: the browser may not end on cancellation (see `withDeadline`).
    let browser = Task {
      let _: Void = try await NetworkBrowser(for: .bonjour(serviceType, domain: nil, includeTxtRecord: false))
        .run { endpoints in
          continuation.yield(endpoints)
          return .continue
        }
    }
    defer { browser.cancel() }
    let match = try await discover(app, in: updates, name: \.name) {
      // A guess at how long a second app on the same network takes to show up; not measured.
      try await Task.sleep(for: .milliseconds(500))
      continuation.finish()
    }
    guard let match else { throw notFound }
    return match
  }

  /// The one endpoint `app` selects from a browser's `updates`, or `nil` when none does.
  ///
  /// Bonjour reports services one by one as it finds them, so the first update with a match may
  /// not hold a second app that matches too; returning then would skip ``ErrorCode/ambiguousApp``.
  /// So once a match turns up, `graceWindow` lets later updates arrive and then finishes
  /// `updates`, and the last update decides.
  ///
  /// A full instance name skips that wait: Bonjour keeps instance names unique per service type
  /// and domain, so the first endpoint with exactly that name is the only one it can select.
  ///
  /// - Throws: ``ErrorCode/ambiguousApp`` when several endpoints match.
  static func discover<Endpoint>(
    _ app: String?,
    in updates: AsyncStream<[Endpoint]>,
    name: (Endpoint) -> String,
    graceWindow: () async throws -> Void
  ) async throws -> Endpoint? {
    var latest: [Endpoint] = []
    for await endpoints in updates {
      if let app, let exact = endpoints.first(where: { name($0) == app }) { return exact }
      latest = endpoints
      if try select(app, from: endpoints.map(name)) != nil { break }
    }
    try Task.checkCancellation()
    try await graceWindow()
    for await endpoints in updates { latest = endpoints }
    guard let selected = try select(app, from: latest.map(name)) else { return nil }
    return latest.first { name($0) == selected }
  }

  /// The instance name ``Inspector/serve(app:)`` advertises: `<app> @ <device>`.
  static func instanceName(app: String) async -> String {
    "\(app) @ \(await deviceName())"
  }

  /// The computer name on the Mac, the same one Bonjour advertises by default. On iOS it is the
  /// simulator's name, and only the model ("iPhone") on a device since iOS 16.
  private static func deviceName() async -> String {
    #if os(macOS)
    (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
    #else
    await MainActor.run { UIDevice.current.name }
    #endif
  }

  /// How long the CLI waits for an answer once it has found the app.
  ///
  /// Never shorter than the app may take, so the CLI never gives up before the app does: a send
  /// waits for its effects up to `timeoutMs`, or the app's default settle timeout, then for its
  /// `until` condition; a wait for its condition.
  static func responseTimeout(for request: Request) -> Duration {
    let margin: Duration = .seconds(5)
    switch request {
    case .send(let send):
      let settle = send.timeoutMs.map { .milliseconds($0) } ?? InspectorCore.defaultSettleTimeout
      guard send.until != nil else { return settle + margin }
      return settle + conditionTimeout(send.untilTimeoutMs) + margin
    case .wait(let wait):
      return conditionTimeout(wait.timeoutMs) + margin
    case .hello, .catalog, .state:
      return margin
    }
  }

  private static func conditionTimeout(_ milliseconds: Int?) -> Duration {
    milliseconds.map { .milliseconds($0) } ?? InspectorCore.defaultConditionTimeout
  }

  /// The instance names of every app that advertises ``serviceType`` within `duration`, sorted.
  public static func instanceNames(browsingFor duration: Duration) async throws -> [String] {
    // Only the latest endpoint list matters; older ones are superseded, never merged.
    let (updates, continuation) = AsyncThrowingStream.makeStream(
      of: [String].self, bufferingPolicy: .bufferingNewest(1))
    // Cancelled, never awaited: the browser may not end on cancellation (see `withDeadline`).
    let browser = Task {
      do {
        let _: Void = try await NetworkBrowser(for: .bonjour(serviceType, domain: nil, includeTxtRecord: false))
          .run { endpoints in
            continuation.yield(endpoints.map(\.name))
            return .continue
          }
      } catch {
        continuation.finish(throwing: error)
      }
    }
    defer { browser.cancel() }
    try await Task.sleep(for: duration)
    continuation.finish()
    var names: [String] = []
    for try await latest in updates { names = latest }
    return Set(names).sorted()
  }

  /// Picks the one instance name `app` selects, or `nil` while none does.
  ///
  /// A name equal to `app` wins over names that only start with `<app> @ `, since Bonjour
  /// instance names are unique.
  ///
  /// - Throws: ``ErrorCode/ambiguousApp`` when several names match.
  static func select(_ app: String?, from names: [String]) throws -> String? {
    if let app, names.contains(app) { return app }
    let matches = names.filter { name in
      guard let app else { return true }
      return name.hasPrefix("\(app) @ ")
    }
    guard matches.count <= 1 else {
      throw InspectorError(
        code: .ambiguousApp,
        message: "several serving apps match; pick one with --app",
        detail: matches.joined(separator: ", "))
    }
    return matches.first
  }
}

@available(iOS 26, macOS 26, *)
extension BonjourTransport {
  /// `Coder` frames one message type per connection; this carries both directions over the same
  /// duplex socket.
  fileprivate enum WireMessage: Codable, Sendable {
    case request(Request)
    case response(Response)
  }
}
