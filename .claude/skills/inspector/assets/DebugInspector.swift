// DEBUG INSPECTOR — the app's debug integration for the `inspector` CLI; remove.sh deletes this file.
// Fill every <#placeholder#> (the file does not compile until each one is filled), then call it
// once from the app's entry point, on one marked line:
//
//     DebugInspector.start(root: <#appModel#>) // DEBUG INSPECTOR
//
// Everything is registered from the root object, and this file is the only caller of `serve()`.
#if DEBUG
import InspectorKit
import OSLog
#endif

@MainActor
enum DebugInspector {
    /// Registers the app's state and actions and starts serving; does nothing in a release build.
    static func start(root: <#AppModel#>) {
        #if DEBUG
        registerList(of: root)
        registerDetail(of: root)
        if #available(iOS 26, macOS 26, *) {
            Task {
                do {
                    try await Inspector.shared.serve()
                } catch {
                    Logger(subsystem: "<#app.subsystem#>", category: "inspector")
                        .error("inspector stopped serving: \(error)")
                }
            }
        }
        #endif
    }
}

#if DEBUG
/// One row of a list screen, so a route can pick it by `index` and confirm it by `id` or `title`.
private struct InspectorListEntry: Encodable, Sendable {
    let index: Int
    let id: String
    let title: String
}

extension DebugInspector {
    // A list screen: read its rows, open one by index.
    private static func registerList(of root: <#AppModel#>) {
        // A top-level key without dots stays reachable as `inspector state <key>`.
        Inspector.shared.state("<#featureList#>") { @MainActor [weak root] in
            root?.<#rows#>.enumerated().map { index, row in
                InspectorListEntry(index: index, id: "\(row.id)", title: <#row.title#>)
            }
        }
        // Go through the same entry point a tap uses, so the screen reacts exactly like it does for a user.
        Inspector.shared.action("<#featureList#>.open") { @MainActor [weak root] (index: Int) in
            guard let root else { return }
            guard root.<#rows#>.indices.contains(index) else {
                throw InspectorError(code: .badRequest, message: "index \(index) out of range 0..<\(root.<#rows#>.count)")
            }
            <#root.select(root.rows[index])#>
        }
    }

    // A detail screen: read what the screen shows, trigger what a user can tap. A reader whose
    // screen is gone reads null.
    private static func registerDetail(of root: <#AppModel#>) {
        struct DetailState: Encodable, Sendable {
            let isLoading: Bool
            <#let value: String#>
        }
        Inspector.shared.state("<#featureDetail#>") { @MainActor [weak root] in
            root?.<#detail#>.map { detail in
                DetailState(isLoading: detail.<#isLoading#>, <#value: detail.value#>)
            }
        }
        Inspector.shared.action("<#featureDetail#>.<#tapSomething#>") { @MainActor [weak root] in
            root?.<#detail#>?.<#somethingTapped()#>
        }
        // No generic back exists, so every screen a route opens needs its own way out.
        Inspector.shared.action("<#featureDetail#>.close") { @MainActor [weak root] in
            root?.<#closeDetail()#>
        }
    }
}
#endif
