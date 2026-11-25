import Foundation
import InspectorKit

/// A touch or keyboard input Xcode synthesizes in the simulator of the session.
enum Gesture: Sendable {
  /// A tap at a point.
  case tap(Point)
  /// A tap at the hit point of the one target whose identifier or label is the name.
  case tapTarget(String)
  /// A finger moved from one point to another, over a duration in seconds or Xcode's default.
  case swipe(from: Point, to: Point, duration: Double?)
  /// Text typed on the keyboard into the focused field.
  case type(String)

  /// Performs the gesture in the session `.inspector/config.json` names and, with `wait`, waits in
  /// the app until its state contains the match.
  ///
  /// With a wait the answer is the app's ``SendResult``, diffed against the state read right
  /// before the gesture, which replaces `wait`'s baseline; without one, ``Performed``. With
  /// `targets`, the answer also carries `targets`, the ``Target``s of the hierarchy Xcode captured
  /// after the gesture. A target is resolved from a capture in the same bridge, before the state
  /// is read; with `find`, a target missing from the capture is looked for again every 300 ms
  /// until `find` has passed.
  ///
  /// With ``Environment/earlyAnswer`` and a wait, the answer can come before Xcode's; see
  /// ``EarlyAnswer``.
  ///
  /// - Throws: ``ErrorCode/noConfig`` and ``ErrorCode/noSession`` before anything is sent, the
  ///   errors of ``Target/resolve(_:in:)`` before the gesture, every error of
  ///   ``DeviceSession/call(_:_:timeout:on:in:)``, and the app's errors, such as
  ///   ``ErrorCode/expectationFailed`` with the last state in `detail`.
  func perform(
    until wait: WaitRequest?, app: String?, targets: Bool = false, find: Duration? = nil,
    in environment: Environment
  ) async throws(InspectorError) -> any Encodable {
    let session = try DeviceSession(in: environment)
    let synthesized: Synthesized
    if let wait, let early = environment.earlyAnswer {
      switch try await race(wait, early: early, app: app, find: find, session: session, in: environment) {
      case .early(let result): return result
      case .synthesized(let completed): synthesized = completed
      }
    } else {
      synthesized = try await synthesize(
        app: app, readsBaseline: wait != nil, find: find, session: session, in: environment)
    }
    let artifacts = Artifacts(of: synthesized.result)
    artifacts.record(in: synthesized.session.folder)
    let listed = targets ? artifacts.targets ?? [] : nil
    guard var wait else { return WithTargets(answer: synthesized.performed, targets: listed) }
    wait.baseline = synthesized.baseline
    let answer: SendResult
    if let concurrent = synthesized.concurrentWait, case .success(let result) = await concurrent.value {
      answer = result
    } else {
      answer = try await environment.wait(wait, from: app)
    }
    return WithTargets(answer: answer, targets: listed)
  }

  /// The gesture as Xcode performed it, and what was read around it.
  private struct Synthesized: Sendable {
    var session: DeviceSession
    var performed: Performed
    var baseline: JSONValue?
    var result: ToolResult
    /// The wait an early answer ran next to the gesture, which may still be running.
    var concurrentWait: Task<Result<SendResult, InspectorError>, Never>?
  }

  /// Resolves the gesture, reads the baseline and has Xcode perform it, in one bridge.
  ///
  /// `sending` hears the gesture and the baseline right before the gesture goes to Xcode.
  private func synthesize(
    app: String?, readsBaseline: Bool, find: Duration?, session: DeviceSession, in environment: Environment,
    sending: (Performed, JSONValue?) -> Void = { _, _ in }
  ) async throws(InspectorError) -> Synthesized {
    var session = session
    let (performed, baseline, result) = try await environment.withXcode { xcode throws(InspectorError) in
      let performed = try await resolved(in: &session, find: find, on: xcode, in: environment)
      var baseline: JSONValue?
      if readsBaseline { baseline = try await Self.baseline(of: app, session: session.name, in: environment) }
      sending(performed, baseline)
      let result = try await session.call(
        .synthesize, ["interactionCommand": .string(performed.gesture)], on: xcode, in: environment)
      return (performed, baseline, result)
    }
    return Synthesized(session: session, performed: performed, baseline: baseline, result: result)
  }

  /// How the race between Xcode and the app's wait ended.
  private enum RaceEnd {
    /// The wait held first, late enough after the gesture went out: its answer.
    case early(SendResult)
    /// Xcode answered first.
    case synthesized(Synthesized)
  }

  /// What the race hears, in the order it happens.
  private enum RaceEvent: Sendable {
    case sending(Performed, JSONValue?, ContinuousClock.Instant)
    case synthesized(Result<Synthesized, InspectorError>)
    case waited(Result<SendResult, InspectorError>)
    case minimumPassed
  }

  /// Runs the gesture and, once it goes to Xcode, the app's wait next to it; the first to answer
  /// decides, as ``EarlyAnswer`` describes.
  ///
  /// The bridge runs in a task of its own that an early answer leaves behind unawaited.
  private func race(
    _ wait: WaitRequest, early: EarlyAnswer, app: String?, find: Duration?, session: DeviceSession,
    in environment: Environment
  ) async throws(InspectorError) -> RaceEnd {
    let (events, sink) = AsyncStream<RaceEvent>.makeStream()
    let gesture = self
    Task {
      do throws(InspectorError) {
        let synthesized = try await gesture.synthesize(
          app: app, readsBaseline: true, find: find, session: session, in: environment
        ) { performed, baseline in
          sink.yield(.sending(performed, baseline, .now))
        }
        sink.yield(.synthesized(.success(synthesized)))
      } catch {
        sink.yield(.synthesized(.failure(error)))
      }
    }
    var concurrentWait: Task<Result<SendResult, InspectorError>, Never>?
    var sentAt: ContinuousClock.Instant?
    var held: SendResult?
    for await event in events {
      switch event {
      case .sending(_, let baseline, let at):
        sentAt = at
        var request = wait
        request.baseline = baseline
        let waiting = Task { () -> Result<SendResult, InspectorError> in
          do throws(InspectorError) {
            return .success(try await environment.wait(request, from: app))
          } catch {
            return .failure(error)
          }
        }
        concurrentWait = waiting
        Task { sink.yield(.waited(await waiting.value)) }
      case .waited(.success(let result)):
        held = result
        let remaining = (sentAt ?? .now) + early.minimum - .now
        guard remaining > .zero else { return .early(result) }
        Task {
          try? await Task.sleep(for: remaining)
          sink.yield(.minimumPassed)
        }
      case .waited(.failure):
        // Xcode's answer decides; the wait then runs once more, as without the early answer.
        break
      case .minimumPassed:
        if let held { return .early(held) }
      case .synthesized(.failure(let error)):
        throw error
      case .synthesized(.success(var synthesized)):
        synthesized.concurrentWait = concurrentWait
        return .synthesized(synthesized)
      }
    }
    throw InspectorError(code: .badRequest, message: "the gesture ended without an answer")
  }

  /// The command `DeviceInteractionSynthesize` takes for the gesture, with the target it aims at.
  private func resolved(
    in session: inout DeviceSession, find: Duration?, on xcode: XcodeBridge, in environment: Environment
  ) async throws(InspectorError) -> Performed {
    switch self {
    case .tap(let point):
      return Performed(gesture: "t \(point.command)")
    case .tapTarget(let name):
      let target = try await Self.target(name, within: find, in: &session, on: xcode, in: environment)
      return Performed(gesture: "t \(target.hitPoint.command)", target: target)
    case .swipe(let start, let end, let duration):
      return Performed(gesture: "t \(start.command) f \(end.command)" + (duration.map { " \($0.command)" } ?? ""))
    case .type(let text):
      // `kbd` takes the rest of the command as its text, so it has to come last.
      return Performed(gesture: "sender keyboard kbd \(text)")
    }
  }

  /// How long ``target(_:within:in:on:in:)`` pauses between two captures.
  static let findInterval = Duration.milliseconds(300)

  /// The one target named `name` in a capture, captured again every ``findInterval`` while it is
  /// missing and `find` has not passed, so a dialog that is still appearing is waited for.
  ///
  /// - Throws: the errors of ``Target/resolve(_:in:)`` for the last capture, and every error of
  ///   ``DeviceSession/capture(on:in:)``.
  private static func target(
    _ name: String, within find: Duration?, in session: inout DeviceSession, on xcode: XcodeBridge,
    in environment: Environment
  ) async throws(InspectorError) -> Target {
    let deadline = find.map { ContinuousClock.now + $0 }
    while true {
      let targets = try await session.capture(on: xcode, in: environment).targets
      do throws(InspectorError) {
        return try Target.resolve(name, in: targets)
      } catch where error.code == .targetNotFound {
        guard let deadline, ContinuousClock.now < deadline else { throw error }
        try? await Task.sleep(for: min(findInterval, deadline - .now))
      }
    }
  }

  /// The state before the gesture.
  ///
  /// An app that does not answer has died, and for a gesture its session with it: Xcode's
  /// `Session not found` comes only after the gesture, which must not run without its baseline.
  private static func baseline(
    of app: String?, session: String, in environment: Environment
  ) async throws(InspectorError) -> JSONValue {
    do throws(InspectorError) {
      return try await environment.state(from: app)
    } catch where [.appNotFound, .timeout].contains(error.code) {
      throw InspectorError(
        code: .noSession, message: "the app of the session `\(session)` does not answer; run `inspector init`",
        detail: error.message)
    }
  }

  /// What a gesture without a condition answers: the command Xcode ran, and the target it aimed at.
  struct Performed: Encodable, Sendable {
    var gesture: String
    var target: Target?
  }

  /// A gesture's answer with `targets` beside its own fields, when `--targets` asked for them.
  struct WithTargets<Answer: Encodable>: Encodable {
    /// The answer as it is without `--targets`.
    var answer: Answer
    /// The targets of the hierarchy Xcode captured after the gesture; `nil` leaves the field out.
    var targets: [Target]?

    private enum CodingKeys: String, CodingKey {
      case targets
    }

    func encode(to encoder: any Encoder) throws {
      try answer.encode(to: encoder)
      guard let targets else { return }
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(targets, forKey: .targets)
    }
  }
}

/// The experimental early answer of a gesture with `--until`, turned on with `INSPECTOR_EARLY=1`.
///
/// **Experimental.** Xcode answers a gesture about 1.4 s after the touch, because it captures the
/// screenshot and the hierarchy afterwards, while the app reaches its new state about 0.17 s after
/// it. With the early answer, the app's wait starts right when the gesture goes to Xcode, next to
/// it:
///
/// - When the wait holds first, the CLI answers with it once ``minimum`` has passed since the
///   gesture went out (`INSPECTOR_EARLY_MIN_MS`, 350 ms by default), unless Xcode answers in the
///   meantime. The process then exits without awaiting the bridge, which ends with it; the answer
///   carries no `targets` and `run.json` gets no artifacts of the gesture.
/// - When Xcode fails first, its error is the answer, as without the early answer.
/// - When Xcode answers first, everything is as without the early answer; a wait that already
///   held is the answer, one that failed runs once more after the gesture.
///
/// The minimum keeps the process alive until Xcode has had time to deliver the touch, and an
/// answer from a condition that held already before the gesture is never earlier than that.
struct EarlyAnswer: Equatable, Sendable {
  /// The earliest time after the gesture went out at which the wait's answer may end the call.
  var minimum: Duration

  /// The default ``minimum``, in milliseconds.
  static let defaultMinimumMs = 350

  /// An early answer with `minimum`.
  init(minimum: Duration) {
    self.minimum = minimum
  }

  /// The early answer the process environment asks for: `INSPECTOR_EARLY=1` turns it on,
  /// `INSPECTOR_EARLY_MIN_MS` sets ``minimum``; a missing or unreadable value is the default.
  ///
  /// `nil` when `INSPECTOR_EARLY` is not `1`.
  init?(variables: [String: String]) {
    guard variables["INSPECTOR_EARLY"] == "1" else { return nil }
    let ms = variables["INSPECTOR_EARLY_MIN_MS"].flatMap { Int($0) }.flatMap { $0 >= 0 ? $0 : nil }
    minimum = .milliseconds(ms ?? Self.defaultMinimumMs)
  }
}

extension Point {
  /// The point as Xcode's interaction commands take it: `x y`.
  fileprivate var command: String {
    "\(x.command) \(y.command)"
  }
}

extension Double {
  /// The number as Xcode's interaction commands take it: a whole number without a fraction.
  fileprivate var command: String {
    guard self == rounded(), abs(self) < 1e15 else { return String(self) }
    return String(Int(self))
  }
}
