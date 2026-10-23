import ArgumentParser
import InspectorKit

/// `inspector apps`: every app serving on the network, each checked with `hello`.
///
/// The only command that is not a wire operation.
struct AppsCommand: InspectorCommand {
  static let configuration = CommandConfiguration(
    commandName: "apps",
    abstract: "Lists every app found through Bonjour, each checked with `hello`.",
    discussion: "An app that does not answer within 2 seconds is listed with `\"live\":false`.")

  @OptionGroup var options: AppOptions

  /// Discovery needs no `.inspector/` folder and is no step of the loop.
  static var isLoopStep: Bool { false }

  func answer(in environment: Environment) async throws(InspectorError) -> any Encodable {
    do {
      return try await listApps(in: environment)
    } catch {
      throw InspectorError(code: .badRequest, message: "could not browse for apps", detail: "\(error)")
    }
  }
}

/// One row of `inspector apps`; `live` is false when the app did not answer `hello` in time.
private struct AppListing: Encodable {
  var name: String
  var live: Bool
  var app: String?
  var pid: Int?
  var provider: String?
}

/// Browses for serving apps and asks each one `hello`, so the list shows which app is behind a name.
private func listApps(in environment: Environment) async throws -> [AppListing] {
  let names = try await environment.instanceNames(.seconds(2))
  return await withTaskGroup { group in
    for name in names {
      group.addTask {
        let hello = await helloOrNil(from: environment.transport(name))
        return AppListing(name: name, live: hello != nil, app: hello?.app, pid: hello?.pid, provider: hello?.provider)
      }
    }
    var listings: [AppListing] = []
    for await listing in group { listings.append(listing) }
    return listings.sorted { $0.name < $1.name }
  }
}

/// `nil` when the app does not answer within 2 seconds; a silent app is a result here, not a failure.
private func helloOrNil(from transport: any InspectorTransport) async -> Hello? {
  await withTaskGroup(of: Hello?.self) { group in
    group.addTask {
      guard case .hello(let hello) = try? await transport.send(.hello) else { return nil }
      return hello
    }
    group.addTask {
      try? await Task.sleep(for: .seconds(2))
      return nil
    }
    let first = await group.next() ?? nil
    group.cancelAll()
    return first
  }
}
