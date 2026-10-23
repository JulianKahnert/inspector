import InspectorKit

/// Everything a command reaches outside the process; a test swaps it for an in-memory app.
struct Environment: Sendable {
  /// The transport to the app `app` selects, or to the only serving app when `nil`.
  var transport: @Sendable (_ app: String?) -> any InspectorTransport
  /// The instance names of every serving app found while browsing for the given time.
  var instanceNames: @Sendable (_ browsingFor: Duration) async throws -> [String]

  /// The apps on the network, found through Bonjour.
  static let live = Environment(
    transport: { BonjourTransport(name: $0) },
    instanceNames: { try await BonjourTransport.instanceNames(browsingFor: $0) })

  /// Sends `request` to the app `app` selects and returns the payload of its response.
  ///
  /// - Throws: the app's rejection, a discovery or timeout error from the transport, and
  ///   ``ErrorCode/badRequest`` for anything else that keeps the request from the app.
  func answer(to request: Request, from app: String?) async throws(InspectorError) -> any Encodable {
    let response: Response
    do {
      response = try await transport(app).send(request)
    } catch let error as InspectorError {
      throw error
    } catch {
      throw InspectorError(code: .badRequest, message: "could not reach the app", detail: "\(error)")
    }
    switch response {
    case .hello(let hello): return hello
    case .catalog(let catalog): return catalog
    case .state(let state): return state
    case .sendResult(let result): return result
    case .error(let error): throw error
    }
  }
}
