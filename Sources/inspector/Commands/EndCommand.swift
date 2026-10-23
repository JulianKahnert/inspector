import ArgumentParser
import InspectorKit

/// `inspector end`: ends the Xcode device interaction session `.inspector/config.json` names.
struct EndCommand: InspectorCommand {
  static let configuration = CommandConfiguration(
    commandName: "end",
    abstract: "Ends the Xcode device interaction session in `.inspector/config.json`.",
    discussion: """
      The app the session started ends with it. The answer carries Xcode's own answer under \
      `xcode`, also for a session that already ended. Needs `.inspector/`; `inspector init` \
      starts the next session.
      """)

  func answer(in environment: Environment) async throws(InspectorError) -> any Encodable {
    let session = try DeviceSession(in: environment)
    let result = try await environment.withXcode { xcode throws(InspectorError) in try await session.end(on: xcode) }
    return Ended(session: session.name, xcode: result.json)
  }

  /// Which session ended and what Xcode said about it.
  struct Ended: Encodable {
    var session: String
    var xcode: JSONValue
  }
}
