import Foundation
import InspectorKit

// inspector [--app name] apps | hello | catalog | state [path] | send <path> [json]

/// Writes `error` to stderr as one JSON line, so a calling agent branches on `code` instead of
/// parsing prose.
func fail(_ error: InspectorError) -> Never {
  FileHandle.standardError.write(Data((WireJSON.line(error) + "\n").utf8))
  exit(1)
}

func usage() -> Never {
  FileHandle.standardError.write(
    Data(
      "usage: inspector [--app name] apps | hello | catalog | state [path] | send <path> [json]\n"
        .utf8))
  exit(64)
}

/// A `send` payload argument is JSON if it parses as JSON, otherwise a plain string.
func parsePayload(_ raw: String) -> JSONValue {
  guard let data = raw.data(using: .utf8),
    let value = try? JSONDecoder().decode(JSONValue.self, from: data)
  else {
    return .string(raw)
  }
  return value
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
private func listApps() async throws -> [AppListing] {
  let names = try await BonjourTransport.instanceNames(browsingFor: .seconds(2))
  return await withTaskGroup { group in
    for name in names {
      group.addTask {
        let hello = await helloOrNil(from: name)
        return AppListing(name: name, live: hello != nil, app: hello?.app, pid: hello?.pid, provider: hello?.provider)
      }
    }
    var listings: [AppListing] = []
    for await listing in group { listings.append(listing) }
    return listings.sorted { $0.name < $1.name }
  }
}

/// `nil` when the app does not answer within 2 seconds; a silent app is a result here, not a failure.
func helloOrNil(from name: String) async -> Hello? {
  await withTaskGroup(of: Hello?.self) { group in
    group.addTask {
      guard case .hello(let hello) = try? await BonjourTransport(name: name).send(.hello) else { return nil }
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

var arguments = Array(CommandLine.arguments.dropFirst())

// `--app` applies to every command, so it is taken out before the command is parsed.
var app: String?
if let index = arguments.firstIndex(of: "--app") {
  guard arguments.indices.contains(index + 1) else { usage() }
  app = arguments[index + 1]
  arguments.removeSubrange(index...(index + 1))
}

if arguments.first == "apps" {
  do {
    print(WireJSON.line(try await listApps()))
    exit(0)
  } catch {
    fail(InspectorError(code: .badRequest, message: "could not browse for apps", detail: "\(error)"))
  }
}

let request: Request
switch arguments.first {
case "hello":
  request = .hello
case "catalog":
  request = .catalog
case "state":
  request = .state(path: arguments.count > 1 ? arguments[1] : nil)
case "send" where arguments.count >= 2:
  let payload = arguments.count > 2 ? parsePayload(arguments[2]) : nil
  request = .send(SendRequest(path: arguments[1], payload: payload))
default:
  usage()
}

let response: Response
do {
  response = try await BonjourTransport(name: app).send(request)
} catch let error as InspectorError {
  fail(error)
} catch {
  fail(InspectorError(code: .badRequest, message: "could not reach the app", detail: "\(error)"))
}

switch response {
case .hello(let hello):
  print(WireJSON.line(hello))
case .catalog(let catalog):
  print(WireJSON.line(catalog))
case .state(let state):
  print(WireJSON.line(state))
case .sendResult(let result):
  print(WireJSON.line(result))
case .error(let error):
  fail(error)
}
