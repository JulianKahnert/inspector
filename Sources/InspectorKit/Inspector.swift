import Foundation
import Synchronization

/// The registry an app or a feature package fills with state readers and actions, and serves to
/// the `inspector` CLI.
///
/// Register from wherever the state lives, typically a view model's init, and serve once from
/// anywhere:
///
/// ```swift
/// import OSLog
///
/// registration = Inspector.shared.state("chat.draft") { @MainActor [weak self] in
///   self?.draft ?? ""
/// }
/// Inspector.shared.action("chat.draft.set") { @MainActor [weak self] (text: String) in
///   self?.draft = text
/// }
///
/// #if DEBUG
/// if #available(iOS 26, *) {
///   Task {
///     do {
///       try await Inspector.shared.serve()
///     } catch {
///       Logger().error("inspector stopped serving: \(error)")
///     }
///   }
/// }
/// #endif
/// ```
///
/// Registering a key or path again replaces the previous registration, so a second instance of
/// the same screen takes over instead of crashing the app.
public final class Inspector: Inspectable, Sendable {
  /// The instance an app and its feature packages share.
  public static let shared = Inspector()

  public var name: String { "Inspector" }

  private typealias StateReader = @Sendable () async throws -> JSONValue
  private typealias ActionPerformer = @Sendable (JSONValue?) async throws -> Void

  private struct StateEntry {
    var id: UUID
    var read: StateReader
  }

  private struct ActionEntry {
    var id: UUID
    var schema: TypeSchema?
    var perform: ActionPerformer
  }

  private struct Storage {
    var states: [String: StateEntry] = [:]
    var actions: [String: ActionEntry] = [:]
  }

  // A `Mutex`, not an actor: registration must be callable synchronously from `@MainActor` inits
  // and from nonisolated code alike, without a `Task` around each line. The lock guards only the
  // dictionary access and is never held across an `await`.
  private let storage = Mutex(Storage())
  private let isServing = Mutex(false)

  /// Creates an empty inspector.
  ///
  /// Tests create one each; an app uses ``shared``.
  public init() {}

  /// Registers a state reader, listed under `key` in the state document.
  ///
  /// - Parameters:
  ///   - key: The top-level member the value appears under; registering it again replaces the reader.
  ///   - read: Called on every state request and around every send; its value is encoded to JSON.
  /// - Returns: A token that removes this reader again. Dropping it keeps the reader for the
  ///   inspector's lifetime.
  @discardableResult
  public func state<Value: Encodable & Sendable>(
    _ key: String,
    _ read: @escaping @Sendable () async throws -> Value
  ) -> Registration {
    let id = UUID()
    storage.withLock { storage in
      storage.states[key] = StateEntry(id: id) { try JSONValue(encoding: try await read()) }
    }
    return Registration(id: id) { [weak self] in
      self?.storage.withLock { storage in
        if storage.states[key]?.id == id { storage.states[key] = nil }
      }
    }
  }

  /// Registers an action that takes no payload.
  ///
  /// - Parameters:
  ///   - path: The dotted address `inspector send` uses; registering it again replaces the action.
  ///   - perform: Runs once per send. A send that carries a non-null payload is rejected with
  ///     ``ErrorCode/payloadTypeMismatch`` before it gets here.
  /// - Returns: A token that removes this action again. Dropping it keeps the action for the
  ///   inspector's lifetime.
  @discardableResult
  public func action(_ path: String, _ perform: @escaping @Sendable () async throws -> Void) -> Registration {
    register(path: path, schema: nil) { payload in
      if let payload, !payload.isNull {
        throw InspectorError(
          code: .payloadTypeMismatch,
          message: "expected no payload, got \(payload.typeName)"
        )
      }
      try await perform()
    }
  }

  /// Registers an action whose payload is decoded from JSON before it runs.
  ///
  /// The catalog lists `schema` if given, else the payload type's ``SchemaDescribable`` schema,
  /// else ``TypeSchema/decodable(type:)`` with the Swift type name. Pass `schema` when the
  /// payload's JSON is narrower than its Swift type, such as a `String` that takes a fixed set of
  /// values.
  ///
  /// - Parameters:
  ///   - path: The dotted address `inspector send` uses; registering it again replaces the action.
  ///   - schema: The payload schema to list in the catalog instead of the derived one.
  ///   - perform: Runs once per send with the decoded payload. A payload that does not decode is
  ///     rejected with ``ErrorCode/payloadTypeMismatch`` before it gets here.
  /// - Returns: A token that removes this action again. Dropping it keeps the action for the
  ///   inspector's lifetime.
  @discardableResult
  public func action<Payload: Decodable & Sendable>(
    _ path: String,
    schema: TypeSchema? = nil,
    _ perform: @escaping @Sendable (Payload) async throws -> Void
  ) -> Registration {
    let resolvedSchema =
      schema
      ?? (Payload.self as? any SchemaDescribable.Type)?.schema
      ?? .decodable(type: String(describing: Payload.self))
    return register(path: path, schema: resolvedSchema) { payload in
      let decoded: Payload
      do {
        decoded = try JSONDecoder().decode(Payload.self, from: JSONEncoder().encode(payload ?? .null))
      } catch {
        throw InspectorError(
          code: .payloadTypeMismatch,
          message: "expected \(resolvedSchema.displayName), got \((payload ?? .null).typeName)"
        )
      }
      try await perform(decoded)
    }
  }

  private func register(path: String, schema: TypeSchema?, perform: @escaping ActionPerformer) -> Registration {
    let id = UUID()
    storage.withLock { storage in
      storage.actions[path] = ActionEntry(id: id, schema: schema, perform: perform)
    }
    return Registration(id: id) { [weak self] in
      self?.storage.withLock { storage in
        if storage.actions[path]?.id == id { storage.actions[path] = nil }
      }
    }
  }

  // MARK: - Serving

  /// Answers requests over `transport` until the surrounding task is cancelled.
  ///
  /// A second call while this instance already serves returns at once without an error, so a
  /// feature package and its host app may both call it. Once the running call ends, a new one
  /// starts serving again.
  ///
  /// - Parameters:
  ///   - app: The name ``Hello/app`` reports.
  ///   - transport: How requests arrive.
  /// - Throws: Whatever `transport` throws, including `CancellationError`.
  public func serve(
    app: String = ProcessInfo.processInfo.processName,
    over transport: some InspectorTransport
  ) async throws {
    let didStart = isServing.withLock { isServing in
      guard !isServing else { return false }
      isServing = true
      return true
    }
    guard didStart else { return }
    defer { isServing.withLock { $0 = false } }

    let core = InspectorCore(provider: self, app: app)
    try await transport.serve { await core.handle($0) }
  }

  /// Answers requests over Bonjour until the surrounding task is cancelled.
  ///
  /// Serves over a ``BonjourTransport`` advertised as `<app> @ <device>`, so several apps on one
  /// device stay apart. Idempotent in the same way as ``serve(app:over:)``.
  ///
  /// - Parameter app: The name ``Hello/app`` reports.
  /// - Throws: Whatever the Bonjour listener throws, including `CancellationError`.
  @available(iOS 26, macOS 26, *)
  public func serve(app: String = ProcessInfo.processInfo.processName) async throws {
    try await serve(app: app, over: BonjourTransport(name: await BonjourTransport.instanceName(app: app)))
  }

  // MARK: - Inspectable

  public func catalog() async -> Catalog {
    let actions = storage.withLock { $0.actions }
    let nodes = actions.map { path, entry in ActionNode(path: path, payload: entry.schema) }
      .sorted { $0.path < $1.path }
    return Catalog(actions: nodes)
  }

  public func state() async throws -> JSONValue {
    let readers = storage.withLock { $0.states }
    var object: [String: JSONValue] = [:]
    for (key, entry) in readers {
      object[key] = try await entry.read()
    }
    return .object(object)
  }

  // `timeout` is for a conformer that tracks in-flight effects; a registered closure runs to
  // completion before this returns, so every send settles immediately.
  public func perform(path: String, payload: JSONValue?, timeout: Duration) async throws -> Bool {
    guard let entry = storage.withLock({ $0.actions[path] }) else {
      throw InspectorError(
        code: .unknownActionPath,
        message: "no action at `\(path)`",
        didYouMean: suggestions(for: path)
      )
    }
    try await entry.perform(payload)
    return true
  }

  /// Paths sharing `path`'s last segment or its prefix, sorted — the sibling a typo most likely meant.
  private func suggestions(for path: String) -> [String] {
    let segments = path.split(separator: ".")
    let lastSegment = segments.last.map(String.init)
    let prefix = segments.dropLast().joined(separator: ".")
    let candidates = storage.withLock { Array($0.actions.keys) }
    return candidates
      .filter { candidate in
        let candidateSegments = candidate.split(separator: ".")
        let sharesLastSegment = lastSegment != nil && candidateSegments.last.map(String.init) == lastSegment
        let sharesPrefix = !prefix.isEmpty && candidateSegments.dropLast().joined(separator: ".") == prefix
        return sharesLastSegment || sharesPrefix
      }
      .sorted()
  }
}

/// A token for one registered state reader or action.
///
/// Every registration on an ``Inspector`` returns one.
public struct Registration: Sendable, Hashable {
  private let id: UUID
  private let remove: @Sendable () -> Void

  fileprivate init(id: UUID, remove: @escaping @Sendable () -> Void) {
    self.id = id
    self.remove = remove
  }

  /// Removes exactly this registration.
  ///
  /// A no-op when the same key or path was registered again since, so a stale token never removes
  /// the newer registration.
  public func cancel() {
    remove()
  }

  public static func == (lhs: Registration, rhs: Registration) -> Bool {
    lhs.id == rhs.id
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

extension JSONValue {
  /// Round-trips an `Encodable` value through `JSONValue`'s own decoder, so any Codable state
  /// reader can be stored without teaching the inspector each concrete type.
  fileprivate init(encoding value: some Encodable) throws {
    self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }
}
