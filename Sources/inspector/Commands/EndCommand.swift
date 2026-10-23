import ArgumentParser
import InspectorKit

/// `inspector end`: ends the Xcode device interaction session `.inspector/config.json` names.
struct EndCommand: InspectorCommand {
  static let configuration = CommandConfiguration(
    commandName: "end",
    abstract: "Ends the Xcode device interaction session in `.inspector/config.json`.",
    discussion: """
      The app the session started ends with it. A session that already ended fails with Xcode's \
      error. Needs `.inspector/`; `inspector init` starts the next session.
      """)

  func answer(in environment: Environment) async throws(InspectorError) -> any Encodable {
    let session = try DeviceSession(in: environment)
    let result = try await environment.withXcode { xcode throws(InspectorError) in try await session.end(on: xcode) }
    return Ended(message: result.text, session: session.name)
  }

  /// Which session ended and what Xcode said about it.
  struct Ended: Encodable {
    var message: String
    var session: String
  }
}
