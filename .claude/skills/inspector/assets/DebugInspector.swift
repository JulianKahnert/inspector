// DEBUG INSPECTOR — temporary hooks for the `inspector` CLI; delete this file to remove them.
// Fill every <#placeholder#>, then call `registerInspector()` at the end of each model's init:
//
//     #if canImport(InspectorKit) // DEBUG INSPECTOR
//     registerInspector() // DEBUG INSPECTOR
//     #endif // DEBUG INSPECTOR
#if canImport(InspectorKit)
import InspectorKit

/// One row of a list screen, so a route can pick it by `index` and confirm it by `id` or `title`.
struct InspectorListEntry: Encodable, Sendable {
    let index: Int
    let id: String
    let title: String
}

func inspectorIndexError(_ index: Int, count: Int) -> InspectorError {
    InspectorError(code: .badRequest, message: "index \(index) out of range 0..<\(count)")
}

// A list screen: read its rows, open one by index.
extension <#ListViewModel#> {
    func registerInspector() {
        // A top-level key without dots stays reachable as `inspector state <key>`.
        Inspector.shared.state("<#featureList#>") { @MainActor [weak self] in
            self?.<#rows#>.enumerated().map { index, row in
                InspectorListEntry(index: index, id: "\(row.id)", title: <#row.title#>)
            }
        }
        // Go through the same entry point a tap uses, so the screen reacts exactly like it does for a user.
        Inspector.shared.action("<#featureList#>.open") { @MainActor [weak self] (index: Int) in
            guard let self else { return }
            guard <#rows#>.indices.contains(index) else { throw inspectorIndexError(index, count: <#rows#>.count) }
            <#select(rows[index])#>
        }
    }
}

// A detail screen: read what the screen shows, trigger what a user can tap.
extension <#DetailViewModel#> {
    private struct InspectorState: Encodable, Sendable {
        let isLoading: Bool
        <#let value: String#>
    }

    func registerInspector() {
        Inspector.shared.state("<#featureDetail#>") { @MainActor [weak self] in
            self.map { model in
                InspectorState(isLoading: model.<#isLoading#>, <#value: model.value#>)
            }
        }
        Inspector.shared.action("<#featureDetail#>.<#tapSomething#>") { @MainActor [weak self] in
            self?.<#somethingTapped()#>
        }
        // No generic back exists, so every screen a route opens needs its own way out.
        Inspector.shared.action("<#featureDetail#>.close") { @MainActor [weak self] in
            self?.<#dismiss()#>
        }
    }
}
#endif
