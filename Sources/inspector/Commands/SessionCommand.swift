import ArgumentParser
import Foundation
import InspectorKit

/// `inspector session`: starts a new Xcode device interaction session on the simulator
/// `.inspector/config.json` names, without asking the app.
struct SessionCommand: InspectorCommand {
  static let configuration = CommandConfiguration(
    commandName: "session",
    abstract: "Starts a new Xcode device interaction session on the simulator in `.inspector/config.json`.",
    discussion: """
      Starts the session with Xcode's DeviceInteractionStartSession on `udid`, without a \
      workspace and without asking the app for `hello`, so it can run while the app is still \
      launching, and writes its name to `config.json` as `session`. While it starts, \
      `.inspector/session.lock` holds this process's ID, and every other call into the session \
      waits for it. The answer is `session` and `startedMs`, how long the start took. Needs \
      `.inspector/` with a `udid`, which `inspector init` writes.
      """)

  func answer(in environment: Environment) async throws(InspectorError) -> any Encodable {
    let folder = try environment.requiredFolder()
    let configFile = folder.url.appending(path: "config.json").path
    guard let config = try folder.config(), let udid = config.udid else {
      throw InspectorError(
        code: .noConfig, message: "no `udid` in `config.json`; run `inspector init`", detail: configFile)
    }
    let clock = ContinuousClock()
    let start = clock.now
    let lock = environment.sessionLock(in: folder)
    let waited = try await lock.acquire()
    defer { lock.release() }
    // Another call started a session while this one waited for the lock: that one is fresh.
    if waited, let latest = try folder.config(), let session = latest.session, session != config.session {
      return Started(session: session, startedMs: Self.milliseconds(clock.now - start))
    }
    let started = try await environment.withXcode { xcode throws(InspectorError) in
      try await DeviceSession.startOnDevice(udid, in: folder, fallback: config, on: xcode, in: environment)
    }
    return Started(session: started.session ?? "", startedMs: Self.milliseconds(clock.now - start))
  }

  private static func milliseconds(_ duration: Duration) -> Int {
    Int((duration / .milliseconds(1)).rounded())
  }

  /// The session that is live now and how long this call took to get it.
  struct Started: Encodable {
    var session: String
    var startedMs: Int
  }
}
