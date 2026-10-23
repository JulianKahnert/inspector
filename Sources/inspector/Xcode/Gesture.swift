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
  /// before the gesture, which replaces `wait`'s baseline; without one, ``Performed``. A target is resolved from a capture in the
  /// same bridge, before the state is read.
  ///
  /// - Throws: ``ErrorCode/noConfig`` and ``ErrorCode/noSession`` before anything is sent, the
  ///   errors of ``Target/resolve(_:in:)`` before the gesture, every error of
  ///   ``DeviceSession/call(_:_:timeout:on:in:)``, and the app's errors, such as
  ///   ``ErrorCode/expectationFailed`` with the last state in `detail`.
  func perform(until wait: WaitRequest?, app: String?, in environment: Environment) async throws(InspectorError)
    -> any Encodable
  {
    var session = try DeviceSession(in: environment)
    let (performed, baseline, result) = try await environment.withXcode { xcode throws(InspectorError) in
      let performed = try await resolved(in: &session, on: xcode, in: environment)
      var baseline: JSONValue?
      if wait != nil { baseline = try await Self.baseline(of: app, session: session.name, in: environment) }
      let result = try await session.call(
        .synthesize, ["interactionCommand": .string(performed.gesture)], on: xcode, in: environment)
      return (performed, baseline, result)
    }
    Artifacts(of: result).record(in: session.folder)
    guard var wait else { return performed }
    wait.baseline = baseline
    return try await environment.wait(wait, from: app)
  }

  /// The command `DeviceInteractionSynthesize` takes for the gesture, with the target it aims at.
  private func resolved(
    in session: inout DeviceSession, on xcode: XcodeBridge, in environment: Environment
  ) async throws(InspectorError) -> Performed {
    switch self {
    case .tap(let point):
      return Performed(gesture: "t \(point.command)")
    case .tapTarget(let name):
      let target = try Target.resolve(name, in: try await session.capture(on: xcode, in: environment).targets)
      return Performed(gesture: "t \(target.hitPoint.command)", target: target)
    case .swipe(let start, let end, let duration):
      return Performed(gesture: "t \(start.command) f \(end.command)" + (duration.map { " \($0.command)" } ?? ""))
    case .type(let text):
      // `kbd` takes the rest of the command as its text, so it has to come last.
      return Performed(gesture: "sender keyboard kbd \(text)")
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
  struct Performed: Encodable {
    var gesture: String
    var target: Target?
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
