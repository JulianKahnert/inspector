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
  /// the part before ` @ `, and `nil` works only while exactly one app serves.
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
    let endpoint: Bonjour.Endpoint = try await Self.first(within: .seconds(5), orThrow: notFound) {
      try await Self.browse(for: name, orThrow: notFound)
    }

    let responseTimeout = Self.responseTimeout(for: request)
    let timedOut = InspectorError(
      code: .timeout,
      message: "`\(endpoint.name)` did not answer within \(responseTimeout.components.seconds) s")
    return try await Self.first(within: responseTimeout, orThrow: timedOut) {
      let connection = NetworkConnection(to: endpoint) {
        Coder(WireMessage.self, using: .json) { TCP() }
      }
      try await connection.send(.request(request))
      guard case .response(let response) = try await connection.receive().content else {
        throw InspectorError(code: .badRequest, message: "unexpected message from app")
      }
      return response
    }
  }

  /// The one endpoint `app` selects, once no second match has turned up for a short while.
  ///
  /// Bonjour reports services one by one as it finds them, so the first update with a match may
  /// not hold a second app that matches too; returning then would skip ``ErrorCode/ambiguousApp``.
  private static func browse(for app: String?, orThrow notFound: InspectorError) async throws -> Bonjour.Endpoint {
    let (updates, continuation) = AsyncStream.makeStream(
      of: [Bonjour.Endpoint].self, bufferingPolicy: .bufferingNewest(1))
    return try await withThrowingTaskGroup { group in
      group.addTask {
        let _: Void = try await NetworkBrowser(for: .bonjour(serviceType, domain: nil, includeTxtRecord: false))
          .run { endpoints in
            continuation.yield(endpoints)
            return .continue
          }
      }
      defer { group.cancelAll() }
      var latest: [Bonjour.Endpoint] = []
      for await endpoints in updates {
        latest = endpoints
        if try select(app, from: endpoints.map(\.name)) != nil { break }
      }
      try Task.checkCancellation()
      // PROTOTYPE 07: skip the second-app grace period when `--app` names an instance that is
      // already present, so a loop step costs the request alone.
      let exact = app.flatMap { name in latest.first { $0.name == name || $0.name.hasPrefix(name + " @ ") } }
      if let exact { return exact }
      // A guess at how long a second app on the same network takes to show up; not measured.
      try await Task.sleep(for: .milliseconds(500))
      continuation.finish()
      for await endpoints in updates { latest = endpoints }
      guard let selected = try select(app, from: latest.map(\.name)),
        let match = latest.first(where: { $0.name == selected })
      else { throw notFound }
      return match
    }
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
  /// Never shorter than the app may take: a send waits for its effects up to `timeoutMs`, or the
  /// app's default settle timeout, before it answers.
  static func responseTimeout(for request: Request) -> Duration {
    let margin: Duration = .seconds(5)
    guard case .send(let send) = request else { return margin }
    return (send.timeoutMs.map { .milliseconds($0) } ?? InspectorCore.defaultSettleTimeout) + margin
  }

  /// The instance names of every app that advertises ``serviceType`` within `duration`, sorted.
  public static func instanceNames(browsingFor duration: Duration) async throws -> [String] {
    // Only the latest endpoint list matters; older ones are superseded, never merged.
    let (updates, continuation) = AsyncStream.makeStream(of: [String].self, bufferingPolicy: .bufferingNewest(1))
    try await withThrowingTaskGroup { group in
      group.addTask {
        let _: Void = try await NetworkBrowser(for: .bonjour(serviceType, domain: nil, includeTxtRecord: false))
          .run { endpoints in
            continuation.yield(endpoints.map(\.name))
            return .continue
          }
      }
      group.addTask { try await Task.sleep(for: duration) }
      try await group.next()
      group.cancelAll()
    }
    continuation.finish()
    var names: [String] = []
    for await latest in updates { names = latest }
    return Set(names).sorted()
  }

  /// Picks the one instance name `app` selects, or `nil` while none does.
  ///
  /// - Throws: ``ErrorCode/ambiguousApp`` when several names match.
  static func select(_ app: String?, from names: [String]) throws -> String? {
    let matches = names.filter { name in
      guard let app else { return true }
      return name == app || name.hasPrefix("\(app) @ ")
    }
    guard matches.count <= 1 else {
      throw InspectorError(
        code: .ambiguousApp,
        message: "several serving apps match; pick one with --app",
        detail: matches.joined(separator: ", "))
    }
    return matches.first
  }

  private static func first<Value: Sendable>(
    within duration: Duration,
    orThrow timeoutError: InspectorError,
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withThrowingTaskGroup { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(for: duration)
        throw timeoutError
      }
      defer { group.cancelAll() }
      guard let value = try await group.next() else { throw timeoutError }
      return value
    }
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
