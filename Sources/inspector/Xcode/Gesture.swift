import Foundation
import InspectorKit

/// A touch or keyboard input Xcode synthesizes in the simulator of the session.
enum Gesture: Sendable {
  /// A tap at a point.
  case tap(Point)
  /// A tap at the hit point of the one target whose identifier or label is the name.
  case tapTarget(String)

  /// Performs the gesture in the session `.inspector/config.json` names and, with `condition`,
  /// waits in the app until its state contains the match.
  ///
  /// With a condition the answer is the app's ``SendResult``, diffed against the state read right
  /// before the gesture; without one, ``Performed``. A target is resolved from a capture in the
  /// same bridge, before the state is read.
  ///
  /// - Throws: ``ErrorCode/noConfig`` and ``ErrorCode/noSession`` before anything is sent, the
  ///   errors of ``Target/resolve(_:in:)`` before the gesture, every error of
  ///   ``DeviceSession/call(_:_:timeout:on:in:)``, and the app's errors, such as
  ///   ``ErrorCode/expectationFailed`` with the last state in `detail`.
  func perform(until condition: UntilOptions, app: String?, in environment: Environment) async throws(InspectorError)
    -> any Encodable
  {
    var session = try DeviceSession(in: environment)
    let (performed, baseline, result) = try await environment.withXcode { xcode throws(InspectorError) in
      let performed = try await resolved(in: &session, on: xcode, in: environment)
      var baseline: JSONValue?
      if condition.match != nil { baseline = try await Self.state(of: app, in: environment) }
      let result = try await session.call(
        .synthesize, ["interactionCommand": .string(performed.gesture)], on: xcode, in: environment)
      return (performed, baseline, result)
    }
    Artifacts(of: result).record(in: session.folder)
    guard let match = condition.match else { return performed }
    let wait = WaitRequest(until: match, timeoutMs: condition.timeout.timeoutMs, baseline: baseline)
    guard case .sendResult(let answer) = try await environment.response(to: .wait(wait), from: app) else {
      throw InspectorError(code: .badRequest, message: "unexpected answer to wait")
    }
    return answer
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
    }
  }

  private static func state(of app: String?, in environment: Environment) async throws(InspectorError) -> JSONValue {
    guard case .state(let state) = try await environment.response(to: .state(path: nil), from: app) else {
      throw InspectorError(code: .badRequest, message: "unexpected answer to state")
    }
    return state
  }

  /// What a gesture without a condition answers: the command Xcode ran, and the target it aimed at.
  struct Performed: Encodable {
    var gesture: String
    var target: Target?
  }
}

extension Point {
  /// The point as Xcode's interaction commands take it: `x y`, whole numbers without a fraction.
  var command: String {
    "\(Self.command(x)) \(Self.command(y))"
  }

  private static func command(_ value: Double) -> String {
    guard value == value.rounded(), abs(value) < 1e15 else { return String(value) }
    return String(Int(value))
  }
}
